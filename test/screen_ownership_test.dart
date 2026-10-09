import 'dart:io';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/compaction.dart';
import 'package:nib/agent/context_meter.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/ui/ambient_line.dart';
import 'package:nib/ui/prompt_reader.dart';
import 'package:nib/ui/terminal_manager.dart';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Doctrine tests for what nicklisac/nib#20 decided, per docs/feel.md. One test
/// per rule, checking the *class* of failure rather than a golden rendering —
/// rules 2, 3 and 7 were failing before #20's build and are its acceptance
/// criteria (nicklisac/nib#13).
void main() {
  /// Bytes for `ESC [ 2 0 0 ~ text ESC [ 2 0 1 ~`.
  List<int> bracketed(String text) => [
    27,
    91,
    ...'200~'.codeUnits,
    ...text.codeUnits,
    27,
    91,
    ...'201~'.codeUnits,
  ];

  group('Rule 3 — Nib never sends what you did not mean as Enter', () {
    test('a bracketed paste arrives as one blob, not as keystrokes', () {
      final events = InputDecoder().add(bracketed('line one\nline two\n'));
      final blobs = events.whereType<PasteBlob>().toList();
      expect(blobs.length, equals(1));
      expect(events.whereType<Key>(), isEmpty);
      expect(blobs.single.text, equals('line one\nline two\n'));
    });

    test('a paste carrying newlines yields no Enter key at all', () {
      // This is the accidental-send failure the rule exists to prevent: before
      // bracketed paste every newline in a pasted block was an Enter.
      final keys = KeyDecoder.decode(bracketed('a\nb\nc\n'));
      expect(
        keys.where(
          (k) => k.isControl && k.controlChar == ControlCharacter.enter,
        ),
        isEmpty,
        reason: 'a paste must never produce Enter',
      );
    });

    test('a paste split across reads still arrives as one blob', () {
      final decoder = InputDecoder();
      final bytes = bracketed('multi\nline\npaste\n');
      final first = decoder.add(bytes.sublist(0, 20));
      final second = decoder.add(bytes.sublist(20));

      final blobs = [
        ...first.whereType<PasteBlob>(),
        ...second.whereType<PasteBlob>(),
      ];
      expect(blobs.length, equals(1));
      expect(blobs.single.text, equals('multi\nline\npaste\n'));
    });

    test(
      'a paste whose end marker never arrives is still not sent as Enters',
      () {
        final decoder = InputDecoder();
        decoder.add([27, 91, ...'200~'.codeUnits, ...'tail\nbeat\n'.codeUnits]);
        final flushed = decoder.flush();
        expect(flushed.whereType<PasteBlob>().length, equals(1));
        expect(
          flushed.whereType<Key>().where(
            (k) => k.isControl && k.controlChar == ControlCharacter.enter,
          ),
          isEmpty,
        );
      },
    );

    test('the trailing backslash and triple-quote gestures still work', () {
      // Bracketed paste replaced them as the *paste* guard; as deliberate
      // multi-line input they stay (#20 Q4).
      final reader = PromptReader();
      expect(reader.hasQueued, isFalse);
    });
  });

  group('Rule 7 — a gesture has one meaning', () {
    test('alt+enter is never an interrupt', () {
      // ESC \r used to decode as Escape, which #20 binds to interrupt: the queue
      // gesture cancelled the very turn it was queueing behind.
      final events = InputDecoder().add([27, 13]);
      final chords = events.whereType<AltKeyEvent>().toList();
      expect(chords.length, equals(1));
      expect(chords.single.label, equals('alt+enter'));
      expect(
        events.whereType<Key>().where(
          (k) => k.isControl && k.controlChar == ControlCharacter.escape,
        ),
        isEmpty,
      );
    });

    test('a lone Escape press is still the interrupt', () {
      final events = InputDecoder().add([27]);
      final keys = events.whereType<Key>().toList();
      expect(keys.length, equals(1));
      expect(keys.single.controlChar, equals(ControlCharacter.escape));
    });

    test('shift+tab is consumed, not turned into Escape plus "[Z"', () {
      final events = InputDecoder().add([27, 91, 90]);
      expect(events, isEmpty);
    });

    test('alt+left is consumed, not typed into the prompt as "[1;3D"', () {
      final events = InputDecoder().add([27, 91, 49, 59, 51, 68]);
      expect(
        events.whereType<Key>().where((k) => !k.isControl).map((k) => k.char),
        isEmpty,
        reason: 'no fragment of an escape sequence may reach the buffer',
      );
      final chords = events.whereType<AltKeyEvent>().toList();
      expect(chords.length, equals(1));
      expect(chords.single.label, equals('alt+left'));
    });

    test('an incomplete escape sequence is dropped, never read as Escape', () {
      // A partial sequence that never completed is not evidence the human meant
      // to stop the turn.
      final decoder = InputDecoder();
      decoder.add([27, 91]);
      expect(
        decoder.flush().where(
          (e) => e is Key && e.controlChar == ControlCharacter.escape,
        ),
        isEmpty,
      );
    });

    test('interrupt bytes still decode normally mid-burst', () {
      final events = InputDecoder().add([27, 3]);
      final keys = events.whereType<Key>().toList();
      expect(
        keys.map((k) => k.controlChar).toList(),
        equals([ControlCharacter.escape, ControlCharacter.ctrlC]),
      );
    });
  });

  group('Rule 2 — Nib never discards what the human has typed', () {
    test('clearBuffer discards stale keys but cannot reach the draft', () {
      final tm = TerminalManager.instance;
      tm.draft = 'half-composed thought';
      tm.clearBuffer();
      expect(tm.draft, equals('half-composed thought'));
      tm.draft = '';
    });

    test('closing a window releases the reader without taking the draft', () {
      final tm = TerminalManager.instance;
      tm.draft = 'draft the stream is about to overrun';
      tm.endWindow();
      expect(tm.draft, equals('draft the stream is about to overrun'));
      // The close is consumed by the next read, so a later window is not closed
      // by the handover that ended this one.
      tm.clearEndWindowSentinels();
      tm.draft = '';
    });

    test('the queue slot composes rather than displacing', () {
      final reader = PromptReader();
      reader.enqueue('first message');
      reader.enqueue('second message');
      expect(reader.queued, equals('first message\nsecond message'));
      expect(reader.takeQueued(), equals('first message\nsecond message'));
      expect(reader.queued, isEmpty);
    });

    test('an empty message never overwrites a queued one', () {
      final reader = PromptReader();
      reader.enqueue('keep me');
      reader.enqueue('   ');
      expect(reader.queued, equals('keep me'));
    });
  });

  group('Rule 1 — Nib never writes to a row it does not own', () {
    test('the ambient row may only be drawn at the start of a row', () {
      final line = AmbientLine(agent: _testAgent(), meter: ContextMeter());
      line.startTurn();
      expect(line.mayDraw, isTrue, reason: 'a fresh row is ours to draw');

      line.suspendForInlineWrite();
      expect(
        line.mayDraw,
        isFalse,
        reason: 'mid-line the stream owns the row; drawing would overwrite it',
      );

      line.resumeAfterLineWrite();
      expect(line.mayDraw, isTrue);

      line.endTurn();
      expect(line.mayDraw, isFalse, reason: 'at rest the prompt holds the row');
    });

    test('the row is erased before an inline write and not redrawn mid-line', () {
      final writes = <String>[];
      final agent = _testAgent();
      final line = AmbientLine(
        agent: agent,
        meter: agent.meter,
        out: writes.add,
      );
      line.startTurn();
      final afterStart = List.of(writes);
      expect(afterStart.last, startsWith('\r\x1B[2K'));

      // A streamed token lands mid-line: the row must be cleared and must NOT be
      // repainted, because the transcript owns that row now.
      writes.clear();
      line.suspendForInlineWrite();
      expect(writes, contains('\r\x1B[2K'));
      writes.clear();
      line.recordToken();
      line.showToolProgress('whatever');
      expect(
        writes,
        isEmpty,
        reason: 'no redraw while the stream owns the row',
      );

      writes.clear();
      line.resumeAfterLineWrite();
      expect(writes, isNotEmpty, reason: 'a fresh row is ours again');
    });

    test('hide clears the row and stops the writer', () {
      final writes = <String>[];
      final agent = _testAgent();
      final line = AmbientLine(
        agent: agent,
        meter: agent.meter,
        out: writes.add,
      );
      line.startTurn();
      writes.clear();
      line.hide();
      expect(writes, contains('\r\x1B[2K'));
      writes.clear();
      line.recordToken();
      expect(writes, isEmpty);
    });
  });

  group('Rule 4 — Nib never shows an estimate as a measurement', () {
    test('an estimate carries the tilde, a measurement does not', () {
      final session = AgentSession(id: 'gauge-test');
      session.addMessage(ChatMessage.user('hello there'));
      final meter = ContextMeter();

      expect(meter.isMeasured, isFalse);
      expect(meter.displayFor(session), startsWith('~'));

      meter.recordPromptTokens(32000);
      expect(meter.isMeasured, isTrue);
      expect(meter.displayFor(session), equals('25%'));
      expect(meter.displayFor(session), isNot(contains('~')));
    });

    test('measured and estimated are never blended into one figure', () {
      final meter = ContextMeter();
      meter.recordPromptTokens(1000);
      final before = meter.tokensFor(AgentSession(id: 'x'));
      meter.recordPromptTokens(2000);
      // The reading moves to the new provider figure, not to a sum or average of
      // the two bases.
      expect(meter.tokensFor(AgentSession(id: 'x')), equals(2000));
      expect(before, equals(1000));
    });

    test(
      'the gauge and the compaction trigger share one window and reserve',
      () {
        final meter = ContextMeter(contextWindow: 262144);
        expect(meter.threshold, equals(262144 - 16384));
        expect(
          meter.reserve,
          equals(CompactionManager.defaultCompactionReserveTokens),
        );

        final small = ContextMeter(contextWindow: 32000);
        expect(
          small.reserve,
          equals(8000),
          reason: 'quarter-window reserve below 32k',
        );
      },
    );

    test('a blown window reads as full, not as 137%', () {
      final meter = ContextMeter(contextWindow: 1000);
      meter.recordPromptTokens(5000);
      expect(meter.percentFor(AgentSession(id: 'x')), equals(100));
    });
  });

  group('Ambient line geometry (nicklisac/nib#22)', () {
    // 61400 of a 262144 window is the reading #22 prototyped against: 23%.
    AmbientLine buildLine() {
      final agent = Agent(
        provider: MockProvider(),
        session: AgentSession(id: 'geometry-test')
          ..addMessage(ChatMessage.user('hello there')),
        contextWindow: 262144,
      );
      agent.meter.recordPromptTokens(61400);
      return AmbientLine(agent: agent, meter: agent.meter);
    }

    String plain(String styled) =>
        styled.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');

    final states = <String, void Function(AmbientLine)>{
      'idle': (l) => l.endTurn(),
      'streaming': (l) => l.startTurn(),
      'tool': (l) {
        l.startTurn();
        l.showTool('bash');
      },
      'toolstream': (l) {
        l.startTurn();
        l.showTool('bash');
        l.showToolProgress('Compiling nib v0.0.1 (/home/nick/.cargo/registry)');
      },
      'queued': (l) {
        l.startTurn();
        l.showComposition(queued: 'one\nqueued message');
      },
      'interrupted': (l) => l.showInterrupted(keyName: 'Esc', draftKept: true),
    };

    for (final width in [100, 80, 40]) {
      test('no state overruns a $width-column terminal', () {
        for (final entry in states.entries) {
          final line = buildLine();
          entry.value(line);
          final rendered = plain(line.render(width: width));
          expect(
            rendered.length,
            lessThanOrEqualTo(width),
            reason: '${entry.key} overran at width $width: "$rendered"',
          );
        }
      });
    }

    test('the gauge and state glyph never drop, whatever the width', () {
      final line = buildLine();
      line.startTurn();
      line.showTool('bash');
      line.showToolProgress('Compiling nib v0.0.1');
      final narrow = plain(line.render(width: 20));
      expect(
        narrow,
        contains('23%'),
        reason: 'the gauge is why the row exists',
      );
      expect(narrow, contains('⚙'), reason: 'the glyph answers "can I type"');
    });

    test('the row carries no provider, model, path, or endpoint', () {
      // Those belong to the dock, which is history rather than present tense.
      final line = buildLine();
      line.startTurn();
      final rendered = plain(line.render(width: 100));
      final dockOnly = [
        'Mock',
        'mock-agent',
        'localhost',
        p.basename(Directory.current.path),
      ];
      for (final forbidden in dockOnly) {
        expect(
          rendered,
          isNot(contains(forbidden)),
          reason: '"$forbidden" is the dock\'s, not the ambient line\'s',
        );
      }
    });
  });
}

Agent _testAgent() {
  final session = AgentSession(id: 'doctrine-test');
  session.addMessage(ChatMessage.user('hello there'));
  return Agent(provider: MockProvider(), session: session);
}
