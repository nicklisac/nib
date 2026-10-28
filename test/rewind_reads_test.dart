import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/config.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/thinking_level.dart';
import 'package:nib/agent/tool.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/event_stream.dart';
import 'package:nib/ai/provider.dart';
import 'package:nib/tools/bash_tool.dart';
import 'package:nib/tools/edit_file_tool.dart';
import 'package:nib/tools/list_dir_tool.dart';
import 'package:nib/tools/read_file_tool.dart';
import 'package:nib/tools/rewind_reads_tool.dart';
import 'package:nib/tools/search_files_tool.dart';
import 'package:nib/tools/skill_tool.dart';
import 'package:nib/tools/web_fetch_tool.dart';
import 'package:nib/tools/web_search_tool.dart';
import 'package:nib/tools/write_file_tool.dart';

void main() {
  late Directory tempDir;
  late Directory testSessionsDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nib_rewind_test_ws_');
    testSessionsDir = Directory.systemTemp.createTempSync(
      'nib_rewind_test_sess_',
    );
    AgentSession.storageDirectoryOverride = testSessionsDir.path;
  });

  tearDown(() {
    AgentSession.storageDirectoryOverride = null;
    for (final d in [tempDir, testSessionsDir]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('Tool readOnly classification', () {
    test('marks only side-effect-free inspection tools as readOnly', () {
      expect(ReadFileTool(workingDirectory: tempDir.path).readOnly, isTrue);
      expect(SearchFilesTool(workingDirectory: tempDir.path).readOnly, isTrue);
      expect(ListDirTool(workingDirectory: tempDir.path).readOnly, isTrue);
      expect(WebFetchTool().readOnly, isTrue);
      expect(WebSearchTool().readOnly, isTrue);
      expect(SkillTool().readOnly, isTrue);

      expect(BashTool(workingDirectory: tempDir.path).readOnly, isFalse);
      expect(WriteFileTool(workingDirectory: tempDir.path).readOnly, isFalse);
      expect(EditFileTool(workingDirectory: tempDir.path).readOnly, isFalse);
      expect(RewindReadsTool().readOnly, isFalse);
    });
  });

  group('rewind_reads happy path & cache prefix invariant', () {
    test(
      'rewinds a single large read_file turn in-place, erases rewind_reads, and resets ContextMeter',
      () async {
        final bigContent = List.generate(
          120,
          (i) => 'line $i: ${"x" * 40}',
        ).join('\n');
        await File(p.join(tempDir.path, 'big.txt')).writeAsString(bigContent);

        final capturedMessageSnapshots = <List<ChatMessage>>[];
        RewindRecord? meterCheckRecord;
        bool? meterMeasuredImmediatelyAfterRewind;

        final provider = _ScriptedProvider([
          // Step 1: call read_file on big.txt (reports 8,000 prompt tokens)
          (messages) {
            capturedMessageSnapshots.add(List.from(messages));
            return [
              ToolCallCompleteEvent(
                ToolCall(
                  id: 'call_read_1',
                  name: 'read_file',
                  arguments: const {'path': 'big.txt'},
                ),
              ),
              DoneEvent(
                finishReason: 'tool_calls',
                promptTokens: 8000,
                completionTokens: 40,
              ),
            ];
          },
          // Step 2: model sees big.txt + hint footer, calls rewind_reads
          (messages) {
            capturedMessageSnapshots.add(List.from(messages));
            return [
              ThoughtDeltaEvent('Dead end file; rewinding.'),
              ToolCallCompleteEvent(
                ToolCall(
                  id: 'call_rewind_2',
                  name: 'rewind_reads',
                  arguments: const {
                    'note':
                        'big.txt is generated fixture data; no source definitions inside.',
                  },
                ),
              ),
              DoneEvent(
                finishReason: 'tool_calls',
                promptTokens: 9500,
                completionTokens: 30,
              ),
            ];
          },
          // Step 3: model continues from the rewound checkpoint
          (messages) {
            capturedMessageSnapshots.add(List.from(messages));
            return [
              TextDeltaEvent('Done inspecting.'),
              DoneEvent(
                finishReason: 'stop',
                promptTokens: 1200,
                completionTokens: 10,
              ),
            ];
          },
        ]);

        final session = AgentSession();
        late final Agent agent;
        agent = Agent(
          provider: provider,
          session: session,
          tools: [
            ReadFileTool(workingDirectory: tempDir.path),
            RewindReadsTool(),
          ],
        );

        await agent.runTurn(
          'Inspect big.txt',
          callbacks: AgentCallbacks(
            onRewind: (record) {
              meterCheckRecord = record;
              // Feel Doctrine Rule 4: stale pre-rewind measuredPromptTokens (9500)
              // must be cleared immediately when the transcript shrinks.
              meterMeasuredImmediatelyAfterRewind = agent.meter.isMeasured;
            },
          ),
        );

        expect(meterCheckRecord, isNotNull);
        expect(meterCheckRecord!.toolsSummary, equals('read_file big.txt'));
        expect(meterCheckRecord!.originalChars, greaterThanOrEqualTo(4800));
        expect(meterMeasuredImmediatelyAfterRewind, isFalse);
        // Once Step 3 finishes, the new smaller measured prompt token count is recorded.
        expect(agent.meter.isMeasured, isTrue);
        expect(agent.meter.measuredPromptTokens, equals(1200));

        // Verify Step 2 saw the affordance tip on the >=4.8k read result.
        final step2ToolMsg = capturedMessageSnapshots[1].last;
        expect(step2ToolMsg.role, equals(Role.tool));
        expect(
          step2ToolMsg.content,
          contains('call rewind_reads to replace it with a short note'),
        );

        // Verify Step 3 saw the rewound transcript:
        // [0] system, [1] user, [2] assistant(read_file), [3] tool(note)
        final step3Messages = capturedMessageSnapshots[2];
        expect(step3Messages.length, equals(4));
        expect(step3Messages[2].role, equals(Role.assistant));
        expect(step3Messages[2].toolCalls!.single.id, equals('call_read_1'));
        expect(step3Messages[2].toolCalls!.single.name, equals('read_file'));
        expect(step3Messages[3].role, equals(Role.tool));
        expect(step3Messages[3].toolCallId, equals('call_read_1'));
        expect(step3Messages[3].content, startsWith('[Rewound read result ('));
        expect(
          step3Messages[3].content,
          contains(
            'big.txt is generated fixture data; no source definitions inside.',
          ),
        );
        // No rewind_reads call exists anywhere in the active transcript.
        expect(
          session.messages.any(
            (m) =>
                m.toolName == 'rewind_reads' ||
                (m.toolCalls?.any((c) => c.name == 'rewind_reads') ?? false),
          ),
          isFalse,
        );

        // Side record is persisted to disk and survives loadFromDisk().
        final loaded = await AgentSession.loadFromDisk(session.id);
        expect(loaded, isNotNull);
        expect(loaded!.rewinds.length, equals(1));
        expect(
          loaded.rewinds.single.note,
          equals(
            'big.txt is generated fixture data; no source definitions inside.',
          ),
        );
        expect(
          loaded.rewinds.single.originalToolMessages.single.content,
          contains('line 0:'),
        );
      },
    );

    test(
      'preserves 1:1 tool_use/tool_result pairing when rewinding a parallel multi-tool read batch',
      () async {
        await File(p.join(tempDir.path, 'a.txt')).writeAsString('alpha ' * 200);
        await File(p.join(tempDir.path, 'b.txt')).writeAsString('beta ' * 200);

        final provider = _ScriptedProvider([
          // Step 1: parallel read_file batch (2 calls in one assistant turn)
          (_) => [
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_a',
                name: 'read_file',
                arguments: const {'path': 'a.txt'},
              ),
            ),
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_b',
                name: 'read_file',
                arguments: const {'path': 'b.txt'},
              ),
            ),
            DoneEvent(finishReason: 'tool_calls'),
          ],
          // Step 2: rewind both with one note
          (_) => [
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_rewind',
                name: 'rewind_reads',
                arguments: const {
                  'note': 'Both a.txt and b.txt are filler fixtures.',
                },
              ),
            ),
            DoneEvent(finishReason: 'tool_calls'),
          ],
          // Step 3: finish
          (_) => [TextDeltaEvent('All set.'), DoneEvent(finishReason: 'stop')],
        ]);

        final session = AgentSession();
        final agent = Agent(
          provider: provider,
          session: session,
          tools: [
            ReadFileTool(workingDirectory: tempDir.path),
            RewindReadsTool(),
          ],
        );

        await agent.runTurn('Check both files');

        // Active transcript:
        // [0] system, [1] user, [2] assistant(call_a, call_b), [3] tool(call_a), [4] tool(call_b), [5] assistant(final)
        expect(session.messages.length, equals(6));
        final assistantTurn = session.messages[2];
        expect(assistantTurn.toolCalls!.length, equals(2));

        final toolResultA = session.messages[3];
        final toolResultB = session.messages[4];
        expect(toolResultA.toolCallId, equals('call_a'));
        expect(
          toolResultA.content,
          contains('Both a.txt and b.txt are filler fixtures.'),
        );
        expect(toolResultB.toolCallId, equals('call_b'));
        expect(
          toolResultB.content,
          equals('[Included in rewound note on read_file (call_a)]'),
        );
      },
    );
  });

  group('rewind_reads refusal & safety invariants', () {
    test(
      'refuses rewind when the preceding turn contains a non-read-only tool',
      () async {
        final provider = _ScriptedProvider([
          // Step 1: write_file (non-read-only)
          (_) => [
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_write',
                name: 'write_file',
                arguments: {'path': 'out.txt', 'content': 'x' * 2000},
              ),
            ),
            DoneEvent(finishReason: 'tool_calls'),
          ],
          // Step 2: model attempts to rewind the write turn
          (_) => [
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_rewind',
                name: 'rewind_reads',
                arguments: const {'note': 'try to erase write'},
              ),
            ),
            DoneEvent(finishReason: 'tool_calls'),
          ],
          // Step 3: finish
          (_) => [
            TextDeltaEvent('Understood refusal.'),
            DoneEvent(finishReason: 'stop'),
          ],
        ]);

        final session = AgentSession();
        final agent = Agent(
          provider: provider,
          session: session,
          tools: [
            WriteFileTool(workingDirectory: tempDir.path),
            RewindReadsTool(),
          ],
        );

        await agent.runTurn('Write and try to rewind');

        expect(session.rewinds, isEmpty);
        final refusalMsg = session.messages.firstWhere(
          (m) => m.role == Role.tool && m.toolName == 'rewind_reads',
        );
        expect(
          refusalMsg.content,
          contains('called non-read-only tool "write_file"'),
        );
      },
    );

    test('refuses rewind when target output is below minChars floor', () async {
      await File(p.join(tempDir.path, 'tiny.txt')).writeAsString('short');

      final provider = _ScriptedProvider([
        (_) => [
          ToolCallCompleteEvent(
            ToolCall(
              id: 'call_read',
              name: 'read_file',
              arguments: const {'path': 'tiny.txt'},
            ),
          ),
          DoneEvent(finishReason: 'tool_calls'),
        ],
        (_) => [
          ToolCallCompleteEvent(
            ToolCall(
              id: 'call_rewind',
              name: 'rewind_reads',
              arguments: const {'note': 'tiny file'},
            ),
          ),
          DoneEvent(finishReason: 'tool_calls'),
        ],
        (_) => [
          TextDeltaEvent('Kept tiny output.'),
          DoneEvent(finishReason: 'stop'),
        ],
      ]);

      final session = AgentSession();
      final agent = Agent(
        provider: provider,
        session: session,
        tools: [
          ReadFileTool(workingDirectory: tempDir.path),
          RewindReadsTool(minChars: 1000),
        ],
      );

      await agent.runTurn('Read tiny file');

      expect(session.rewinds, isEmpty);
      final refusalMsg = session.messages.firstWhere(
        (m) => m.role == Role.tool && m.toolName == 'rewind_reads',
      );
      expect(refusalMsg.content, contains('minimum is 1000 chars'));
    });

    test(
      'refuses rewind when batched alongside another tool call in the same turn',
      () async {
        await File(
          p.join(tempDir.path, 'large.txt'),
        ).writeAsString('content ' * 300);

        final provider = _ScriptedProvider([
          (_) => [
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_read_1',
                name: 'read_file',
                arguments: const {'path': 'large.txt'},
              ),
            ),
            DoneEvent(finishReason: 'tool_calls'),
          ],
          // Model batches rewind_reads with another read_file in the same turn
          (_) => [
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_rewind',
                name: 'rewind_reads',
                arguments: const {'note': 'batched rewind'},
              ),
            ),
            ToolCallCompleteEvent(
              ToolCall(
                id: 'call_read_2',
                name: 'read_file',
                arguments: const {'path': 'large.txt'},
              ),
            ),
            DoneEvent(finishReason: 'tool_calls'),
          ],
          (_) => [TextDeltaEvent('Done.'), DoneEvent(finishReason: 'stop')],
        ]);

        final session = AgentSession();
        final agent = Agent(
          provider: provider,
          session: session,
          tools: [
            ReadFileTool(workingDirectory: tempDir.path),
            RewindReadsTool(),
          ],
        );

        await agent.runTurn('Batch test');

        expect(session.rewinds, isEmpty);
        final refusalMsg = session.messages.firstWhere(
          (m) => m.role == Role.tool && m.toolCallId == 'call_rewind',
        );
        expect(
          refusalMsg.content,
          contains('must be the sole tool call in a turn'),
        );
      },
    );

    test(
      'runaway guard still trips if model loops read_file -> rewind_reads repeatedly',
      () async {
        await File(
          p.join(tempDir.path, 'loop.txt'),
        ).writeAsString('loop_data ' * 250);

        int step = 0;
        final provider = _CallbackProvider((_) {
          step++;
          if (step.isOdd) {
            return [
              ToolCallCompleteEvent(
                ToolCall(
                  id: 'call_r_$step',
                  name: 'read_file',
                  arguments: const {'path': 'loop.txt'},
                ),
              ),
              DoneEvent(finishReason: 'tool_calls'),
            ];
          } else {
            return [
              ToolCallCompleteEvent(
                ToolCall(
                  id: 'call_rw_$step',
                  name: 'rewind_reads',
                  arguments: const {'note': 'nothing here'},
                ),
              ),
              DoneEvent(finishReason: 'tool_calls'),
            ];
          }
        });

        final session = AgentSession();
        final agent = Agent(
          provider: provider,
          session: session,
          tools: [
            ReadFileTool(workingDirectory: tempDir.path),
            RewindReadsTool(),
          ],
          maxStuckIterations: 2,
        );

        final thoughts = <String>[];
        await agent.runTurn(
          'Spin with rewind',
          callbacks: AgentCallbacks(onThoughtDelta: thoughts.add),
        );

        expect(thoughts, anyElement(contains('no progress')));
        expect(step, lessThanOrEqualTo(6));
      },
    );
  });

  group('experiments.rewind_reads config toggle', () {
    test(
      'defaults to false and round-trips through NibConfig save/load',
      () async {
        final defaultConfig = NibConfig();
        expect(defaultConfig.isExperimentEnabled('rewind_reads'), isFalse);

        final configFile = File(p.join(tempDir.path, 'config.json'));
        final enabledConfig = NibConfig(
          defaultProvider: 'openai',
          experiments: {'rewind_reads': true},
        );
        await enabledConfig.save(customPath: configFile.path);

        final loaded = await NibConfig.load(customPath: configFile.path);
        expect(loaded.isExperimentEnabled('rewind_reads'), isTrue);
      },
    );

    test(
      'does not append rewind hint footer when RewindReadsTool is not registered',
      () async {
        await File(p.join(tempDir.path, 'big.txt')).writeAsString('a' * 6000);

        final session = AgentSession();
        final agent = Agent(
          provider: _ScriptedProvider([
            (_) => [
              ToolCallCompleteEvent(
                ToolCall(
                  id: 'call_1',
                  name: 'read_file',
                  arguments: const {'path': 'big.txt'},
                ),
              ),
              DoneEvent(finishReason: 'tool_calls'),
            ],
            (_) => [
              TextDeltaEvent('Finished.'),
              DoneEvent(finishReason: 'stop'),
            ],
          ]),
          session: session,
          tools: [ReadFileTool(workingDirectory: tempDir.path)],
        );

        await agent.runTurn('Read without experiment');

        final toolMsg = session.messages.firstWhere((m) => m.role == Role.tool);
        expect(toolMsg.content, isNot(contains('rewind_reads')));
      },
    );
  });
}

class _ScriptedProvider implements LLMProvider {
  final List<List<StreamEvent> Function(List<ChatMessage> messages)> steps;
  int _index = 0;

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
    if (_index >= steps.length) {
      yield TextDeltaEvent('done');
      yield DoneEvent(finishReason: 'stop');
      return;
    }
    final events = steps[_index++](messages);
    for (final event in events) {
      yield event;
    }
  }
}

class _CallbackProvider implements LLMProvider {
  final List<StreamEvent> Function(List<ChatMessage> messages) onTurn;

  _CallbackProvider(this.onTurn);

  @override
  String get name => 'CallbackMock';

  @override
  String get model => 'callback-mock';

  @override
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
    int? maxTokens,
    ThinkingLevel? thinkingLevel,
  }) async* {
    for (final event in onTurn(messages)) {
      yield event;
    }
  }
}
