import 'package:nib/agent/config.dart';
import 'package:test/test.dart';

void main() {
  group('resolveSecret', () {
    final env = {'OPENAI_API_KEY': 'sk-from-env', 'EMPTY_ONE': ''};

    test('a literal key is used as written', () {
      expect(resolveSecret('sk-abc123', env: env), equals('sk-abc123'));
      expect(resolveSecret('ollama', env: env), equals('ollama'));
      expect(resolveSecret('', env: env), equals(''));
    });

    test('a bare environment variable name is looked up', () {
      expect(resolveSecret('OPENAI_API_KEY', env: env), equals('sk-from-env'));
    });

    test(r'$NAME and ${NAME} are looked up too', () {
      expect(
        resolveSecret(r'$OPENAI_API_KEY', env: env),
        equals('sk-from-env'),
      );
      expect(
        resolveSecret(r'${OPENAI_API_KEY}', env: env),
        equals('sk-from-env'),
      );
    });

    test('a named but unset variable warns once and yields an empty key', () {
      final warnings = <String>[];
      for (var i = 0; i < 2; i++) {
        final value = resolveSecret(
          'NOT_SET_ANYWHERE_KEY',
          label: 'search_api_key',
          env: env,
          warn: warnings.add,
        );
        expect(value, isEmpty, reason: 'never send the name as the key');
      }
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('NOT_SET_ANYWHERE_KEY'));
      expect(warnings.single, contains('search_api_key'));
    });

    test('a variable that is set but empty counts as unset', () {
      final warnings = <String>[];
      expect(resolveSecret('EMPTY_ONE', env: env, warn: warnings.add), isEmpty);
      expect(warnings, hasLength(1));
    });
  });

  group('config keeps what was written', () {
    test(
      'saving never replaces an environment variable name with its value',
      () {
        final p = ProviderConfig.fromJson('openai', {
          'name': 'OpenAI',
          'model': 'gpt-4o',
          'api_key': 'OPENAI_API_KEY',
        });
        expect(p.toJson()['api_key'], equals('OPENAI_API_KEY'));
      },
    );
  });
}
