import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Represents a modular agent capability or skill loaded from a SKILL.md definition.
class Skill {
  final String name;
  final String description;
  final String content;
  final String filePath;

  /// Sibling files shipped alongside SKILL.md (e.g. `LOGIC.md`, `ADR-FORMAT.md`).
  final List<String> assets;

  /// Frontmatter flag: skill is user-invoked only and must not be listed in the
  /// model-facing index.
  final bool disableModelInvocation;
  final bool isWorkspace;
  bool isEnabled;

  Skill({
    required this.name,
    required this.description,
    required this.content,
    required this.filePath,
    this.assets = const [],
    this.disableModelInvocation = false,
    this.isWorkspace = false,
    this.isEnabled = true,
  });

  /// Directory containing this skill's SKILL.md.
  String get directory => p.dirname(filePath);

  @override
  String toString() =>
      '$name: $description (${isEnabled ? "active" : "disabled"})';
}

/// Discovers, loads, toggles, and formats modular skills.
///
/// Skills are loaded lazily: the system prompt carries only a name + description
/// index, and the model fetches a skill's full body through the `skill` tool.
/// This keeps a large shared skill library off the context window.
class SkillsManager {
  static final SkillsManager instance = SkillsManager();

  final List<Skill> _skills = [];

  /// Workspace root used to resolve the persisted `.nib/skills.json` overrides.
  String? _workspacePath;

  /// The workspace the skills were last loaded from, if any.
  String? get workspacePath => _workspacePath;

  List<Skill> get skills => List.unmodifiable(_skills);
  List<Skill> get activeSkills => _skills.where((s) => s.isEnabled).toList();

  /// Skills the model is allowed to see in the index.
  List<Skill> get indexableSkills =>
      activeSkills.where((s) => !s.disableModelInvocation).toList();

  /// Scans Nib's own skill paths for directories containing SKILL.md.
  ///
  /// Only Nib-owned roots are scanned (`.nib/skills` in the workspace and in the
  /// user's home). Skill directories belonging to other agent harnesses are
  /// deliberately not imported, so Nib's prompt is not polluted by tools that do
  /// not exist here.
  Future<void> loadSkills({String? workspacePath}) async {
    _skills.clear();
    _workspacePath = workspacePath;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final seen = <String>{};

    final candidates = <({String dir, bool isWorkspace})>[
      if (workspacePath != null)
        (dir: p.join(workspacePath, '.nib', 'skills'), isWorkspace: true),
      if (home.isNotEmpty)
        (dir: p.join(home, '.nib', 'skills'), isWorkspace: false),
    ];

    for (final candidate in candidates) {
      final skillDir = Directory(candidate.dir);
      if (!await skillDir.exists()) continue;
      try {
        for (final entity in skillDir.listSync()) {
          if (entity is! Directory) continue;
          final skillFile = File(p.join(entity.path, 'SKILL.md'));
          final fallbackFile = File(p.join(entity.path, 'skill.md'));
          final target = await skillFile.exists()
              ? skillFile
              : (await fallbackFile.exists() ? fallbackFile : null);
          if (target == null) continue;

          final skill = await _parseSkillFile(
            target,
            defaultName: p.basename(entity.path),
            isWorkspace: candidate.isWorkspace,
          );
          if (skill != null && !seen.contains(skill.name.toLowerCase())) {
            seen.add(skill.name.toLowerCase());
            _skills.add(skill);
          }
        }
      } catch (_) {}
    }

    await _applyPersistedOverrides();
  }

  Future<Skill?> _parseSkillFile(
    File file, {
    required String defaultName,
    required bool isWorkspace,
  }) async {
    try {
      final raw = await file.readAsString();
      var name = defaultName;
      var description = '';
      var body = raw;
      var disableModelInvocation = false;

      // Parse YAML frontmatter if present (between --- and ---)
      if (raw.startsWith('---')) {
        final secondIndex = raw.indexOf('---', 3);
        if (secondIndex != -1) {
          final frontmatterStr = raw.substring(3, secondIndex).trim();
          body = raw.substring(secondIndex + 3).trim();

          try {
            final parsedYaml = loadYaml(frontmatterStr);
            if (parsedYaml is Map) {
              name = parsedYaml['name']?.toString() ?? name;
              description =
                  parsedYaml['description']?.toString() ?? description;
              final dmi = parsedYaml['disable-model-invocation'];
              disableModelInvocation = dmi == true || dmi?.toString() == 'true';
            }
          } catch (_) {}
        }
      }

      if (description.isEmpty) {
        String? foundHeading;
        String? foundParagraph;
        for (final line in body.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('---')) continue;
          if (trimmed.startsWith('#')) {
            foundHeading ??= trimmed.replaceAll(RegExp(r'^#+\s*'), '');
          } else {
            foundParagraph = trimmed;
            break;
          }
        }
        description = foundParagraph ?? foundHeading ?? '';
      }

      return Skill(
        name: name,
        description: description,
        content: body,
        filePath: file.path,
        assets: await _listAssets(file),
        disableModelInvocation: disableModelInvocation,
        isWorkspace: isWorkspace,
        isEnabled: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Lists sibling markdown files next to a SKILL.md, sorted by name.
  Future<List<String>> _listAssets(File skillFile) async {
    try {
      final dir = Directory(p.dirname(skillFile.path));
      if (!await dir.exists()) return const [];
      final assets = <String>[];
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        if (base.toLowerCase() == 'skill.md') continue;
        if (!base.toLowerCase().endsWith('.md')) continue;
        assets.add(base);
      }
      assets.sort();
      return assets;
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Persisted per-project enable/disable overrides (.nib/skills.json)
  // ---------------------------------------------------------------------------

  File get _overridesFile {
    final ws = _workspacePath;
    if (ws == null) {
      return File(p.join(Directory.current.path, '.nib', 'skills.json'));
    }
    return File(p.join(ws, '.nib', 'skills.json'));
  }

  Future<void> _applyPersistedOverrides() async {
    final file = _overridesFile;
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final disabled = decoded['disabled'];
      if (disabled is! List) return;
      for (final entry in disabled) {
        final skill = findSkill(entry.toString());
        if (skill != null) skill.isEnabled = false;
      }
    } catch (_) {
      // A malformed overrides file must never block startup.
    }
  }

  /// Persists the current enable/disable state for this workspace.
  ///
  /// Entries already in the file that do not match a currently loaded skill are
  /// preserved, so a skill disabled in another checkout (or temporarily absent)
  /// is not silently forgotten here. Names of loaded skills that are now
  /// re-enabled are dropped.
  Future<void> saveOverrides() async {
    try {
      final file = _overridesFile;
      final reEnabled = {
        for (final s in _skills)
          if (s.isEnabled) s.name.toLowerCase(),
      };
      final seen = <String>{};
      final kept = <String>[];
      for (final name in await _persistedDisabledNames()) {
        final key = name.toLowerCase();
        if (reEnabled.contains(key) || !seen.add(key)) continue;
        kept.add(name);
      }
      for (final s in _skills) {
        if (s.isEnabled || !seen.add(s.name.toLowerCase())) continue;
        kept.add(s.name);
      }
      await file.parent.create(recursive: true);
      final encoded = const JsonEncoder.withIndent(
        '  ',
      ).convert({'disabled': kept});
      await file.writeAsString('$encoded\n');
    } catch (_) {}
  }

  Future<List<String>> _persistedDisabledNames() async {
    final file = _overridesFile;
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const [];
      final disabled = decoded['disabled'];
      if (disabled is! List) return const [];
      return disabled.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  Skill? findSkill(String name) {
    final lower = name.toLowerCase().trim();
    for (final s in _skills) {
      if (s.name.toLowerCase() == lower) return s;
    }
    return null;
  }

  bool toggleSkill(String name) {
    final skill = findSkill(name);
    if (skill != null) {
      skill.isEnabled = !skill.isEnabled;
      return true;
    }
    return false;
  }

  void enableSkill(String name) {
    final skill = findSkill(name);
    if (skill != null) skill.isEnabled = true;
  }

  void disableSkill(String name) {
    final skill = findSkill(name);
    if (skill != null) skill.isEnabled = false;
  }

  /// Formats active skills as a **name + description index** for the system
  /// prompt. Full bodies are fetched on demand via the `skill` tool.
  String formatForSystemPrompt() {
    final indexable = indexableSkills;
    if (indexable.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('\n\n# Available Agent Skills');
    buffer.writeln(
      'You have access to the specialized workflows below. They are NOT loaded '
      'into your context: each entry is a name and a description only.',
    );
    buffer.writeln(
      'Before following a skill\'s workflow, call the `skill` tool with its name '
      'to load the full instructions. Load a skill only when the task actually '
      'needs it; never load one speculatively.\n',
    );

    for (final skill in indexable) {
      buffer.writeln('- **${skill.name}** — ${skill.description}');
    }
    return buffer.toString();
  }

  /// Returns the full body of one skill, plus a pointer to its sibling files.
  String formatSkillBody(Skill skill) {
    final buffer = StringBuffer();
    buffer.writeln('# Skill: ${skill.name}');
    if (skill.description.isNotEmpty) buffer.writeln('_${skill.description}_');
    buffer.writeln();
    buffer.writeln(skill.content.trimRight());

    if (skill.assets.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## Companion files');
      buffer.writeln(
        'This skill ships additional files referenced by the workflow above: '
        '${skill.assets.join(', ')}.',
      );
      buffer.writeln(
        'Read one by calling the `skill` tool again with name '
        '"${skill.name}" and file "<name>". Do not use read_file on these: they '
        'may live outside the workspace, which read_file cannot access.',
      );
    }
    return buffer.toString();
  }
}
