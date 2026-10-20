import 'package:nib/agent/updater.dart';
import 'package:nib/ui/ansi.dart';
import 'package:test/test.dart';

void main() {
  group('NibUpdater Tests', () {
    test('currentVersion matches 0.2.6', () {
      expect(NibUpdater.currentVersion, equals('0.2.6'));
    });

    test('Ansi.banner includes update notice when provided', () {
      final banner = Ansi.banner(
        model: 'test-model',
        provider: 'mock',
        workspace: '/workspace',
        updateNotice: 'Update available: v0.3.0. Run "nib update" to upgrade.',
      );
      expect(banner, contains('Update available: v0.3.0'));
      expect(banner, contains('nib update'));
    });

    test('Ansi.banner omits update notice when null or empty', () {
      final banner = Ansi.banner(
        model: 'test-model',
        provider: 'mock',
        workspace: '/workspace',
      );
      expect(banner, isNot(contains('Update available')));
    });
  });
}
