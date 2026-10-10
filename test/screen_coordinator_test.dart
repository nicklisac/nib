import 'package:nib/ui/screen_coordinator.dart';
import 'package:nib/ui/theme.dart';
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

      // Scroll region applied to lines 1..26 (no header was supplied, so the
      // transcript keeps row 1)
      expect(writes, contains('\x1B7\x1B[1;26r\x1B8'));

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
        expect(writes, contains('\x1B7\x1B[1;24r\x1B8'));

        writes.clear();
        // Prompt shrinks back to 1 line
        coord.updatePromptLines(1);
        expect(coord.promptLines, equals(1));
        expect(coord.footerLines, equals(4));
        expect(coord.scrollBottom, equals(26));
        expect(coord.promptStartRow, equals(28));
        expect(writes, contains('\x1B7\x1B[1;26r\x1B8'));
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
        expect(writes, contains('\x1B7\x1B[1;36r\x1B8'));
      },
    );

    test(
      'writeTranscript emits newline and carriage return when wrapping past terminalColumns',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 20);
        coord.activate(initialPromptLines: 1);

        writes.clear();
        // Send 25 characters without newline across a 20-col terminal
        coord.writeTranscript('1234567890123456789012345');

        expect(writes, contains('\n'));
        expect(writes, contains('\r'));
        expect(coord.transcriptRow, equals(26));
        // 20 chars on line 1, then wraps: 5 remaining chars on line 2 (cols 1..5), next is col 6
        expect(coord.transcriptCol, equals(6));

        // When another write arrives, it should position at row 26, col 6, not col 1
        writes.clear();
        coord.writeTranscript('ABC');
        expect(writes.first, equals('\x1B7'));
        expect(writes, contains('\x1B[26;6H'));
        expect(writes, contains('ABC'));
        expect(coord.transcriptCol, equals(9));
      },
    );
  });

  /// #27: static session facts pinned at the top, live telemetry alone at the
  /// bottom. The header is a band the transcript may never scroll through.
  group('pinned top header', () {
    final facts = ['Nib', 'exllama', 'Qwen3-Next', '⌂ dart-tui'];

    test(
      'a header that fits takes one row and pushes the scroll region down',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 80);

        expect(coord.activate(header: facts), isTrue);

        expect(coord.headerLines, equals(1));
        expect(coord.scrollTop, equals(2));
        expect(coord.scrollBottom, equals(26));
        expect(coord.transcriptRow, equals(26));

        // Region starts below the header, not at row 1
        expect(writes, contains('\x1B7\x1B[2;26r\x1B8'));
        // Header painted on row 1 only, with the theme inverted (text color
        // as background) so the band reads as chrome, not chat history.
        expect(writes.any((w) => w.contains('\x1B[2;1H\x1B[2KNib')), isFalse);
        final band = NibTheme.current.primary.bg;
        expect(
          writes.any((w) => w.contains('\x1B[1;1H$band\x1B[2K')),
          isTrue,
          reason: 'row 1 must be painted with the theme background active',
        );
      },
    );

    test('the header never emits a newline, so it cannot scroll itself away', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(header: facts);

      writes.clear();
      coord.setHeader([...facts, 'extra fact'], width: 80);
      coord.renderHeader();

      // Nothing written between cursor-save and cursor-restore may contain a
      // newline: row 1 is outside the scroll region, so a newline there scrolls
      // the header off screen.
      final paints = writes.where(
        (w) => w.contains(';1H') && w.contains('\x1B[2K'),
      );
      expect(paints, isNotEmpty);
      for (final p in paints) {
        expect(p.contains('\n'), isFalse);
      }
    });

    test(
      'a header too wide for one row takes two rather than dropping a fact',
      () {
        final coord = ScreenCoordinator.forTesting(out: (_) {});
        coord.setTestDimensions(lines: 30, cols: 40);
        coord.activate(header: facts);

        // Joined at 40 cols this run does not fit one row.
        coord.setHeader([
          'Nib',
          'anthropic',
          'claude-3-7-sonnet-20250219',
          '⌂ dart-tui',
        ], width: 40);

        expect(coord.headerLines, equals(2));
        expect(coord.scrollTop, equals(3));
        // Every fact survives the split somewhere across the two rows.
        final joined = coord.headerContent.join(' ');
        for (final fact in [
          'Nib',
          'anthropic',
          'claude-3-7-sonnet-20250219',
          '⌂ dart-tui',
        ]) {
          expect(joined, contains(fact));
        }
      },
    );

    test(
      'a terminal too short to spare a row gets no header and reports it',
      () {
        final coord = ScreenCoordinator.forTesting(out: (_) {});
        coord.setTestDimensions(lines: 10, cols: 80);

        // footer(4) + minimum transcript(6) already fills a 10-row terminal.
        expect(coord.activate(header: facts), isFalse);
        expect(coord.headerLines, equals(0));
        expect(coord.scrollTop, equals(1));
        // The transcript keeps every row the footer does not need.
        expect(coord.scrollBottom, equals(6));
      },
    );

    test('header yields its rows before the footer gives up any', () {
      final coord = ScreenCoordinator.forTesting(out: (_) {});
      coord.setTestDimensions(lines: 12, cols: 80);
      coord.activate(header: facts);

      // 12 rows: footer 4, minimum transcript 6, so exactly 2 rows are spare and
      // the header keeps one of them.
      expect(coord.headerLines, equals(1));
      expect(coord.scrollTop, equals(2));
      expect(coord.scrollBottom, equals(8));
      expect(coord.scrollBottom - coord.scrollTop + 1, greaterThanOrEqualTo(6));
    });

    test(
      'a header collapsing from two rows to one clears the orphaned row',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 30);
        coord.activate(
          header: ['Nib', 'anthropic', 'a-long-model-name', '⌂ dart-tui'],
        );
        expect(coord.headerLines, equals(2));

        writes.clear();
        coord.setHeader(['Nib', 'exllama'], width: 80);

        expect(coord.headerLines, equals(1));
        // The released row is erased with attributes reset, so no reverse
        // video survives on a row the transcript now owns.
        expect(writes, contains('\x1B[2;1H\x1B[0m\x1B[2K'));
        expect(coord.scrollTop, equals(2));
      },
    );

    test(
      'a resize re-fits the header and re-sets the region when rows change',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 30);
        coord.activate(
          header: ['Nib', 'anthropic', 'a-long-model-name', '⌂ dart-tui'],
        );
        expect(coord.headerLines, equals(2));
        expect(writes, contains('\x1B7\x1B[3;26r\x1B8'));

        writes.clear();
        coord.setTestDimensions(lines: 30, cols: 120);
        coord.updateTerminalSize();

        expect(coord.headerLines, equals(1));
        expect(coord.scrollTop, equals(2));
        expect(writes, contains('\x1B7\x1B[2;26r\x1B8'));
      },
    );

    test(
      'a prompt growing to multi-line pushes the header out, not the transcript',
      () {
        final coord = ScreenCoordinator.forTesting(out: (_) {});
        coord.setTestDimensions(lines: 12, cols: 80);
        coord.activate(header: ['Nib', 'exllama', 'Qwen3', '⌂ dart-tui']);
        expect(coord.headerLines, equals(1));
        final rowsBefore = coord.scrollBottom - coord.scrollTop + 1;

        coord.updatePromptLines(3);

        final rowsAfter = coord.scrollBottom - coord.scrollTop + 1;
        // The header surrenders its row so the transcript keeps its floor.
        expect(coord.headerLines, equals(0));
        expect(
          rowsAfter,
          greaterThanOrEqualTo(rowsBefore - 2),
          reason: 'transcript must not lose more rows than the prompt grew by',
        );
        expect(
          rowsAfter,
          greaterThanOrEqualTo(6),
          reason: 'the transcript floor holds while the prompt grows',
        );
      },
    );

    test('the header comes back when the prompt shrinks again', () {
      final coord = ScreenCoordinator.forTesting(out: (_) {});
      coord.setTestDimensions(lines: 12, cols: 80);
      coord.activate(header: ['Nib', 'exllama', 'Qwen3', '⌂ dart-tui']);
      coord.updatePromptLines(3);
      expect(coord.headerLines, equals(0));

      coord.updatePromptLines(1);
      expect(coord.headerLines, equals(1));
    });

    test('transcript stays a valid DECSTBM region at every terminal size', () {
      // DECSTBM requires top < bottom; a violated region is silently ignored by
      // the terminal, which shows up as output overwriting the footer. Swept
      // across sizes and prompt/queue growth rather than spot-checked.
      for (var lines = 10; lines <= 60; lines++) {
        for (var cols = 40; cols <= 160; cols += 10) {
          for (final header in [
            const <String>[],
            [
              'Nib',
              'exllama',
              'Qwen3-Next-Heavy',
              '⌂ dart-tui',
              'compact at 111.6k',
            ],
          ]) {
            final coord = ScreenCoordinator.forTesting(out: (_) {});
            coord.setTestDimensions(lines: lines, cols: cols);
            coord.activate(header: header);
            for (final prompt in [1, 2, 4, 8]) {
              coord.updatePromptLines(prompt);
              for (final queue in [0, 1, 3, 6]) {
                coord.setQueued(List.generate(queue, (i) => 'queued $i'));
                expect(
                  coord.scrollTop,
                  lessThan(coord.scrollBottom),
                  reason:
                      'lines=$lines cols=$cols header=${header.length} '
                      'prompt=$prompt queue=$queue',
                );
              }
            }
          }
        }
      }
    });

    test('deactivate clears header rows and restores full margins', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(header: facts);

      writes.clear();
      coord.deactivate();

      expect(writes, contains('\x1B[1;1H\x1B[2K'));
      expect(writes, contains('\x1B[r'));
    });

    test('transcript output is clamped inside the region below the header', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(header: facts);

      writes.clear();
      coord.writeTranscript('hello\n');

      expect(writes, contains('\x1B[26;1H'));
      // Never positioned on the header row
      expect(writes.any((w) => RegExp(r'\x1B\[1;\d+H').hasMatch(w)), isFalse);
    });
  });

  /// Slash commands and the session picker write through the coordinator while
  /// it owns the screen. These guard the /history-invisible and /resume-menu-
  /// below-the-input regressions: output must enter the scroll region at the
  /// tracked row, and a menu's rewind must never reach into the footer.
  group('transcript writer routing', () {
    test('writeLine lands in the region and advances the tracked row', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(header: ['Nib', 'exllama', 'Qwen3']);
      // activate parks the cursor at scrollBottom; a newline there scrolls the
      // region and the tracked row clamps rather than running past the bottom.
      final rowBefore = coord.transcriptRow;
      expect(rowBefore, equals(coord.scrollBottom));

      writes.clear();
      coord.writeLine('Session Transcript Summary:');

      expect(coord.transcriptRow, equals(coord.scrollBottom));
      expect(
        writes.any((w) => w.contains('Session Transcript Summary:')),
        isTrue,
      );
      // Written inside the region, not at the footer where the raw cursor sits.
      expect(writes.any((w) => w.contains('\x1B[$rowBefore;1H')), isTrue);
    });

    test(
      'rewind returns the cursor to the block and clears only region rows',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 80);
        coord.activate(header: ['Nib', 'exllama', 'Qwen3']);
        for (var i = 0; i < 8; i++) {
          coord.writeLine('menu row $i');
        }
        expect(coord.transcriptRow, equals(coord.scrollBottom));

        writes.clear();
        coord.rewind(8);

        expect(coord.transcriptRow, equals(coord.scrollBottom - 8));
        expect(
          writes.any((w) => w.contains('\x1B[J')),
          isFalse,
          reason: 'ESC[J would clear into the pinned footer',
        );
        for (final w in writes.where((w) => w.contains('\x1B[2K'))) {
          final row = RegExp(r'\x1B\[(\d+);1H').firstMatch(w)!.group(1)!;
          final n = int.parse(row);
          expect(n, lessThanOrEqualTo(coord.scrollBottom));
          expect(n, greaterThanOrEqualTo(coord.scrollTop));
        }
      },
    );

    test('rewind clamps at the region top when the block scrolled away', () {
      final coord = ScreenCoordinator.forTesting(out: (_) {});
      coord.setTestDimensions(lines: 14, cols: 80);
      coord.activate(header: ['Nib', 'exllama', 'Qwen3']);
      for (var i = 0; i < 20; i++) {
        coord.writeLine('menu row $i');
      }

      coord.rewind(40);

      expect(coord.transcriptRow, equals(coord.scrollTop));
    });
  });
}
