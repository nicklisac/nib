import 'package:nib/agent/compaction.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:test/test.dart';

void main() {
  group('Tau-Style Compaction Test', () {
    test('estimateTokens calculates approximate token counts', () {
      final messages = [
        ChatMessage.user('Hello world'),
        ChatMessage.assistant('Hi there! How can I help you today?'),
      ];
      final tokens = CompactionManager.estimateTokens(messages);
      expect(tokens, greaterThan(10));
    });

    test('compact preserves recent messages and inserts structured summary prefix', () async {
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
      expect(firstMsg.content, startsWith(CompactionManager.compactionSummaryPrefix));
      expect(firstMsg.content, contains('## Goal'));
      expect(firstMsg.content, contains('## Progress'));

      // The last kept message should be the 10th assistant answer
      expect(session.messages.last.content, equals('Assistant answer 10'));
    });
  });
}
