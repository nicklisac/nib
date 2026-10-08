import 'dart:io';
import 'package:test/test.dart';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/tools/list_dir_tool.dart';

void main() {
  group('Agent & Session Loop Test', () {
    test('Session manages messages and usage counters', () {
      final session = AgentSession();
      session.addSystemPromptIfNeeded();
      expect(session.messages.length, equals(1));
      expect(session.messages.first.role, equals(Role.system));

      session.addMessage(ChatMessage.user('Hi!'));
      expect(session.messages.length, equals(2));

      session.recordUsage(100, 50);
      expect(session.totalPromptTokens, equals(100));
      expect(session.totalCompletionTokens, equals(50));

      session.clearHistory();
      expect(session.messages.length, equals(1)); // keeps system prompt
    });

    test('Agent runs turns, invokes tools, and accumulates history', () async {
      final session = AgentSession();
      final tempDir = await Directory.systemTemp.createTemp('tau_test_');

      final agent = Agent(
        provider: MockProvider(),
        session: session,
        tools: [ListDirTool(workingDirectory: tempDir.path)],
      );

      final events = <String>[];
      await agent.runTurn(
        'list files in this directory',
        callbacks: AgentCallbacks(
          onTextDelta: (t) => events.add('text:$t'),
          onToolCallStarted: (tc) => events.add('tool_start:${tc.name}'),
          onToolCallFinished: (tc, res, dur) =>
              events.add('tool_done:${tc.name}'),
        ),
      );

      expect(events, anyElement(contains('tool_start:list_dir')));
      expect(events, anyElement(contains('tool_done:list_dir')));
      expect(session.toolExecutionsCount, equals(1));

      // Check messages: system, user, assistant (call), tool result, assistant (final)
      expect(session.messages.length, equals(5));

      await tempDir.delete(recursive: true);
    });

    test(
      'Agent turn cancellation preserves valid transcript and allows follow-up steering',
      () async {
        final session = AgentSession();
        final agent = Agent(provider: MockProvider(), session: session);

        final events = <String>[];
        // Turn 1: Cancel mid-generation
        await agent.runTurn(
          'first prompt',
          callbacks: AgentCallbacks(
            onTextDelta: (t) {
              events.add('text:$t');
              agent.cancel();
            },
          ),
        );

        expect(events, isNotEmpty);
        // Verify transcript has: system, user, assistant (with interrupted marker)
        expect(session.messages.length, equals(3));
        expect(session.messages[1].role, equals(Role.user));
        expect(session.messages[1].content, equals('first prompt'));
        expect(session.messages[2].role, equals(Role.assistant));
        expect(session.messages[2].content, contains('[Interrupted by user]'));

        // Turn 2: Follow-up steering instruction
        await agent.runTurn('steer instruction');
        // Messages should now be: system, user1, assistant1, user2, assistant2
        expect(session.messages.length, greaterThanOrEqualTo(5));
        expect(session.messages[3].role, equals(Role.user));
        expect(session.messages[3].content, equals('steer instruction'));
        expect(session.messages[4].role, equals(Role.assistant));
      },
    );
  });
}
