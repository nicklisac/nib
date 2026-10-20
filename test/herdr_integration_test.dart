import 'package:nib/ui/herdr_integration.dart';
import 'package:test/test.dart';

void main() {
  group('HerdrIntegration tests', () {
    test('does nothing when HERDR_ENV is not 1', () async {
      final calls = <List<String>>[];
      final herdr = HerdrIntegration.forTesting(
        environment: {'HERDR_ENV': '0', 'HERDR_PANE_ID': 'w1:p1'},
        runner: (exe, args) async => calls.add([exe, ...args]),
      );

      expect(herdr.isHerdr, isFalse);
      await herdr.reportState('idle');
      herdr.release();

      expect(calls, isEmpty);
    });

    test('does nothing when HERDR_PANE_ID is missing', () async {
      final calls = <List<String>>[];
      final herdr = HerdrIntegration.forTesting(
        environment: {'HERDR_ENV': '1'},
        runner: (exe, args) async => calls.add([exe, ...args]),
      );

      expect(herdr.isHerdr, isTrue);
      expect(herdr.paneId, isNull);
      await herdr.reportState('idle');
      herdr.release();

      expect(calls, isEmpty);
    });

    test('reports state changes when running in Herdr', () async {
      final calls = <List<String>>[];
      final herdr = HerdrIntegration.forTesting(
        environment: {
          'HERDR_ENV': '1',
          'HERDR_PANE_ID': 'wP:p1',
          'HERDR_BIN_PATH': '/custom/herdr',
        },
        runner: (exe, args) async => calls.add([exe, ...args]),
      );

      expect(herdr.isHerdr, isTrue);
      expect(herdr.paneId, equals('wP:p1'));
      expect(herdr.herdrBin, equals('/custom/herdr'));

      // 1. Initial idle with resume
      herdr.reportIdle(withResume: true);
      // runner was async in reportState
      await Future<void>.delayed(Duration.zero);

      expect(calls.length, equals(1));
      expect(calls[0][0], equals('/custom/herdr'));
      expect(calls[0][1], equals('pane'));
      expect(calls[0][2], equals('report-agent'));
      expect(calls[0][3], equals('wP:p1'));
      expect(
        calls[0],
        containsAllInOrder([
          '--source',
          'nib',
          '--agent',
          'nib',
          '--state',
          'idle',
        ]),
      );
      expect(calls[0], containsAllInOrder(['--', 'nib', '--resume']));

      // 2. Working state
      calls.clear();
      herdr.reportWorking();
      await Future<void>.delayed(Duration.zero);

      expect(calls.length, equals(1));
      expect(calls[0], containsAllInOrder(['--state', 'working']));

      // 3. Duplicate working state is ignored
      calls.clear();
      herdr.reportWorking();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);

      // 4. Blocked state with message
      calls.clear();
      herdr.reportBlocked('Confirm rm -rf');
      await Future<void>.delayed(Duration.zero);

      expect(calls.length, equals(1));
      expect(
        calls[0],
        containsAllInOrder([
          '--state',
          'blocked',
          '--message',
          'Confirm rm -rf',
        ]),
      );

      // 5. Release
      calls.clear();
      herdr.release();

      expect(calls.length, equals(1));
      expect(calls[0][1], equals('pane'));
      expect(calls[0][2], equals('release-agent'));
      expect(calls[0][3], equals('wP:p1'));
      expect(
        calls[0],
        containsAllInOrder(['--source', 'nib', '--agent', 'nib']),
      );
    });
  });
}
