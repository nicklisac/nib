import 'dart:io';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/skills.dart';
import 'package:nib/ai/mock_provider.dart';
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
      expect(dartSkill!.description, contains('Best practices for modern Dart'));
      expect(dartSkill.content, contains('pattern matching'));
    });

    test('SkillsManager toggles skills and formats system prompt', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);

      final initialPrompt = manager.formatForSystemPrompt();
      expect(initialPrompt, contains('## Skill: Git Master'));
      expect(initialPrompt, contains('## Skill: dart-pro'));

      // Toggle Git Master off
      final toggled = manager.toggleSkill('Git Master');
      expect(toggled, isTrue);
      expect(manager.findSkill('Git Master')!.isEnabled, isFalse);

      final promptAfterToggle = manager.formatForSystemPrompt();
      expect(promptAfterToggle, isNot(contains('## Skill: Git Master')));
      expect(promptAfterToggle, contains('## Skill: dart-pro'));

      // Re-enable Git Master
      manager.enableSkill('Git Master');
      expect(manager.findSkill('Git Master')!.isEnabled, isTrue);
    });

    test('AgentSession rebuildSystemPrompt dynamically injects active skills', () async {
      final manager = SkillsManager.instance;
      await manager.loadSkills(workspacePath: tempDir.path);

      final session = AgentSession();
      session.rebuildSystemPrompt(appendPrompt: 'Custom instructions');

      expect(session.systemPrompt, contains('# Active Agent Skills'));
      expect(session.systemPrompt, contains('## Skill: Git Master'));
      expect(session.systemPrompt, contains('Custom instructions'));
      expect(session.messages.first.content, equals(session.systemPrompt));
    });

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
  });
}
