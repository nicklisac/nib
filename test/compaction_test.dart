import 'dart:io';
import 'package:nib/agent/compaction.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:test/test.dart';

void main() {
  late Directory testSessionsDir;

  setUp(() {
    testSessionsDir = Directory.systemTemp.createTempSync(
      'nib_compaction_test_sess_',
    );
    AgentSession.storageDirectoryOverride = testSessionsDir.path;
  });

  tearDown(() {
    AgentSession.storageDirectoryOverride = null;
    try {
      if (testSessionsDir.existsSync()) {
        testSessionsDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Tau-Style Compaction Test', () {
    test('estimateTokens calculates approximate token counts', () {
      final messages = [
        ChatMessage.user('Hello world'),
        ChatMessage.assistant('Hi there! How can I help you today?'),
      ];
      final tokens = CompactionManager.estimateTokens(messages);
      expect(tokens, greaterThan(10));
    });

    test(
      'compact preserves recent messages and inserts structured summary prefix',
      () async {
        final session = AgentSession();
        // Add 10 messages
        for (int i = 1; i <= 10; i++) {
          session.addMessage(ChatMessage.user('User question $i'));
          session.addMessage(ChatMessage.assistant('Assistant answer $i'));
        }

        expect(session.messages.length, equals(20));

        final mockProvider = MockProvider();
        final result = await CompactionManager.compact(
          session: session,
          provider: mockProvider,
          keepRecentCount: 4,
        );

        expect(result.success, isTrue);
        expect(result.replacedMessageCount, equals(16));
        // Resulting messages: 1 summary message + 4 kept recent messages = 5
        expect(session.messages.length, equals(5));

        final firstMsg = session.messages.first;
        expect(firstMsg.role, equals(Role.user));
        expect(
          firstMsg.content,
          startsWith(CompactionManager.compactionSummaryPrefix),
        );
        expect(firstMsg.content, contains('## Goal'));
        expect(firstMsg.content, contains('## Progress'));

        // The last kept message should be the 10th assistant answer
        expect(session.messages.last.content, equals('Assistant answer 10'));
      },
    );

    test('shouldAutoCompact respects custom context window limits', () {
      final session = AgentSession();
      for (int i = 0; i < 10; i++) {
        session.addMessage(ChatMessage.user('A' * 400));
        session.addMessage(ChatMessage.assistant('B' * 400));
      }
      // With default 128k context window, should not compact
      expect(CompactionManager.shouldAutoCompact(session), isFalse);

      // With custom 2500 token window and 500 reserve, should compact
      expect(
        CompactionManager.shouldAutoCompact(
          session,
          contextWindow: 2500,
          reserve: 500,
        ),
        isTrue,
      );
    });
  });
}
