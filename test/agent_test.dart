import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/thinking_level.dart';
import 'package:nib/agent/tool.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/event_stream.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/ai/provider.dart';
import 'package:nib/tools/list_dir_tool.dart';
import 'package:nib/tools/read_file_tool.dart';

void main() {
  late Directory testSessionsDir;

  setUp(() {
    testSessionsDir = Directory.systemTemp.createTempSync(
      'nib_agent_test_sess_',
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

    test(
      'ChatMessage persists thought field to JSON and excludes it from provider payloads',
      () {
        final msg = ChatMessage.assistant(
          'Here is the result',
          thought: 'Let me think through this step by step...',
        );

        // Verify toJson includes thought
        final json = msg.toJson();
        expect(
          json['thought'],
          equals('Let me think through this step by step...'),
        );
        expect(json['content'], equals('Here is the result'));

        // Verify fromJson deserializes thought
        final restored = ChatMessage.fromJson(json);
        expect(
          restored.thought,
          equals('Let me think through this step by step...'),
        );
        expect(restored.content, equals('Here is the result'));

        // Verify toOpenAiJson excludes thought so provider does not reject unknown field
        final openAiPayload = msg.toOpenAiJson();
        expect(openAiPayload.containsKey('thought'), isFalse);
        expect(openAiPayload['content'], equals('Here is the result'));
      },
    );

    test(
      'Agent turn with reasoning traces saves thought to session on disk',
      () async {
        final session = AgentSession();
        final agent = Agent(provider: MockProvider(), session: session);

        await agent.runTurn('test reasoning turn');

        expect(session.messages.length, greaterThanOrEqualTo(3));
        final assistantMsg = session.messages.lastWhere(
          (m) => m.role == Role.assistant,
        );
        expect(assistantMsg.thought, isNotNull);
        expect(assistantMsg.thought, isNotEmpty);

        // Verify saved to disk and reloadable
        await session.saveToDisk();
        final loaded = await AgentSession.loadFromDisk(session.id);
        expect(loaded, isNotNull);
        final loadedAssistantMsg = loaded!.messages.lastWhere(
          (m) => m.role == Role.assistant,
        );
        expect(loadedAssistantMsg.thought, equals(assistantMsg.thought));
      },
    );

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

  group('Runaway loop guard', () {
    /// Emits the same tool call every iteration until told to stop, optionally
    /// varying the tool's result so polling behaviour can be exercised.
    test(
      'stops when identical calls keep returning identical results',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('nib_spin_');
        await File(p.join(tempDir.path, 'stable.txt')).writeAsString('same');

        final agent = Agent(
          provider: _RepeatingToolProvider('read_file'),
          session: AgentSession(),
          tools: [ReadFileTool(workingDirectory: tempDir.path)],
          maxStuckIterations: 3,
        );

        final thoughts = <String>[];
        await agent.runTurn(
          'read it forever',
          callbacks: AgentCallbacks(onThoughtDelta: thoughts.add),
        );

        expect(
          thoughts,
          anyElement(contains('no progress')),
          reason: 'guard should report why it stopped',
        );
        // Threshold 3 allows three occurrences of the identical iteration; the
        // fourth trips the guard, so the tool runs exactly 4 times.
        expect(agent.session.toolExecutionsCount, equals(4));

        await tempDir.delete(recursive: true);
      },
    );

    test('does NOT stop when repeated calls return changing results', () async {
      final tempDir = await Directory.systemTemp.createTemp('nib_poll_');
      var calls = 0;

      // Same call each turn, but the file changes underneath, so output differs.
      final mutatingTool = _MutatingFileTool(tempDir.path, () => calls++);
      final agent = Agent(
        provider: _RepeatingToolProvider(mutatingTool.name),
        session: AgentSession(),
        tools: [mutatingTool],
        maxStuckIterations: 2,
        maxTurns: 6,
      );

      final thoughts = <String>[];
      await agent.runTurn(
        'poll it',
        callbacks: AgentCallbacks(onThoughtDelta: thoughts.add),
      );

      expect(
        thoughts,
        isNot(anyElement(contains('no progress'))),
        reason: 'changing output is real progress, not a spin',
      );
      expect(calls, greaterThan(2));

      await tempDir.delete(recursive: true);
    });

    test('the old 20-turn cap no longer truncates longer runs', () async {
      final tempDir = await Directory.systemTemp.createTemp('nib_long_');
      var calls = 0;
      final tool = _MutatingFileTool(tempDir.path, () => calls++);

      final agent = Agent(
        provider: _RepeatingToolProvider(tool.name),
        session: AgentSession(),
        tools: [tool],
        maxTurns: 0, // unbounded
        maxStuckIterations: 1000,
      );

      await agent.runTurn('keep going');
      expect(
        calls,
        greaterThan(20),
        reason: 'runs must be able to exceed the removed 20-iteration cap',
      );

      await tempDir.delete(recursive: true);
    });

    test(
      'catches an alternating A/B cycle that a streak counter misses',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('nib_cycle_');
        await File(p.join(tempDir.path, 'a.txt')).writeAsString('A');
        await File(p.join(tempDir.path, 'b.txt')).writeAsString('B');

        final agent = Agent(
          provider: _AlternatingToolProvider('read_file', const [
            'a.txt',
            'b.txt',
          ], limit: 40),
          session: AgentSession(),
          tools: [ReadFileTool(workingDirectory: tempDir.path)],
          maxStuckIterations: 3,
        );

        final thoughts = <String>[];
        await agent.runTurn(
          'flip forever',
          callbacks: AgentCallbacks(onThoughtDelta: thoughts.add),
        );

        expect(
          thoughts,
          anyElement(contains('no progress')),
          reason: 'A/B/A/B repeats are stuck work even though no streak forms',
        );
        // Each signature may occur 3 times before the 4th trips the guard: 7 calls.
        expect(agent.session.toolExecutionsCount, equals(7));

        await tempDir.delete(recursive: true);
      },
    );

    test('maxStuckIterations of 0 disables the guard', () async {
      final tempDir = await Directory.systemTemp.createTemp('nib_noguard_');
      await File(p.join(tempDir.path, 'stable.txt')).writeAsString('same');

      final agent = Agent(
        provider: _RepeatingToolProvider('read_file', limit: 12),
        session: AgentSession(),
        tools: [ReadFileTool(workingDirectory: tempDir.path)],
        maxStuckIterations: 0,
        hardIterationCap: 0,
      );

      final thoughts = <String>[];
      await agent.runTurn(
        'repeat',
        callbacks: AgentCallbacks(onThoughtDelta: thoughts.add),
      );

      expect(thoughts, isNot(anyElement(contains('no progress'))));
      // The provider stops itself after 12 calls, so the identical call runs
      // that many times with no guard interfering.
      expect(agent.session.toolExecutionsCount, equals(12));

      await tempDir.delete(recursive: true);
    });

    test('hardIterationCap backstops a provider that never settles', () async {
      final tempDir = await Directory.systemTemp.createTemp('nib_cap_');
      var calls = 0;
      final tool = _MutatingFileTool(tempDir.path, () => calls++);

      final agent = Agent(
        provider: _RepeatingToolProvider(tool.name, limit: 500),
        session: AgentSession(),
        tools: [tool],
        maxTurns: 0,
        maxStuckIterations: 1000, // never trips: results keep changing
        hardIterationCap: 5,
      );

      final thoughts = <String>[];
      await agent.runTurn(
        'spin',
        callbacks: AgentCallbacks(onThoughtDelta: thoughts.add),
      );

      expect(calls, equals(5));
      expect(thoughts, anyElement(contains('absolute limit')));

      await tempDir.delete(recursive: true);
    });
  });
}

/// Alternates between tool calls with different arguments each iteration.
class _AlternatingToolProvider implements LLMProvider {
  final String toolName;
  final List<String> paths;
  final int _limit;
  int _issued = 0;

  _AlternatingToolProvider(this.toolName, this.paths, {int limit = 60})
    : _limit = limit;

  @override
  String get name => 'Alternating Mock';

  @override
  String get model => 'alternating-mock';

  @override
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
    int? maxTokens,
    ThinkingLevel? thinkingLevel,
  }) async* {
    if (_issued++ >= _limit) {
      yield TextDeltaEvent('done');
      yield DoneEvent(finishReason: 'stop');
      return;
    }
    yield ToolCallCompleteEvent(
      ToolCall(
        id: 'call_$_issued',
        name: toolName,
        arguments: {'path': paths[_issued % paths.length]},
      ),
    );
    yield DoneEvent(finishReason: 'tool_calls');
  }
}

/// Streams the same tool call on every iteration; ends after [_limit] calls.
class _RepeatingToolProvider implements LLMProvider {
  final String toolName;
  final int _limit;
  int _issued = 0;

  _RepeatingToolProvider(this.toolName, {int limit = 60}) : _limit = limit;

  @override
  String get name => 'Repeat Mock';

  @override
  String get model => 'repeat-mock';

  @override
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
    int? maxTokens,
    ThinkingLevel? thinkingLevel,
  }) async* {
    if (_issued++ >= _limit) {
      yield TextDeltaEvent('done');
      yield DoneEvent(finishReason: 'stop');
      return;
    }
    yield ToolCallCompleteEvent(
      ToolCall(
        id: 'call_$_issued',
        name: toolName,
        arguments: const {'path': 'stable.txt'},
      ),
    );
    yield DoneEvent(finishReason: 'tool_calls');
  }
}

/// Reads a file whose contents change on every call, simulating a poll.
class _MutatingFileTool extends AgentTool {
  final String root;
  final int Function() onCall;

  _MutatingFileTool(this.root, this.onCall);

  @override
  String get name => 'poll_file';

  @override
  String get description => 'Read a file that changes each call.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'path': {'type': 'string'},
    },
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final n = onCall();
    final f = File(p.join(root, 'stable.txt'));
    await f.writeAsString('tick $n');
    return 'tick $n: ${await f.readAsString()}';
  }
}
