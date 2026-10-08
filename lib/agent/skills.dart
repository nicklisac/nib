import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Represents a modular agent capability or skill loaded from a SKILL.md definition.
class Skill {
  final String name;
  final String description;
  final String content;
  final String filePath;
  final bool isWorkspace;
  bool isEnabled;

  Skill({
    required this.name,
    required this.description,
    required this.content,
    required this.filePath,
    this.isWorkspace = false,
    this.isEnabled = true,
  });

  @override
  String toString() => '$name: $description (${isEnabled ? "active" : "disabled"})';
}

/// Discovers, loads, toggles, and formats modular skills from workspace and user directories.
class SkillsManager {
  static final SkillsManager instance = SkillsManager();

  final List<Skill> _skills = [];

  List<Skill> get skills => List.unmodifiable(_skills);
  List<Skill> get activeSkills => _skills.where((s) => s.isEnabled).toList();

  /// Scans workspace and global paths for skill directories containing SKILL.md.
  Future<void> loadSkills({String? workspacePath}) async {
    _skills.clear();
    final home = Platform.environment['HOME'] ?? '';
    final seen = <String>{};

    // Candidate directories in priority order:
    final candidates = <({String dir, bool isWorkspace})>[
      // 1. Workspace local skills (.nib/skills and .tau/skills)
      if (workspacePath != null) ...[
        (dir: p.join(workspacePath, '.nib', 'skills'), isWorkspace: true),
        (dir: p.join(workspacePath, '.tau', 'skills'), isWorkspace: true),
        (dir: p.join(workspacePath, 'skills'), isWorkspace: true),
      ],
      // 2. User global skills (~/.nib/skills and ~/.tau/skills)
      if (home.isNotEmpty) ...[
        (dir: p.join(home, '.nib', 'skills'), isWorkspace: false),
        (dir: p.join(home, '.tau', 'skills'), isWorkspace: false),
      ],
    ];

    for (final candidate in candidates) {
      final skillDir = Directory(candidate.dir);
      if (await skillDir.exists()) {
        try {
          final entities = skillDir.listSync();
          for (final entity in entities) {
            if (entity is Directory) {
              final skillFile = File(p.join(entity.path, 'SKILL.md'));
              final fallbackFile = File(p.join(entity.path, 'skill.md'));
              final target = await skillFile.exists()
                  ? skillFile
                  : (await fallbackFile.exists() ? fallbackFile : null);

              if (target != null) {
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
            }
          }
        } catch (_) {}
      }
    }
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

      // Parse YAML frontmatter if present (between --- and ---)
      if (raw.startsWith('---')) {
        final secondIndex = raw.indexOf('---', 3);
        if (secondIndex != -1) {
          final frontmatterStr = raw.substring(3, secondIndex).trim();
          body = raw.substring(secondIndex + 3).trim();

          try {
            final parsedYaml = loadYaml(frontmatterStr);
            if (parsedYaml is Map) {
              if (parsedYaml.containsKey('name')) {
                name = parsedYaml['name']?.toString() ?? name;
              }
              if (parsedYaml.containsKey('description')) {
                description = parsedYaml['description']?.toString() ?? description;
              }
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
        isWorkspace: isWorkspace,
        isEnabled: true,
      );
    } catch (_) {
      return null;
    }
  }

  String _stripQuotes(String val) {
    if ((val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))) {
      return val.substring(1, val.length - 1);
    }
    return val;
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

  /// Formats active skills to be injected into the agent's system prompt.
  String formatForSystemPrompt() {
    final active = activeSkills;
    if (active.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('\n\n# Active Agent Skills');
    buffer.writeln('You have access to the following specialized capabilities and workflows.');
    buffer.writeln('Consult and follow these guidelines when executing relevant tasks:\n');

    for (final skill in active) {
      buffer.writeln('## Skill: ${skill.name}');
      if (skill.description.isNotEmpty) {
        buffer.writeln('_${skill.description}_\n');
      }
      buffer.writeln(skill.content);
      buffer.writeln();
    }

    return buffer.toString();
  }
}
