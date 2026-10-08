import 'dart:io';
import 'package:nib/agent/config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Project instructions (AGENTS.md)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nib_agents_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('returns null when no instructions file exists', () async {
      expect(await NibConfig.loadProjectInstructions(tempDir.path), isNull);
    });

    test('loads AGENTS.md with a source header', () async {
      await File(
        p.join(tempDir.path, 'AGENTS.md'),
      ).writeAsString('# My Repo\n\nUse `pnpm test`.\n');

      final text = await NibConfig.loadProjectInstructions(tempDir.path);
      expect(text, isNotNull);
      expect(text, contains('## Project instructions (from AGENTS.md)'));
      expect(text, contains('Use `pnpm test`.'));
    });

    test('prefers AGENTS.md over CLAUDE.md', () async {
      await File(
        p.join(tempDir.path, 'AGENTS.md'),
      ).writeAsString('agents wins');
      await File(
        p.join(tempDir.path, 'CLAUDE.md'),
      ).writeAsString('claude loses');

      final text = await NibConfig.loadProjectInstructions(tempDir.path);
      expect(text, contains('agents wins'));
      expect(text, isNot(contains('claude loses')));
    });

    test('falls back to CLAUDE.md when AGENTS.md is absent', () async {
      await File(
        p.join(tempDir.path, 'CLAUDE.md'),
      ).writeAsString('claude only');

      final text = await NibConfig.loadProjectInstructions(tempDir.path);
      expect(text, contains('from CLAUDE.md'));
      expect(text, contains('claude only'));
    });

    test('skips an empty AGENTS.md and uses CLAUDE.md', () async {
      await File(p.join(tempDir.path, 'AGENTS.md')).writeAsString('   \n');
      await File(
        p.join(tempDir.path, 'CLAUDE.md'),
      ).writeAsString('non-empty wins');

      final text = await NibConfig.loadProjectInstructions(tempDir.path);
      expect(text, contains('non-empty wins'));
    });

    test('truncates oversized files and says so', () async {
      await File(p.join(tempDir.path, 'AGENTS.md')).writeAsString('x' * 5000);

      final text = await NibConfig.loadProjectInstructions(
        tempDir.path,
        maxChars: 1000,
      );
      expect(text, isNotNull);
      expect(text!.length, lessThan(1500));
      expect(text, contains('truncated'));
      expect(text, contains('Read the file directly'));
    });
  });
}
