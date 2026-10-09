import 'package:nib/ui/screen_coordinator.dart';
import 'package:test/test.dart';

void main() {
  group('ScreenCoordinator tests', () {
    test('activate sets DECSTBM scroll region and establishes geometry', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);

      expect(coord.isSupported, isTrue);
      expect(coord.terminalLines, equals(30));
      expect(coord.terminalColumns, equals(80));

      coord.activate(initialPromptLines: 1);
      expect(coord.isActive, isTrue);
      expect(coord.promptLines, equals(1));
      expect(
        coord.footerLines,
        equals(4),
      ); // topSpacer(1) + queue(0) + prompt(1) + bottomSpacer(1) + status(1) = 4
      expect(coord.scrollBottom, equals(26));
      expect(coord.promptStartRow, equals(28));
      expect(coord.statusRow, equals(30));

      // Positions cursor at scrollBottom to stream up naturally
      expect(writes, contains('\x1B[26;1H'));

      // Scroll region applied to lines 1..26
      expect(writes, contains('\x1B[1;26r'));

      coord.deactivate();
      expect(coord.isActive, isFalse);
      expect(writes, contains('\x1B[r'));
    });

    test(
      'updatePromptLines dynamically resizes scroll margins when prompt grows and shrinks',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 80);
        coord.activate(initialPromptLines: 1);

        writes.clear();
        // Prompt grows to 3 lines (e.g. multi-line paste or wrapping)
        coord.updatePromptLines(3);
        expect(coord.promptLines, equals(3));
        expect(coord.footerLines, equals(6));
        expect(coord.scrollBottom, equals(24));
        expect(coord.promptStartRow, equals(26));
        expect(writes, contains('\x1B[1;24r'));

        writes.clear();
        // Prompt shrinks back to 1 line
        coord.updatePromptLines(1);
        expect(coord.promptLines, equals(1));
        expect(coord.footerLines, equals(4));
        expect(coord.scrollBottom, equals(26));
        expect(coord.promptStartRow, equals(28));
        expect(writes, contains('\x1B[1;26r'));
        // Freed rows 26 and 27 should be cleared
        expect(writes, contains('\x1B[26;1H\x1B[2K'));
        expect(writes, contains('\x1B[27;1H\x1B[2K'));
      },
    );

    test(
      'writeTranscript writes within scroll margins and restores human cursor',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 80);
        coord.activate(initialPromptLines: 1);

        writes.clear();
        coord.writeTranscript('Hello world\n');

        // Saves cursor, moves to transcript row, writes text, restores cursor
        expect(writes.first, equals('\x1B7'));
        expect(writes.last, equals('\x1B8'));
        expect(writes, contains('Hello world'));
        expect(writes, contains('\n'));
        expect(coord.transcriptRow, equals(26));
        expect(coord.transcriptCol, equals(1));
      },
    );

    test('renderStatus draws to bottom row without moving human cursor', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(initialPromptLines: 1);

      writes.clear();
      coord.renderStatus('Model: Qwen3.8 | ~1%');

      expect(writes.first, equals('\x1B7'));
      expect(writes.last, equals('\x1B8'));
      expect(writes, contains('\x1B[30;1H\x1B[2KModel: Qwen3.8 | ~1%'));
    });

    test('clearPromptArea clears all rows belonging to the prompt', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(
        initialPromptLines: 2,
      ); // prompt starts at row 27 (footer=5: 30-5+2=27)

      writes.clear();
      coord.clearPromptArea();

      expect(writes.first, equals('\x1B7'));
      expect(writes.last, equals('\x1B8'));
      expect(writes, contains('\x1B[27;1H\x1B[2K'));
      expect(writes, contains('\x1B[28;1H\x1B[2K'));
    });

    test(
      'positionPromptCursor positions cursor accurately inside prompt area',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 80);
        coord.activate(initialPromptLines: 2); // prompt starts at row 27

        writes.clear();
        coord.positionPromptCursor(1, 15); // row offset 1 -> row 28, col 15

        expect(writes, contains('\x1B[28;15H'));
      },
    );

    test(
      'updateTerminalSize reapplies DECSTBM scroll region with new dimensions',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 80);
        coord.activate(initialPromptLines: 1);

        writes.clear();
        coord.setTestDimensions(lines: 40, cols: 100);
        coord.updateTerminalSize();

        expect(coord.scrollBottom, equals(36));
        expect(writes, contains('\x1B[1;36r'));
      },
    );
  });
}
