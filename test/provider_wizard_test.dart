import 'dart:io';
import 'package:nib/agent/config.dart';
import 'package:nib/ui/autocomplete.dart';
import 'package:nib/ui/provider_wizard.dart';
import 'package:test/test.dart';

void main() {
  group('Provider Wizard and Setup Tests', () {
    test('knownProviders includes standard providers', () {
      final ids = knownProviders.map((p) => p.id).toList();
      expect(ids, contains('anthropic'));
      expect(ids, contains('openai'));
      expect(ids, contains('openrouter'));
      expect(ids, contains('gemini'));
      expect(ids, contains('ollama'));
      expect(ids, contains('mock'));
    });

    test('command registry includes /setup', () {
      final hasSetup = AutoCompleter.commandRegistry.any(
        (c) => c.command == '/setup',
      );
      expect(hasSetup, isTrue);
    });

    test('ProviderConfig saves and reloads cleanly', () async {
      final tempDir = await Directory.systemTemp.createTemp('nib_config_test_');
      try {
        final configPath = '${tempDir.path}/config.json';
        final config = NibConfig(
          defaultProvider: 'anthropic',
          defaultModel: 'claude-3-7-sonnet-20250219',
          providers: {
            'anthropic': ProviderConfig(
              name: 'anthropic',
              model: 'claude-3-7-sonnet-20250219',
              baseUrl: 'https://api.anthropic.com',
              apiKey: 'sk-ant-test',
            ),
          },
        );

        await config.save(customPath: configPath);
        final loaded = await NibConfig.load(customPath: configPath);

        expect(loaded.defaultProvider, equals('anthropic'));
        expect(loaded.providers.containsKey('anthropic'), isTrue);
        expect(loaded.providers['anthropic']!.apiKey, equals('sk-ant-test'));
        expect(
          loaded.providers['anthropic']!.model,
          equals('claude-3-7-sonnet-20250219'),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
