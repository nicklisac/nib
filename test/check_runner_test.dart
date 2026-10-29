import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/check_runner.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/thinking_level.dart';
import 'package:nib/agent/tool.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/event_stream.dart';
import 'package:nib/ai/provider.dart';
import 'package:nib/tools/check_status_tool.dart';

/// Scripted provider that snapshots the transcript it is called with, so
/// tests can assert exactly what the model saw at each call.
class _ScriptedProvider implements LLMProvider {
  final List<List<StreamEvent> Function(List<ChatMessage> messages)> steps;
  int _index = 0;
  final captured = <List<ChatMessage>>[];

  _ScriptedProvider(this.steps);

  @override
  String get name => 'ScriptedMock';
  @override
  String get model => 'scripted-mock';

  @override
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
    int? maxTokens,
    ThinkingLevel? thinkingLevel,
  }) async* {
    captured.add(List.from(messages));
    if (_index >= steps.length) {
      yield TextDeltaEvent('done');
      yield DoneEvent(finishReason: 'stop');
      return;
    }
    for (final e in steps[_index++](messages)) {
      yield e;
    }
  }
}

class _FakeEditTool extends AgentTool {
  @override
  String get name => 'edit_file';
  @override
  String get description => 'fake edit for tests';
  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {
      'path': {'type': 'string'},
    },
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async =>
      ToolResult.text('Successfully updated "${arguments['path']}".');
}

class _FakeReadTool extends AgentTool {
  @override
  String get name => 'read_file';
  @override
  bool get readOnly => true;
  @override
  String get description => 'fake read for tests';
  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {
      'path': {'type': 'string'},
    },
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async =>
      ToolResult.text('contents of ${arguments['path']}');
}

/// A fake [Process] stand-in is not possible (Process is not implementable
/// cleanly), so process-level tests spawn real trivial commands instead of
/// mocking; the injectable starter only swaps *what* runs, which keeps the
/// suite independent of any language toolchain.
List<List<StreamEvent> Function(List<ChatMessage>)> editThenStop({
  String path = 'a.ts',
}) => [
  (m) => [
    ToolCallCompleteEvent(
      ToolCall(id: 'c1', name: 'edit_file', arguments: {'path': path}),
    ),
    DoneEvent(finishReason: 'tool_calls'),
  ],
  (m) => [TextDeltaEvent('ok'), DoneEvent(finishReason: 'stop')],
];

CheckController _controller({
  String command = 'true',
  int graceMs = 1000,
  int timeoutMs = 30000,
  bool reportAlways = true,
  bool enabled = true,
}) => CheckController(
  workspace: Directory.systemTemp.path,
  settings: CheckSettings(
    command: command,
    graceMs: graceMs,
    timeoutMs: timeoutMs,
    reportAlways: reportAlways,
  ),
  enabled: enabled,
);

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('check54_');
    AgentSession.storageDirectoryOverride = dir.path;
  });
  tearDown(() {
    AgentSession.storageDirectoryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('CheckController verdicts', () {
    test('clean run: exit 0, byte-stable text, no timing inside', () async {
      final c = _controller(command: 'true');
      c.recordMutation('a.ts');
      final v = await c.start();
      expect(v!.kind, CheckKind.clean);
      expect(v.transcriptText, '[check clean: true]');
      expect(v.durationMs, greaterThan(-1));
      expect(v.transcriptText.contains('ms'), isFalse);
    });

    test('failed run: exit code plus raw output, no parsed counts', () async {
      final c = _controller(
        command: "echo 'src/a.ts(1,2): error TS1: boom'; exit 2",
      );
      c.recordMutation('a.ts');
      final v = await c.start();
      expect(v!.kind, CheckKind.failed);
      expect(v.transcriptText, contains('(exit code 2)'));
      expect(v.transcriptText, contains('boom'));
      expect(v.transcriptText, contains('may be expected'));
      // Raw output contract: the checker's own words, uninterpreted.
      expect(v.transcriptText, contains('error TS1: boom'));
    });

    test('command not found: not run, loud reason', () async {
      final c = _controller(command: 'definitely-not-a-real-binary-54');
      c.recordMutation('a.ts');
      final v = await c.start();
      expect(v!.kind, CheckKind.notRun);
      expect(v.transcriptText, contains('command not found'));
    });

    test('timeout: killed, not run with reason, bounded', () async {
      final c = _controller(command: 'sleep 5', timeoutMs: 150);
      c.recordMutation('a.ts');
      final sw = Stopwatch()..start();
      final v = await c.start();
      expect(v!.kind, CheckKind.notRun);
      expect(v.transcriptText, contains('timed out after 150 ms'));
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('killed runs never deliver', () async {
      final c = _controller(command: 'sleep 5');
      c.recordMutation('a.ts');
      final first = c.start();
      c.recordMutation('b.ts'); // kills and supersedes
      final second = c.start();
      expect(await first, isNull);
      expect(await second, isNotNull);
      expect(c.takeNotices(), isEmpty);
    });

    test('verdict text repeats are byte-identical', () async {
      final c = _controller(command: 'true');
      c.recordMutation('a.ts');
      final v1 = await c.start();
      c.recordMutation('a.ts');
      final v2 = await c.start();
      expect(v1!.transcriptText, equals(v2!.transcriptText));
    });

    test('stale notice is stamped with files changed since', () async {
      final c = _controller(command: 'true');
      c.recordMutation('a.ts');
      final v = await c.start();
      c.recordMutation('b.ts');
      c.recordMutation('c.ts');
      expect(c.noticeFor(v!), contains('2 files changed since'));
    });

    test(
      'report: issues suppresses clean to the model but caches it',
      () async {
        final c = _controller(command: 'true', reportAlways: false);
        c.recordMutation('a.ts');
        final v = await c.start();
        expect(c.deliversTo(v!), isFalse);
        expect(c.lastCompleted, isNotNull); // cache hit still available
      },
    );
  });

  group('agent loop integration', () {
    test(
      'fast check lands inline on the edit result before next call',
      () async {
        final provider = _ScriptedProvider(editThenStop());
        final session = AgentSession();
        final c = _controller(command: 'true');
        final agent = Agent(
          provider: provider,
          session: session,
          tools: [_FakeEditTool()],
        );
        agent.checkController = c;

        await agent.runTurn('edit a.ts');

        final toolMsg = provider.captured[1].lastWhere(
          (m) => m.role == Role.tool,
        );
        expect(toolMsg.content, contains('Successfully updated'));
        expect(toolMsg.content, contains('[check clean: true]'));
      },
    );

    test('slow check commits the async note and delivers late', () async {
      final provider = _ScriptedProvider(editThenStop());
      final session = AgentSession();
      final c = _controller(command: 'sleep 0.3', graceMs: 30);
      final agent = Agent(
        provider: provider,
        session: session,
        tools: [_FakeEditTool()],
      );
      agent.checkController = c;

      await agent.runTurn('edit a.ts');

      final toolMsg = provider.captured[1].lastWhere(
        (m) => m.role == Role.tool,
      );
      expect(toolMsg.content, contains('[check running async'));
      // Turn-end drain delivered the verdict into the transcript.
      expect(
        session.messages.any((m) => (m.content ?? '').contains('[check clean')),
        isTrue,
      );
    });

    test('no mutations means no check and no note', () async {
      final provider = _ScriptedProvider([
        (m) => [
          ToolCallCompleteEvent(
            ToolCall(id: 'c1', name: 'read_file', arguments: {'path': 'x'}),
          ),
          DoneEvent(finishReason: 'tool_calls'),
        ],
        (m) => [TextDeltaEvent('ok'), DoneEvent(finishReason: 'stop')],
      ]);
      final session = AgentSession();
      final c = _controller(command: 'true');
      final agent = Agent(
        provider: provider,
        session: session,
        tools: [_FakeReadTool()],
      );
      agent.checkController = c;

      await agent.runTurn('read x');

      final toolMsg = provider.captured[1].lastWhere(
        (m) => m.role == Role.tool,
      );
      expect(toolMsg.content, isNot(contains('check')));
      expect(
        session.messages.any((m) => (m.content ?? '').contains('[check')),
        isFalse,
      );
    });

    test('disabled experiment changes nothing at all', () async {
      final provider = _ScriptedProvider(editThenStop());
      final session = AgentSession();
      final c = _controller(command: 'true', enabled: false);
      final agent = Agent(
        provider: provider,
        session: session,
        tools: [_FakeEditTool()],
      );
      agent.checkController = c;

      await agent.runTurn('edit a.ts');

      final toolMsg = provider.captured[1].lastWhere(
        (m) => m.role == Role.tool,
      );
      expect(toolMsg.content, isNot(contains('check')));
    });

    test(
      'repeated identical edit+verdict loops still trip the stuck guard',
      () async {
        // The whole point of byte-stable verdict text: the iteration signature
        // (calls + results) must not jitter, or stuck detection dies on every
        // mutating loop.
        final provider = _ScriptedProvider(
          List.generate(
            10,
            (_) =>
                (m) => [
                  ToolCallCompleteEvent(
                    ToolCall(
                      id: 'c',
                      name: 'edit_file',
                      arguments: {'path': 'a.ts'},
                    ),
                  ),
                  DoneEvent(finishReason: 'tool_calls'),
                ],
          ),
        );
        final session = AgentSession();
        final agent = Agent(
          provider: provider,
          session: session,
          tools: [_FakeEditTool()],
          maxStuckIterations: 3,
        );
        agent.checkController = _controller(command: 'true');

        await agent.runTurn('edit a.ts');

        expect(
          session.messages.any(
            (m) => (m.content ?? '').contains('stopped to avoid spinning'),
          ),
          isTrue,
        );
      },
    );

    test('edits landing during a check re-run it on the newer state', () async {
      final provider = _ScriptedProvider([
        (m) => [
          ToolCallCompleteEvent(
            ToolCall(id: 'c1', name: 'edit_file', arguments: {'path': 'a.ts'}),
          ),
          // Second edit in the same bundle kills the first bundle check via
          // recordMutation before the bundle closes.
          ToolCallCompleteEvent(
            ToolCall(id: 'c2', name: 'edit_file', arguments: {'path': 'b.ts'}),
          ),
          DoneEvent(finishReason: 'tool_calls'),
        ],
        (m) => [TextDeltaEvent('ok'), DoneEvent(finishReason: 'stop')],
      ]);
      final session = AgentSession();
      final c = _controller(command: 'sleep 0.25', graceMs: 30);
      final agent = Agent(
        provider: provider,
        session: session,
        tools: [_FakeEditTool()],
      );
      agent.checkController = c;

      await agent.runTurn('edit a and b');

      // The model saw one async note (on the last mutating result), and the
      // delivered verdict describes the state after BOTH edits.
      final toolMsgs = provider.captured[1]
          .where((m) => m.role == Role.tool)
          .toList();
      expect(toolMsgs.last.content, contains('[check running async'));
      expect(
        session.messages.any(
          (m) =>
              (m.content ?? '').contains('[check clean') &&
              !(m.content ?? '').contains('changed since'),
        ),
        isTrue,
        reason: 'late verdict covers the final state, so it is not stale',
      );
    });
  });

  group('check_status tool', () {
    test('answers from cache when nothing changed', () async {
      final c = _controller(command: 'true');
      c.recordMutation('a.ts');
      await c.start();
      final tool = CheckStatusTool(c);
      final res = await tool.execute({});
      expect(res.content, contains('[check clean: true]'));
      expect(res.content, isNot(contains('stale')));
    });

    test(
      'a verdict that does not cover the current state re-runs fresh',
      () async {
        // Contract: cache hits only when nothing changed. A verdict from before
        // an edit the model can see would be a confident wrong answer, so the
        // tool re-runs instead of stamping and returning it.
        final c = _controller(command: 'true');
        c.recordMutation('a.ts');
        await c.start();
        c.recordMutation('b.ts');
        final tool = CheckStatusTool(c);
        final res = await tool.execute({});
        expect(res.content, contains('[check clean: true]'));
        expect(res.content, isNot(contains('stale')));
      },
    );

    test('runs now when the bundle already mutated', () async {
      final c = _controller(command: 'true');
      c.recordMutation('a.ts');
      await c.start();
      c.recordMutation('b.ts');
      c.bundleHasMutations = true;
      final tool = CheckStatusTool(c);
      final res = await tool.execute({});
      // Fresh verdict, not the stale cached one.
      expect(res.content, contains('[check clean: true]'));
      expect(res.content, isNot(contains('stale')));
    });

    test('waits for an in-flight check instead of duplicating it', () async {
      final c = _controller(command: 'sleep 0.2');
      c.recordMutation('a.ts');
      final inflight = c.start();
      final tool = CheckStatusTool(c);
      final res = await tool.execute({});
      expect(res.content, contains('[check clean: sleep 0.2]'));
      await inflight;
    });

    test('inactive controller says not run with the exact reason', () async {
      final c = CheckController(workspace: '.', settings: null, enabled: true);
      final tool = CheckStatusTool(c);
      final res = await tool.execute({});
      expect(res.content, contains('no check.command configured'));
    });
  });

  group('adaptive grace and bash seam', () {
    test(
      'grace skips after 3 consecutive overruns, re-arms on a fast run',
      () async {
        // Generous margins either way: slow command is ~10x the grace, re-arm grace
        // is huge, so no scheduler hiccup can flip the expectation.
        final c = _controller(command: 'sleep 0.3', graceMs: 25);
        c.recordMutation('a.ts');
        expect(c.graceWorthwhile, isTrue);
        await c.start();
        c.recordMutation('a.ts');
        await c.start();
        c.recordMutation('a.ts');
        await c.start();
        expect(c.graceWorthwhile, isFalse);

        c.settings = CheckSettings(command: 'true', graceMs: 30000);
        await c.start();
        expect(c.graceWorthwhile, isTrue);
      },
    );

    test('external run of the check command absorbs the next start', () async {
      final c = _controller(command: 'npm run check');
      c.beforeBashRun('npm run check'); // exact match, no running check yet
      c.recordMutation('a.ts');
      final v = await c.start();
      expect(v, isNull); // absorbed: the model already has the bash result
      // The start after that runs normally.
      c.recordMutation('a.ts');
      final v2 = await c.start();
      expect(v2, isNotNull);
    });

    test('bash run of any command cancels the in-flight check', () async {
      final c = _controller(command: 'sleep 5');
      c.recordMutation('a.ts');
      final first = c.start();
      c.beforeBashRun('cargo test');
      expect(await first, isNull);
    });

    test(
      'plausible command is offered as suggestion only when unconfigured',
      () {
        final configured = _controller(command: 'true');
        configured.beforeBashRun('npm run check');
        expect(configured.pendingSuggestion, isNull);

        final unconfigured = CheckController(
          workspace: '.',
          settings: null,
          enabled: true,
        );
        unconfigured.beforeBashRun('npm run check');
        expect(unconfigured.pendingSuggestion, 'npm run check');
        unconfigured.resolveSuggestion('npm run check', false);
        expect(unconfigured.pendingSuggestion, isNull);
        expect(unconfigured.suggestionsAllowed, isFalse);
        unconfigured.beforeBashRun('cargo test');
        expect(unconfigured.pendingSuggestion, isNull); // never recurs
      },
    );

    test(
      'cd-prefixed commands still trigger, suggestion is the bare checker',
      () {
        // Agents lead bash commands with `cd <dir> &&`; anchoring the match at
        // the whole line meant the suggestion never fired in real sessions.
        final c = CheckController(
          workspace: '.',
          settings: null,
          enabled: true,
        );
        c.beforeBashRun(
          'cd /some/proj && dart analyze --fatal-infos 2>&1 | tail -1',
        );
        expect(c.pendingSuggestion, 'dart analyze --fatal-infos 2>&1');
      },
    );

    test('non-check commands do not trigger suggestions', () {
      final c = CheckController(workspace: '.', settings: null, enabled: true);
      c.beforeBashRun('git commit -m x');
      c.beforeBashRun('grep -rn check src');
      expect(c.pendingSuggestion, isNull);
    });
  });

  group('prompt and zero-overhead-when-off', () {
    test('prompt section appears only when active', () {
      expect(_controller(enabled: false).promptSection, isNull);
      expect(
        CheckController(
          workspace: '.',
          settings: null,
          enabled: true,
        ).promptSection,
        isNull,
      );
      expect(_controller().promptSection, contains('check_status'));
    });

    test(
      'toggle at runtime flips tool registration and prompt section',
      () async {
        final session = AgentSession();
        final c = _controller(command: 'true');
        c.enabled = false;
        expect(c.isActive, isFalse);
        session.experimentPromptSection = c.promptSection ?? '';
        session.rebuildSystemPrompt();
        expect(
          session.systemPrompt,
          isNot(contains('Post-bundle project check')),
        );

        c.enabled = true;
        session.experimentPromptSection = c.promptSection ?? '';
        session.rebuildSystemPrompt();
        expect(session.systemPrompt, contains('Post-bundle project check'));
      },
    );
  });
}
