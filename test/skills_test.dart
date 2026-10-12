import 'dart:convert';
import 'dart:io';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/skills.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/tools/skill_tool.dart';
import 'package:nib/ui/autocomplete.dart';
import 'package:nib/ui/slash_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Skills Architecture & Slash Commands Test', () {
    late Directory tempDir;
    late Directory skillsDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nib_skills_test_');
      skillsDir = Directory(p.join(tempDir.path, '.nib', 'skills'));
      await skillsDir.create(recursive: true);

      // Create a dummy skill with YAML frontmatter
      final dummySkillDir = Directory(p.join(skillsDir.path, 'git-master'));
      await dummySkillDir.create();
      final dummySkillFile = File(p.join(dummySkillDir.path, 'SKILL.md'));
      await dummySkillFile.writeAsString('''---
name: Git Master
description: Expert git workflows, rebasing, and atomic commits.
---

Always write conventional commits (e.g. feat:, fix:).
Never force push to main.
''');

      // Create a second skill without frontmatter (heading fallback)
      final dummySkill2Dir = Directory(p.join(skillsDir.path, 'dart-pro'));
      await dummySkill2Dir.create();
      final dummySkill2File = File(p.join(dummySkill2Dir.path, 'SKILL.md'));
      await dummySkill2File.writeAsString('''# Dart Pro
Best practices for modern Dart 3 null-safety and patterns.

Always prefer records and pattern matching where clean.
''');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('SkillsManager discovers and parses skills correctly', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);

      expect(manager.skills.length, greaterThanOrEqualTo(2));

      final gitSkill = manager.findSkill('Git Master');
      expect(gitSkill, isNotNull);
      expect(gitSkill!.description, contains('Expert git workflows'));
      expect(gitSkill.content, contains('conventional commits'));
      expect(gitSkill.isWorkspace, isTrue);
      expect(gitSkill.isEnabled, isTrue);

      final dartSkill = manager.findSkill('dart-pro');
      expect(dartSkill, isNotNull);
      expect(
        dartSkill!.description,
        contains('Best practices for modern Dart'),
      );
      expect(dartSkill.content, contains('pattern matching'));
    });

    test('SkillsManager toggles skills and formats system prompt', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);

      // Lazy contract: the system prompt carries an index (name + description),
      // never the skill body.
      final initialPrompt = manager.formatForSystemPrompt();
      expect(initialPrompt, contains('# Available Agent Skills'));
      expect(initialPrompt, contains('- **Git Master**'));
      expect(initialPrompt, contains('- **dart-pro**'));
      expect(initialPrompt, isNot(contains('conventional commits')));
      expect(initialPrompt, isNot(contains('pattern matching')));

      // Toggle Git Master off
      final toggled = manager.toggleSkill('Git Master');
      expect(toggled, isTrue);
      expect(manager.findSkill('Git Master')!.isEnabled, isFalse);

      final promptAfterToggle = manager.formatForSystemPrompt();
      expect(promptAfterToggle, isNot(contains('- **Git Master**')));
      expect(promptAfterToggle, contains('- **dart-pro**'));

      // Re-enable Git Master
      manager.enableSkill('Git Master');
      expect(manager.findSkill('Git Master')!.isEnabled, isTrue);
    });

    test('SkillTool loads the full body on demand', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);

      final tool = SkillTool(skillsManager: manager);
      expect(tool.name, equals('skill'));

      final result = await tool.execute({'name': 'Git Master'});
      expect(result.content, contains('conventional commits'));
      expect(result.content, contains('# Skill: Git Master'));

      // Lookup is case-insensitive on the directory-name fallback too.
      final dartResult = await tool.execute({'name': 'DART-PRO'});
      expect(dartResult.content, contains('pattern matching'));

      final missing = await tool.execute({'name': 'nope'});
      expect(missing.content, contains('not found'));
      expect(missing.content, contains('Git Master'));

      final empty = await tool.execute({});
      expect(empty.content, contains('"name" argument is required'));
    });

    test('SkillTool refuses disabled skills', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);
      manager.disableSkill('dart-pro');

      final result = await SkillTool(
        skillsManager: manager,
      ).execute({'name': 'dart-pro'});
      expect(result.content, contains('disabled'));
    });

    test('Skill bodies list companion files and how to read them', () async {
      final manager = SkillsManager.instance;
      await File(
        p.join(skillsDir.path, 'git-master', 'COMMIT-FORMAT.md'),
      ).writeAsString('# Commit format\n');
      await manager.loadSkills(workspacePath: tempDir.path);

      final git = manager.findSkill('Git Master')!;
      expect(git.assets, contains('COMMIT-FORMAT.md'));

      final body = await SkillTool(
        skillsManager: manager,
      ).execute({'name': 'Git Master'});
      expect(body.content, contains('COMMIT-FORMAT.md'));
      // The body must not hand back an absolute path for read_file: global
      // skills live outside the workspace, which read_file cannot reach.
      expect(body.content, isNot(contains(skillsDir.path)));
      expect(body.content, contains('the `skill` tool'));
    });

    test(
      'the file argument reads a companion file through the skill tool',
      () async {
        final manager = SkillsManager.instance;
        await File(
          p.join(skillsDir.path, 'git-master', 'COMMIT-FORMAT.md'),
        ).writeAsString('# Commit format\nConventional commits only.\n');
        await manager.loadSkills(workspacePath: tempDir.path);

        final out = await SkillTool(
          skillsManager: manager,
        ).execute({'name': 'Git Master', 'file': 'COMMIT-FORMAT.md'});
        expect(out.content, contains('Conventional commits only.'));
      },
    );

    test('the file argument cannot escape the skill directory', () async {
      final manager = SkillsManager.instance;
      await File(
        p.join(skillsDir.path, 'git-master', 'COMMIT-FORMAT.md'),
      ).writeAsString('# Commit format\n');
      await manager.loadSkills(workspacePath: tempDir.path);

      final tool = SkillTool(skillsManager: manager);
      final out = await tool.execute({
        'name': 'Git Master',
        'file': '../../../../etc/passwd',
      });
      expect(out.content, contains('is not a companion file'));
      expect(out.content, isNot(contains('root:')));
    });

    test('disable-model-invocation skills stay out of the index', () async {
      final dir = Directory(p.join(skillsDir.path, 'user-only'));
      await dir.create();
      await File(p.join(dir.path, 'SKILL.md')).writeAsString('''---
name: user-only
description: Invoked by the human only.
disable-model-invocation: true
---

Hidden workflow body.
''');
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);

      expect(manager.findSkill('user-only'), isNotNull);
      expect(
        manager.indexableSkills.map((s) => s.name),
        isNot(contains('user-only')),
      );
      expect(manager.formatForSystemPrompt(), isNot(contains('user-only')));
    });

    test('disabled skills persist to .nib/skills.json and reload', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);
      manager.disableSkill('Git Master');
      await manager.saveOverrides();

      final file = File(p.join(tempDir.path, '.nib', 'skills.json'));
      expect(await file.exists(), isTrue);

      final reloaded = SkillsManager();
      await reloaded.loadSkills(workspacePath: tempDir.path);
      expect(reloaded.findSkill('Git Master')!.isEnabled, isFalse);
      expect(reloaded.findSkill('dart-pro')!.isEnabled, isTrue);
    });

    test(
      'AgentSession rebuildSystemPrompt dynamically injects active skills',
      () async {
        final manager = SkillsManager.instance;
        await manager.loadSkills(workspacePath: tempDir.path);

        final session = AgentSession();
        session.rebuildSystemPrompt(appendPrompt: 'Custom instructions');

        expect(session.systemPrompt, contains('# Available Agent Skills'));
        expect(session.systemPrompt, contains('- **Git Master**'));
        expect(session.systemPrompt, contains('Custom instructions'));
        expect(session.messages.first.content, equals(session.systemPrompt));
      },
    );

    test('AutoCompleter finds slash commands and metadata', () {
      final matches = AutoCompleter.completeSlashInfo('/sk');
      expect(matches.any((m) => m.command == '/skills'), isTrue);

      final resumeMatch = AutoCompleter.completeSlashInfo('/res');
      expect(resumeMatch.any((m) => m.command == '/resume'), isTrue);
    });

    test('SlashCommandHandler handles /skills commands cleanly', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);

      final session = AgentSession();
      final agent = Agent(
        provider: MockProvider(),
        session: session,
        tools: [],
      );

      final handler = SlashCommandHandler(agent);

      // /skills list
      final handledList = await handler.handle('/skills');
      expect(handledList, isTrue);

      // /skills toggle
      final handledToggle = await handler.handle('/skills toggle Git Master');
      expect(handledToggle, isTrue);
      expect(manager.findSkill('Git Master')!.isEnabled, isFalse);

      // /skills show
      final handledShow = await handler.handle('/skills show dart-pro');
      expect(handledShow, isTrue);
    });

    test('/skills run loads a human-only skill into the next turn', () async {
      final manager = SkillsManager.instance;
      final humanOnlyDir = Directory(p.join(skillsDir.path, 'map-it'));
      await humanOnlyDir.create();
      await File(p.join(humanOnlyDir.path, 'SKILL.md')).writeAsString('''---
name: map-it
description: Human-only workflow.
disable-model-invocation: true
---

Chart the map in three steps.
''');
      await manager.loadSkills(workspacePath: tempDir.path);

      // The model must not be able to load it on its own...
      final refusal = await SkillTool(
        skillsManager: manager,
      ).execute({'name': 'map-it'});
      expect(refusal.content, contains('reserved for direct human invocation'));

      // ...but the human can hand it over deliberately.
      final agent = Agent(provider: MockProvider(), session: AgentSession());
      final handler = SlashCommandHandler(agent);
      await handler.handle('/skills run map-it chart the backlog');

      expect(handler.pendingInvocation, isNotNull);
      expect(
        handler.pendingInvocation,
        contains('Chart the map in three steps.'),
      );
      expect(handler.pendingInvocation, contains('chart the backlog'));
      // Handing it over must not silently grant the model access to it.
      expect(manager.findSkill('map-it')!.disableModelInvocation, isTrue);
    });

    test('/skills run refuses a disabled or unknown skill', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);
      manager.disableSkill('Git Master');

      final agent = Agent(provider: MockProvider(), session: AgentSession());
      final handler = SlashCommandHandler(agent);
      await handler.handle('/skills run Git Master');
      expect(handler.pendingInvocation, isNull);

      await handler.handle('/skills run no-such-skill');
      expect(handler.pendingInvocation, isNull);
    });

    test(
      'read-only /skills subcommands never write .nib/skills.json',
      () async {
        final manager = SkillsManager.instance;
        await manager.loadSkills(workspacePath: tempDir.path);

        final agent = Agent(provider: MockProvider(), session: AgentSession());
        final handler = SlashCommandHandler(agent);
        final file = File(p.join(tempDir.path, '.nib', 'skills.json'));

        await handler.handle('/skills');
        await handler.handle('/skills list');
        await handler.handle('/skills show dart-pro');
        await handler.handle('/skills reload');
        await handler.handle('/skills bogus-subcommand');
        expect(
          await file.exists(),
          isFalse,
          reason: 'listing, showing, reloading and typos must not persist',
        );

        await handler.handle('/skills disable dart-pro');
        expect(await file.exists(), isTrue);
      },
    );

    test(
      'saveOverrides keeps entries for skills that are not loaded',
      () async {
        final manager = SkillsManager.instance;
        await manager.loadSkills(workspacePath: tempDir.path);

        final file = File(p.join(tempDir.path, '.nib', 'skills.json'));
        await file.writeAsString(
          '${jsonEncode({
            'disabled': ['Ghost Skill', 'Git Master'],
          })}\n',
        );
        await manager.loadSkills(workspacePath: tempDir.path);

        // Disabling another skill must not drop the entry for a skill this
        // checkout does not currently have.
        manager.disableSkill('dart-pro');
        await manager.saveOverrides();

        final disabled =
            ((jsonDecode(await file.readAsString()))['disabled'] as List)
                .cast<String>();
        expect(disabled, contains('Ghost Skill'));
        expect(disabled, contains('dart-pro'));
        expect(disabled, contains('Git Master'));

        // Re-enabling a loaded skill removes only its own entry.
        manager.enableSkill('Git Master');
        await manager.saveOverrides();

        final after =
            ((jsonDecode(await file.readAsString()))['disabled'] as List)
                .cast<String>();
        expect(after, isNot(contains('Git Master')));
        expect(after, contains('Ghost Skill'));
        expect(after, contains('dart-pro'));
      },
    );
  });
}
