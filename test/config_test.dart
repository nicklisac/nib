import 'dart:convert';
import 'dart:io';
import 'package:nib/agent/config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Config-driven agent ceilings', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nib_config_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> writeConfig(Map<String, dynamic> json) async {
      await File(
        p.join(tempDir.path, 'config.json'),
      ).writeAsString(jsonEncode(json));
    }

    test('defaults keep the tool loop unbounded', () async {
      await writeConfig({
        'default_provider': 'exllama',
        'providers': {
          'exllama': {'model': 'm', 'base_url': 'http://localhost:5000/v1'},
        },
      });

      final config = await NibConfig.load(
        customPath: p.join(tempDir.path, 'config.json'),
      );
      expect(config.maxTurns, 0, reason: 'no fixed per-prompt cap by default');
      expect(config.maxStuckIterations, 5);
      expect(config.hardIterationCap, 200);
      expect(config.contextWindow, isNull);
    });

    test(
      'top-level context window and ceilings are read from the file',
      () async {
        await writeConfig({
          'default_provider': 'exllama',
          'context_window': 262144,
          'max_tokens': 16384,
          'max_turns': 40,
          'max_stuck_iterations': 8,
          'hard_iteration_cap': 500,
          'providers': {},
        });

        final config = await NibConfig.load(
          customPath: p.join(tempDir.path, 'config.json'),
        );
        expect(config.contextWindow, 262144);
        expect(config.maxTokens, 16384);
        expect(config.maxTurns, 40);
        expect(config.maxStuckIterations, 8);
        expect(config.hardIterationCap, 500);
      },
    );

    test('the active provider overrides the top-level values', () async {
      await writeConfig({
        'default_provider': 'exllama',
        'context_window': 32768,
        'max_stuck_iterations': 5,
        'providers': {
          'exllama': {
            'model': 'big',
            'context_window': 262144,
            'max_tokens': 16384,
            'max_stuck_iterations': 12,
          },
          'small': {'model': 'tiny', 'context_window': 8192},
        },
      });

      final config = await NibConfig.load(
        customPath: p.join(tempDir.path, 'config.json'),
      );
      final ex = config.providers['exllama']!;
      expect(ex.contextWindow, 262144);
      expect(ex.maxStuckIterations, 12);
      // Unset provider values fall through to the top level.
      expect(ex.maxTurns, isNull);
      expect(config.providers['small']!.contextWindow, 8192);
    });

    test('round-trips through save() without losing the ceilings', () async {
      final config = NibConfig(
        defaultProvider: 'exllama',
        contextWindow: 262144,
        maxStuckIterations: 7,
        providers: {
          'exllama': ProviderConfig(
            name: 'exllama',
            model: 'm',
            baseUrl: 'http://localhost:5000/v1',
            apiKey: '',
            contextWindow: 262144,
            hardIterationCap: 300,
          ),
        },
      );
      final path = p.join(tempDir.path, 'written', 'config.json');
      await config.save(customPath: path);

      final reloaded = await NibConfig.load(customPath: path);
      expect(reloaded.maxStuckIterations, 7);
      expect(reloaded.providers['exllama']!.hardIterationCap, 300);
      expect(reloaded.providers['exllama']!.contextWindow, 262144);
    });
  });
}
