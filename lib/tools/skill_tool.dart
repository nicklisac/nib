import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/skills.dart';
import '../agent/tool.dart';

/// Lets the model load the full instructions of a skill on demand.
///
/// The system prompt carries only a name + description index, so the model must
/// fetch a skill's body before following its workflow. This keeps an unused
/// skill library off the context window.
class SkillTool extends AgentTool {
  final SkillsManager _skills;

  SkillTool({SkillsManager? skillsManager})
    : _skills = skillsManager ?? SkillsManager.instance;

  @override
  String get name => 'skill';

  @override
  String get description =>
      'Load the full instructions of a named agent skill into the conversation. '
      'Skills are listed by name and description in the system prompt but their '
      'bodies are not preloaded, so you must call this before following one. '
      'Returns the complete workflow plus the names of any companion files it '
      'references. Global skills live outside the workspace and their companion '
      'files cannot be read with read_file; pass "file" to read one instead.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'name': {
        'type': 'string',
        'description':
            'The skill name exactly as listed in the Available Agent Skills index.',
      },
      'file': {
        'type': 'string',
        'description':
            'Optional companion file name (e.g. "LOGIC.md") to read instead of '
            'the skill body. Must be one of the files listed by the skill.',
      },
    },
    'required': ['name'],
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final rawName = (arguments['name'] as String?)?.trim() ?? '';
    if (rawName.isEmpty) {
      return 'Error: the "name" argument is required.';
    }

    final skill = _skills.findSkill(rawName);
    if (skill == null) {
      final available = _skills.indexableSkills.map((s) => s.name).toList();
      if (available.isEmpty) {
        return 'Error: skill "$rawName" not found, and no skills are currently '
            'active. Skills live in .nib/skills/<name>/SKILL.md (workspace) or '
            '~/.nib/skills/<name>/SKILL.md.';
      }
      return 'Error: skill "$rawName" not found. Available skills: '
          '${available.join(', ')}';
    }

    if (!skill.isEnabled) {
      return 'Error: skill "${skill.name}" is disabled. Re-enable it with '
          '/skills enable ${skill.name} before loading it.';
    }

    // A skill marked disable-model-invocation is excluded from the index and
    // must not be served even if the model guesses its name.
    if (skill.disableModelInvocation) {
      return 'Error: skill "${skill.name}" is reserved for direct human '
          'invocation and cannot be loaded by the model.';
    }

    final wantedFile = (arguments['file'] as String?)?.trim();
    if (wantedFile != null && wantedFile.isNotEmpty) {
      return _readCompanionFile(skill, wantedFile);
    }

    return _skills.formatSkillBody(skill);
  }

  /// Reads a companion file that belongs to [skill].
  ///
  /// Companion files often live outside the workspace (global skills live under
  /// `~/.nib/skills`), which `read_file` correctly refuses. This path stays
  /// sandboxed to the skill's own directory, so only files the skill actually
  /// ships can be read.
  Future<String> _readCompanionFile(Skill skill, String wantedFile) async {
    final base = p.basename(wantedFile);
    if (!skill.assets.contains(base)) {
      final list = skill.assets.isEmpty
          ? 'this skill ships no companion files'
          : 'available: ${skill.assets.join(', ')}';
      return 'Error: "$base" is not a companion file of skill '
          '"${skill.name}" ($list).';
    }

    final file = File(p.join(skill.directory, base));
    try {
      if (!await file.exists()) {
        return 'Error: companion file "$base" is missing from ${skill.directory}.';
      }
      final text = await file.readAsString();
      const cap = 20000;
      if (text.length > cap) {
        return '# ${skill.name}/$base\n\n'
            '${text.substring(0, cap)}\n\n[... ${text.length - cap} characters '
            'truncated ...]';
      }
      return '# ${skill.name}/$base\n\n$text';
    } catch (e) {
      return 'Error reading companion file "$base": $e';
    }
  }
}
