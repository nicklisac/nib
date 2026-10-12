import 'dart:io';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/velocity_tracker.dart';
import 'package:nib/ai/event_stream.dart';
import 'package:test/test.dart';

void main() {
  group('GenerationVelocityTracker (Issue #28)', () {
    test(
      'does not start clock until first token arrives (bypasses TTFT)',
      () async {
        final tracker = GenerationVelocityTracker();
        tracker.startBurst();
        expect(tracker.isBurstActive, isFalse);
        expect(tracker.currentRate, isNull);

        // Simulate prefill latency / waiting for 1st token
        await Future.delayed(const Duration(milliseconds: 50));
        expect(tracker.isBurstActive, isFalse);

        // First token arrives
        tracker.recordDelta('Hello');
        expect(tracker.isBurstActive, isTrue);
      },
    );

    test(
      'reconciles estimated tokens with provider actual completion_tokens on DoneEvent',
      () async {
        final tracker = GenerationVelocityTracker();
        tracker.startBurst();

        tracker.recordDelta('chunk 1 ');
        tracker.recordDelta('chunk 2 ');
        await Future.delayed(const Duration(milliseconds: 60));

        // Provider returns ground truth completion_tokens = 50
        tracker.endBurst(actualTokens: 50);

        expect(tracker.isBurstActive, isFalse);
        expect(tracker.recentBursts.length, equals(1));
        final burst = tracker.recentBursts.first;
        expect(burst.tokens, equals(50));
        expect(burst.durationSeconds, greaterThan(0.05));
        expect(burst.rate, greaterThan(0.0));
      },
    );

    test('is completely isolated from tool execution wait times', () async {
      final tracker = GenerationVelocityTracker();

      // Generation burst 1
      tracker.startBurst();
      tracker.recordDelta('Tool call incoming');
      await Future.delayed(const Duration(milliseconds: 60));
      tracker.endBurst(actualTokens: 10);

      final burst1Duration = tracker.recentBursts.first.durationSeconds;

      // Tool executes for some time: generation clock is 100% stopped
      await Future.delayed(const Duration(milliseconds: 100));

      // Generation burst 2
      tracker.startBurst();
      tracker.recordDelta('Result is 42');
      await Future.delayed(const Duration(milliseconds: 60));
      tracker.endBurst(actualTokens: 10);

      expect(tracker.recentBursts.length, equals(2));
      final burst2Duration = tracker.recentBursts[1].durationSeconds;

      // Neither burst's duration includes the 100ms tool wait
      expect(burst1Duration, lessThan(0.09));
      expect(burst2Duration, lessThan(0.09));

      // Rolling rate combines only the generation times
      final rolling = tracker.rollingRate;
      expect(rolling, greaterThan(100.0));
    });

    test('maintains rolling FIFO window of at most 10 bursts', () {
      final tracker = GenerationVelocityTracker();

      for (int i = 1; i <= 15; i++) {
        tracker.startBurst();
        tracker.recordDelta('token');
        // Manually trigger endBurst with explicit duration
        tracker.endBurst(actualTokens: 10 * i, durationSeconds: 0.1);
      }

      // Max history is 10
      expect(tracker.recentBursts.length, equals(10));
    });

    test('reset clears all bursts and stopwatch', () {
      final tracker = GenerationVelocityTracker();
      tracker.startBurst();
      tracker.recordDelta('token');
      tracker.endBurst(actualTokens: 20, durationSeconds: 0.1);
      expect(tracker.recentBursts.isNotEmpty, isTrue);

      tracker.reset();
      expect(tracker.recentBursts, isEmpty);
      expect(tracker.isBurstActive, isFalse);
      expect(tracker.rollingRate, equals(0.0));
      expect(tracker.currentRate, isNull);
    });
  });

  group('Session Prompt Occupancy vs Spend & Cache Tracking (Issue #29)', () {
    test('tracks current active prompt tokens without cumulative explosion', () {
      final session = AgentSession();

      // Turn 1: 5000 prompt tokens, 100 completion tokens
      session.recordUsage(5000, 100, cachedTokens: 4000);
      expect(session.currentPromptTokens, equals(5000));
      expect(session.cachedPromptTokens, equals(4000));
      expect(session.totalCompletionTokens, equals(100));
      expect(session.cumulativePromptTokens, equals(5000));
      expect(session.cumulativeCachedTokens, equals(4000));

      // Turn 2: 5200 prompt tokens, 150 completion tokens
      session.recordUsage(5200, 150, cachedTokens: 4800);
      // currentPromptTokens stays at active occupancy (5200), does NOT sum to 10200
      expect(session.currentPromptTokens, equals(5200));
      expect(session.cachedPromptTokens, equals(4800));
      // totalCompletionTokens accumulates generated tokens (100 + 150 = 250)
      expect(session.totalCompletionTokens, equals(250));
      // cumulativePromptTokens tracks total billed across turns
      expect(session.cumulativePromptTokens, equals(10200));
      expect(session.cumulativeCachedTokens, equals(8800));
    });

    test(
      'persists and restores currentPromptTokens, cachedPromptTokens, and completion tokens',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'nib_session_meta_test_',
        );
        AgentSession.storageDirectoryOverride = tempDir.path;

        try {
          final session = AgentSession(id: 'meta_test_session');
          session.recordUsage(6400, 320, cachedTokens: 5000);
          await session.saveToDisk();

          final loaded = await AgentSession.loadFromDisk('meta_test_session');
          expect(loaded, isNotNull);
          expect(loaded!.currentPromptTokens, equals(6400));
          expect(loaded.totalPromptTokens, equals(6400));
          expect(loaded.cachedPromptTokens, equals(5000));
          expect(loaded.totalCompletionTokens, equals(320));
          expect(loaded.cumulativePromptTokens, equals(6400));
          expect(loaded.cumulativeCachedTokens, equals(5000));
        } finally {
          AgentSession.storageDirectoryOverride = null;
          await tempDir.delete(recursive: true);
        }
      },
    );

    test('DoneEvent carries cachedPromptTokens field cleanly', () {
      final event = DoneEvent(
        finishReason: 'stop',
        promptTokens: 4000,
        completionTokens: 250,
        cachedPromptTokens: 3200,
      );

      expect(event.finishReason, equals('stop'));
      expect(event.promptTokens, equals(4000));
      expect(event.completionTokens, equals(250));
      expect(event.cachedPromptTokens, equals(3200));
    });
  });
}
