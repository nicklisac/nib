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

  /// Static session facts pinned in an inverted band at the bottom of the
  /// footer, above the telemetry row. The band is chrome the transcript may
  /// never scroll through, and the scroll region always starts at row 1 so
  /// emulators keep feeding scrollback.
  group('pinned bottom facts band', () {
    final facts = ['Nib', 'exllama', 'Qwen3-Next', '\u2302 dart-tui'];

    test(
      'a band that fits takes one row above the status row, region from row 1',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 80);

        expect(coord.activate(band: facts), isTrue);

        expect(coord.bandLines, equals(1));
        expect(coord.scrollTop, equals(1));
        expect(coord.scrollBottom, equals(25));
        expect(coord.bandStartRow, equals(30));
        expect(coord.statusRow, equals(29));
        expect(coord.transcriptRow, equals(25));

        // Region spans row 1: a top margin below row 1 would stop the
        // emulator pushing scrolled lines into scrollback.
        expect(writes, contains('\x1B7\x1B[1;25r\x1B8'));
        // Band painted on row 30, the last row of the screen, with a plain
        // erase and themed segments: no background of its own.
        expect(
          writes.any((w) => w.contains('\x1B[30;1H\x1B[2K')),
          isTrue,
          reason: 'the band row must be painted with a plain erase',
        );
        expect(
          writes.any((w) => w.contains('\x1B[48;2;')),
          isFalse,
          reason: 'the band carries no background color',
        );
        expect(
          writes.any((w) => w.contains('\x1B[29;1H')),
          isFalse,
          reason:
              'the telemetry row above the band belongs to the ambient line',
        );
      },
    );

    test('the band never emits a newline, so it cannot scroll itself away', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(band: facts);

      writes.clear();
      coord.setBand([...facts, 'extra fact'], width: 80);
      coord.renderBand();

      // Nothing written between cursor-save and cursor-restore may contain a
      // newline: the band rows are outside the scroll region, and the human's
      // cursor is restored from wherever it was.
      final paints = writes.where(
        (w) => w.contains(';1H') && w.contains('\x1B[2K'),
      );
      expect(paints, isNotEmpty);
      for (final p in paints) {
        expect(p.contains('\n'), isFalse);
      }
    });

    test(
      'a band too wide for one row takes two rather than dropping a fact',
      () {
        final coord = ScreenCoordinator.forTesting(out: (_) {});
        coord.setTestDimensions(lines: 30, cols: 120);
        coord.activate(band: facts);

        coord.setBand([
          'Nib',
          'anthropic',
          'claude-3-7-sonnet-20250219',
          '\u2302 dart-tui',
        ], width: 40);

        expect(coord.bandLines, equals(2));
        expect(coord.bandStartRow, equals(29));
        // Every fact survives the split somewhere across the two rows.
        final joined = coord.bandContent.join(' ');
        for (final fact in [
          'Nib',
          'anthropic',
          'claude-3-7-sonnet-20250219',
          '\u2302 dart-tui',
        ]) {
          expect(joined, contains(fact));
        }
      },
    );

    test('a terminal too short to spare a row gets no band and reports it', () {
      final coord = ScreenCoordinator.forTesting(out: (_) {});
      coord.setTestDimensions(lines: 10, cols: 80);

      // footer(4) + minimum transcript(6) already fills a 10-row terminal.
      expect(coord.activate(band: facts), isFalse);
      expect(coord.bandLines, equals(0));
      expect(coord.scrollTop, equals(1));
      // The transcript keeps every row the footer does not need.
      expect(coord.scrollBottom, equals(6));
    });

    test('band yields its rows before the footer gives up any', () {
      final coord = ScreenCoordinator.forTesting(out: (_) {});
      coord.setTestDimensions(lines: 12, cols: 80);
      coord.activate(band: facts);

      // 12 rows: footer 4 without band, minimum transcript 6, so exactly 2
      // rows are spare and the band keeps one of them.
      expect(coord.bandLines, equals(1));
      expect(coord.scrollTop, equals(1));
      expect(coord.scrollBottom, equals(7));
      expect(coord.scrollBottom - coord.scrollTop + 1, greaterThanOrEqualTo(6));
    });

    test('a band collapsing from two rows to one clears the orphaned row', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 30);
      coord.activate(
        band: ['Nib', 'anthropic', 'a-long-model-name', '\u2302 dart-tui'],
      );
      expect(coord.bandLines, equals(2));
      expect(coord.bandStartRow, equals(29));

      writes.clear();
      coord.setBand(['Nib', 'exllama'], width: 80);

      expect(coord.bandLines, equals(1));
      expect(coord.bandStartRow, equals(30));
      // The released row (the band's old top) is erased with attributes
      // reset, so no band background survives on a row the status row moved
      // up into.
      expect(writes, contains('\x1B[29;1H\x1B[0m\x1B[2K'));
      expect(coord.scrollTop, equals(1));
    });

    test(
      'a resize re-fits the band and re-sets the region when rows change',
      () {
        final writes = <String>[];
        final coord = ScreenCoordinator.forTesting(out: writes.add);
        coord.setTestDimensions(lines: 30, cols: 30);
        coord.activate(
          band: ['Nib', 'anthropic', 'a-long-model-name', '\u2302 dart-tui'],
        );
        expect(coord.bandLines, equals(2));
        expect(writes, contains('\x1B7\x1B[1;24r\x1B8'));

        writes.clear();
        coord.setTestDimensions(lines: 30, cols: 120);
        coord.updateTerminalSize();

        expect(coord.bandLines, equals(1));
        expect(coord.scrollTop, equals(1));
        expect(writes, contains('\x1B7\x1B[1;25r\x1B8'));
      },
    );

    test(
      'a prompt growing to multi-line pushes the band out, not the transcript',
      () {
        final coord = ScreenCoordinator.forTesting(out: (_) {});
        coord.setTestDimensions(lines: 12, cols: 80);
        coord.activate(band: ['Nib', 'exllama', 'Qwen3', '\u2302 dart-tui']);
        expect(coord.bandLines, equals(1));
        final rowsBefore = coord.scrollBottom - coord.scrollTop + 1;

        coord.updatePromptLines(3);

        final rowsAfter = coord.scrollBottom - coord.scrollTop + 1;
        // The band surrenders its row so the transcript keeps its floor.
        expect(coord.bandLines, equals(0));
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

    test('the band comes back when the prompt shrinks again', () {
      final coord = ScreenCoordinator.forTesting(out: (_) {});
      coord.setTestDimensions(lines: 12, cols: 80);
      coord.activate(band: ['Nib', 'exllama', 'Qwen3', '\u2302 dart-tui']);
      coord.updatePromptLines(3);
      expect(coord.bandLines, equals(0));

      coord.updatePromptLines(1);
      expect(coord.bandLines, equals(1));
    });

    test('transcript stays a valid DECSTBM region at every terminal size', () {
      // DECSTBM requires top < bottom; a violated region is silently ignored
      // by the terminal, which shows up as output overwriting the footer. The
      // top is always 1 now, so the invariant is scrollBottom > 1. Swept
      // across sizes and prompt/queue growth rather than spot-checked.
      for (var lines = 10; lines <= 60; lines++) {
        for (var cols = 40; cols <= 160; cols += 10) {
          for (final band in [
            const <String>[],
            [
              'Nib',
              'exllama',
              'Qwen3-Next-Heavy',
              '\u2302 dart-tui',
              'compact at 111.6k',
            ],
          ]) {
            final coord = ScreenCoordinator.forTesting(out: (_) {});
            coord.setTestDimensions(lines: lines, cols: cols);
            coord.activate(band: band);
            for (final prompt in [1, 2, 4, 8]) {
              coord.updatePromptLines(prompt);
              for (final queue in [0, 1, 3, 6]) {
                coord.setQueued(List.generate(queue, (i) => 'queued $i'));
                expect(
                  coord.scrollTop,
                  equals(1),
                  reason:
                      'lines=$lines cols=$cols band=${band.length} '
                      'prompt=$prompt queue=$queue: region top must stay at '
                      'row 1 or scrollback dies',
                );
                expect(
                  coord.scrollTop,
                  lessThan(coord.scrollBottom),
                  reason:
                      'lines=$lines cols=$cols band=${band.length} '
                      'prompt=$prompt queue=$queue',
                );
                expect(
                  coord.scrollBottom,
                  lessThan(coord.bandStartRow),
                  reason:
                      'lines=$lines cols=$cols: transcript must never reach '
                      'a band row',
                );
              }
            }
          }
        }
      }
    });

    test('deactivate clears band rows and restores full margins', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(band: facts);

      writes.clear();
      coord.deactivate();

      expect(writes, contains('\x1B[30;1H\x1B[2K'));
      expect(writes, contains('\x1B[r'));
    });

    test('transcript output is clamped inside the region above the band', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(band: facts);

      writes.clear();
      coord.writeTranscript('hello\n');

      expect(writes, contains('\x1B[25;1H'));
      // Never positioned on the status row or the band row
      expect(
        writes.any((w) => RegExp(r'\x1B\[(29|30);\d+H').hasMatch(w)),
        isFalse,
      );
    });

    test('clearPromptArea stops above the band, never flashing its rows', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(initialPromptLines: 2, band: facts);

      writes.clear();
      coord.clearPromptArea();

      // Prompt rows are cleared; the status row (29) and band row (30) are not.
      expect(writes.any((w) => w.contains('\x1B[29;1H')), isFalse);
      expect(writes.any((w) => w.contains('\x1B[30;1H')), isFalse);
    });
  });

  group('transcript writer routing', () {
    test('writeLine lands in the region and advances the tracked row', () {
      final writes = <String>[];
      final coord = ScreenCoordinator.forTesting(out: writes.add);
      coord.setTestDimensions(lines: 30, cols: 80);
      coord.activate(band: ['Nib', 'exllama', 'Qwen3']);
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
        coord.activate(band: ['Nib', 'exllama', 'Qwen3']);
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
      coord.activate(band: ['Nib', 'exllama', 'Qwen3']);
      for (var i = 0; i < 20; i++) {
        coord.writeLine('menu row $i');
      }

      coord.rewind(40);

      expect(coord.transcriptRow, equals(coord.scrollTop));
    });
  });
}
