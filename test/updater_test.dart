import 'dart:io';

import 'package:nib/agent/updater.dart';
import 'package:nib/ui/ansi.dart';
import 'package:test/test.dart';

void main() {
  group('NibUpdater Tests', () {
    test('currentVersion matches pubspec.yaml', () {
      // A literal pin here is what let the constant drift behind the pubspec
      // bump during v0.2.9; compare the two sources instead.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(match, isNotNull, reason: 'pubspec.yaml has no version: line');
      expect(
        NibUpdater.currentVersion,
        equals(match!.group(1)),
        reason:
            'lib/agent/updater.dart currentVersion must match pubspec '
            'version (nib update compares this against GitHub releases)',
      );
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
