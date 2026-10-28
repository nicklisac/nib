import 'dart:async';
import 'dart:convert';
import '../ai/chat_message.dart';
import '../ai/event_stream.dart';
import '../ai/image_attachment.dart';
import '../ai/provider.dart';
import 'compaction.dart';
import 'context_meter.dart';
import 'session.dart';
import 'thinking_level.dart';
import 'tool.dart';
import 'velocity_tracker.dart';

/// Callbacks for streaming events to the UI during agent execution.
class AgentCallbacks {
  final void Function(String text)? onTextDelta;
  final void Function(String thought)? onThoughtDelta;
  final void Function(ToolCall toolCall)? onToolCallStarted;
  final void Function(ToolCall toolCall, String result, Duration duration)?
  onToolCallFinished;
  final void Function(ToolCall toolCall, String line)? onToolProgress;
  final void Function(RewindRecord record)? onRewind;
  final void Function(String error)? onError;

  AgentCallbacks({
    this.onTextDelta,
    this.onThoughtDelta,
    this.onToolCallStarted,
    this.onToolCallFinished,
    this.onToolProgress,
    this.onRewind,
    this.onError,
  });
}

/// The core agent harness managing model interactions and the tool execution loop.
class Agent {
  LLMProvider provider;
  AgentSession session;
  final Map<String, AgentTool> _tools = {};

  /// Ceiling on tool-loop iterations within one user prompt. `0` means unbounded,
  /// which is the default: real agentic work (planning skills, multi-file
  /// refactors) needs far more iterations than any fixed number can predict, and
  /// a low ceiling aborts valid work mid-task. The historical 20-iteration cap
  /// caused exactly that and must not come back.
  ///
  /// Real runaway protection is [maxStuckIterations], which detects repetition.
  /// [hardIterationCap] is a far higher net for a broken provider, not a limit on
  /// legitimate work.
  final int maxTurns;

  /// How many times the *same* iteration may occur within one prompt before the
  /// loop is treated as stuck. An iteration is identified by its tool calls and
  /// their results, so a call whose output changes (polling a build, watching a
  /// log) is progress and never counts. Counting occurrences rather than
  /// consecutive runs also catches alternating cycles (A, B, A, B), which a
  /// consecutive counter resets on every step and therefore never catches.
  ///
  /// The default leaves room for legitimate waiting, where a command such as
  /// `sleep 30 && gh run view` reports the same unchanged status several times in
  /// a row. Raise it for slow-workflow polling; `0` disables the guard.
  final int maxStuckIterations;

  /// Absolute iteration ceiling, set far above any plausible real task, that
  /// guarantees termination if a provider emits endless distinct-but-useless
  /// calls. With compaction enabled an unbounded loop would otherwise burn
  /// context and API budget forever. `0` disables it.
  final int hardIterationCap;

  final int? contextWindow;
  final int? maxTokens;
  ThinkingLevel thinkingLevel;

  /// The context gauge: what fraction of the window the *next request* would
  /// occupy. Owned here because this is the layer that knows what a request will
  /// cost — the estimate is of this transcript, and the measured figure is the
  /// prompt tokens of the last request made through this provider.
  late final ContextMeter meter = ContextMeter(
    contextWindow:
        contextWindow ?? CompactionManager.defaultContextWindowTokens,
  );

  /// Tracks LLM generation speed across pure generation bursts.
  final GenerationVelocityTracker velocityTracker = GenerationVelocityTracker();

  Agent({
    required this.provider,
    required this.session,
    List<AgentTool> tools = const [],
    this.maxTurns = 0,
    this.maxStuckIterations = 5,
    this.hardIterationCap = 200,
    this.contextWindow,
    this.maxTokens,
    ThinkingLevel? thinkingLevel,
  }) : thinkingLevel = thinkingLevel ?? ThinkingLevel.medium {
    for (final t in tools) {
      registerTool(t);
    }
  }

  void registerTool(AgentTool tool) {
    _tools[tool.name] = tool;
  }

  void unregisterTool(String name) {
    _tools.remove(name);
  }

  bool hasTool(String name) => _tools.containsKey(name);

  List<AgentTool> get tools => _tools.values.toList();
  bool _isCancelled = false;
  StreamSubscription? _activeStreamSub;
  Completer<void>? _turnStreamCompleter;

  /// Cancels the currently running turn and any active tool processes.
  void cancel() {
    _isCancelled = true;
    velocityTracker.endBurst();
    _activeStreamSub?.cancel();
    _activeStreamSub = null;
    if (_turnStreamCompleter != null && !_turnStreamCompleter!.isCompleted) {
      _turnStreamCompleter!.complete();
    }
    _turnStreamCompleter = null;
    for (final tool in _tools.values) {
      tool.cancel();
    }
  }

  /// Runs the full agent loop for the provided user message.
  Future<void> runTurn(
    String userPrompt, {
    List<ImageAttachment>? images,
    AgentCallbacks? callbacks,
  }) async {
    _isCancelled = false;
    session.addSystemPromptIfNeeded();
    session.addMessage(ChatMessage.user(userPrompt, images: images));

    int currentTurn = 0;
    // Occurrence counts per iteration signature (calls + results), so repeated
    // work is caught even when it alternates with other calls.
    final iterationCounts = <String, int>{};

    while (!_isCancelled &&
        !_iterationLimitReached(currentTurn, callbacks: callbacks)) {
      currentTurn++;

      // Auto-compact before calling model if context threshold is reached. The
      // numerator is the gauge's own reading, so the human who compacted because
      // the gauge said 94% and the trigger that fired are looking at one number.
      final occupiedTokens = meter.tokensFor(session);
      if (CompactionManager.shouldAutoCompact(
        session,
        contextWindow: meter.contextWindow,
        reserve: meter.reserve,
        tokens: occupiedTokens,
      )) {
        callbacks?.onThoughtDelta?.call(
          '\n[Context threshold reached: automatically compacting conversation history...]\n',
        );
        await CompactionManager.compact(session: session, provider: provider);
      }

      final textBuffer = StringBuffer();
      final thoughtBuffer = StringBuffer();
      final toolCalls = <ToolCall>[];
      String? lastFinishReason;

      velocityTracker.startBurst();

      final stream = provider.streamChat(
        messages: session.messages,
        tools: tools,
        maxTokens: maxTokens,
        thinkingLevel: thinkingLevel,
      );

      bool hasError = false;
      final completer = Completer<void>();
      _turnStreamCompleter = completer;

      _activeStreamSub = stream.listen(
        (event) {
          if (_isCancelled) {
            velocityTracker.endBurst();
            _activeStreamSub?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          switch (event) {
            case TextDeltaEvent(:final text):
              velocityTracker.recordDelta(text);
              textBuffer.write(text);
              callbacks?.onTextDelta?.call(text);

            case ThoughtDeltaEvent(:final thought):
              velocityTracker.recordDelta(thought);
              thoughtBuffer.write(thought);
              callbacks?.onThoughtDelta?.call(thought);

            case ToolCallCompleteEvent(:final toolCall):
              toolCalls.add(toolCall);

            case DoneEvent(
              finishReason: final fr,
              promptTokens: final pt,
              completionTokens: final ct,
              cachedPromptTokens: final cpt,
            ):
              lastFinishReason = fr;
              velocityTracker.endBurst(actualTokens: ct);
              session.recordUsage(pt, ct, cachedTokens: cpt);
              meter.recordPromptTokens(pt);

            case ErrorEvent(:final message):
              velocityTracker.endBurst();
              hasError = true;
              callbacks?.onError?.call(message);
          }
        },
        onError: (e) {
          if (!_isCancelled) {
            hasError = true;
            callbacks?.onError?.call(e.toString());
          }
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );

      await completer.future;
      _activeStreamSub = null;
      _turnStreamCompleter = null;

      if (_isCancelled || hasError) {
        if (_isCancelled) {
          final partial = textBuffer.toString().trim();
          final assistantText = partial.isNotEmpty
              ? '$partial\n\n[Interrupted by user]'
              : '[Interrupted by user]';
          final thoughtText = thoughtBuffer.toString().trim();
          session.addMessage(
            ChatMessage.assistant(
              assistantText,
              thought: thoughtText.isNotEmpty ? thoughtText : null,
            ),
          );
          await session.saveToDisk();
        }
        return;
      }

      // Record assistant message
      final assistantContent = textBuffer.toString();
      final thoughtContent = thoughtBuffer.toString().trim();
      session.addMessage(
        ChatMessage.assistant(
          assistantContent,
          thought: thoughtContent.isNotEmpty ? thoughtContent : null,
          toolCalls: toolCalls.isNotEmpty ? toolCalls : null,
        ),
      );

      // If no tool calls were requested, this turn is done!
      if (toolCalls.isEmpty || _isCancelled) {
        break;
      }

      // Signature of the calls issued this iteration; combined with the results
      // below it decides whether the loop actually made progress. Arguments are
      // canonicalised so that the same call with reordered JSON keys counts as
      // the same iteration.
      final callSignature = toolCalls
          .map((c) => '${c.name}:${_canonical(c.arguments)}')
          .join('|');
      final resultParts = <String>[];

      // Intercept `rewind_reads` when it is the sole tool call in the turn and
      // the tool is registered on this agent (#53).
      String? rewindRefusalReason;
      var rewoundTurn = false;
      if (_tools.containsKey(AgentSession.rewindToolName) &&
          toolCalls.length == 1 &&
          toolCalls.first.name == AgentSession.rewindToolName &&
          !_isCancelled) {
        final call = toolCalls.first;
        final note = (call.arguments['note'] as String?) ?? '';
        final minChars =
            _tools[AgentSession.rewindToolName]?.minRewindChars ?? 1000;
        final outcome = session.rewindLastReadTurn(
          note: note,
          isReadOnlyTool: (name) => _tools[name]?.readOnly ?? false,
          minChars: minChars,
        );
        switch (outcome) {
          case RewindSuccess(:final record):
            rewoundTurn = true;
            session.toolExecutionsCount++;
            // Clear stale pre-rewind measured prompt tokens so the context gauge
            // never reports the old larger window reading (Feel Doctrine Rule 4).
            meter.reset();
            resultParts.add('REWIND:${record.originalChars}:${record.note}');
            if (callbacks?.onRewind != null) {
              callbacks!.onRewind!(record);
            } else {
              callbacks?.onThoughtDelta?.call(
                '\n[~ rewound ${record.formattedOriginalChars} (${record.toolsSummary}) -> ~${record.estimatedNoteTokens}-token note]\n',
              );
            }
          case RewindRefused(:final reason):
            rewindRefusalReason = reason;
        }
      }

      // Execute requested tools (skipped when a rewind_reads call succeeded and
      // already rewound the transcript in-place).
      for (int i = 0; !rewoundTurn && i < toolCalls.length; i++) {
        final call = toolCalls[i];

        if (_isCancelled) {
          session.addMessage(
            ChatMessage.toolResult(
              toolCallId: call.id,
              toolName: call.name,
              content: '[Tool execution cancelled by user]',
            ),
          );
          continue;
        }

        callbacks?.onToolCallStarted?.call(call);

        final tool = _tools[call.name];
        tool?.onProgress = (line) {
          callbacks?.onToolProgress?.call(call, line);
        };

        ToolResult result;
        final stopwatch = Stopwatch()..start();

        if (tool == null) {
          result = ToolResult.text(
            'Error: Unknown tool "${call.name}". Available tools: ${_tools.keys.join(', ')}',
          );
        } else if (call.name == AgentSession.rewindToolName) {
          final reason =
              rewindRefusalReason ??
              'Refused rewind_reads: rewind_reads must be the sole tool call in a turn, '
                  'not batched with other tools (${toolCalls.map((c) => c.name).join(', ')}).';
          result = ToolResult.text(reason);
        } else {
          try {
            result = await tool.execute(call.arguments);
          } catch (e, st) {
            result = ToolResult.text(
              'Error executing tool "${call.name}": $e\n$st',
            );
          }
        }
        stopwatch.stop();
        tool?.onProgress = null;

        if (_isCancelled) {
          callbacks?.onToolCallFinished?.call(
            call,
            'Cancelled',
            stopwatch.elapsed,
          );
          session.addMessage(
            ChatMessage.toolResult(
              toolCallId: call.id,
              toolName: call.name,
              content: '[Tool execution cancelled by user]',
            ),
          );
          // Fulfill all remaining pending tool calls in this turn so transcript schema is valid
          for (int j = i + 1; j < toolCalls.length; j++) {
            final nextCall = toolCalls[j];
            session.addMessage(
              ChatMessage.toolResult(
                toolCallId: nextCall.id,
                toolName: nextCall.name,
                content: '[Tool execution cancelled by user]',
              ),
            );
          }
          break;
        }

        session.toolExecutionsCount++;
        callbacks?.onToolCallFinished?.call(
          call,
          result.content,
          stopwatch.elapsed,
        );

        // Add tool result to transcript (safely truncated if oversized)
        var sanitizedResult = _truncateToolResult(result.content);
        if (_tools.containsKey(AgentSession.rewindToolName) &&
            (tool?.readOnly ?? false) &&
            result.content.length >= rewindHintThresholdChars) {
          sanitizedResult = '$sanitizedResult${AgentSession.rewindHintFooter}';
        }
        resultParts.add(sanitizedResult);
        session.addMessage(
          ChatMessage.toolResult(
            toolCallId: call.id,
            toolName: call.name,
            content: sanitizedResult,
            images: result.images,
          ),
        );
      }

      if (_isCancelled) {
        session.addMessage(
          ChatMessage.assistant(
            '[Tool execution interrupted by user. Ready for steering instruction.]',
          ),
        );
        break;
      }

      // Runaway guard. An iteration is identified by its tool calls *and* their
      // results, so re-running a command whose output changed (polling a build,
      // watching a log) is real progress and never counts against the limit.
      // Occurrences are counted across the whole prompt rather than consecutively,
      // which also catches alternating A/B/A/B cycles that a consecutive counter
      // resets on every step and therefore never sees.
      final iterationSignature = '$callSignature\n${resultParts.join("\n")}';
      final occurrences = (iterationCounts[iterationSignature] ?? 0) + 1;
      iterationCounts[iterationSignature] = occurrences;
      if (maxStuckIterations > 0 && occurrences > maxStuckIterations) {
        callbacks?.onThoughtDelta?.call(
          '\n[Stopped: the same tool call and result occurred $occurrences '
          'times in this prompt with no progress. Awaiting steering input.]\n',
        );
        session.addMessage(
          ChatMessage.assistant(
            '[This tool call has now returned the same result $occurrences times '
            'without changing anything, so the loop was stopped to avoid '
            'spinning. Try a different approach, or steer me in a new direction.]',
          ),
        );
        break;
      }

      // Check if finish reason indicates stop despite tool calls (rare)
      if (lastFinishReason == 'stop' && toolCalls.isEmpty) {
        break;
      }
    }

    // Auto-persist session to disk
    await session.saveToDisk();
  }

  static const int maxToolOutputChars = 20000;

  /// Read-only tool outputs at or above this character count receive a one-line
  /// hint reminding the model it can call `rewind_reads` if the result is a
  /// dead end or scaffolding (#53).
  static const int rewindHintThresholdChars = 4800;

  /// Whether an iteration ceiling has been reached. By default [maxTurns] is `0`
  /// (no per-prompt ceiling) and only [hardIterationCap] applies, which exists to
  /// stop a broken provider, not to limit legitimate work.
  bool _iterationLimitReached(int currentTurn, {AgentCallbacks? callbacks}) {
    if (maxTurns > 0 && currentTurn >= maxTurns) return true;
    if (hardIterationCap > 0 && currentTurn >= hardIterationCap) {
      callbacks?.onThoughtDelta?.call(
        '\n[Stopped: reached the absolute limit of $hardIterationCap tool '
        'iterations for one prompt. The task likely needs to be split up.]\n',
      );
      return true;
    }
    return false;
  }

  /// Stable string for a JSON-ish value, with map keys sorted so that two calls
  /// carrying the same arguments in a different order hash identically.
  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return '{${keys.map((k) => '"$k":${_canonical(value[k])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonical).join(',')}]';
    }
    return jsonEncode(value);
  }

  static String _truncateToolResult(String output) {
    if (output.length <= maxToolOutputChars) return output;
    final kept = output.substring(0, maxToolOutputChars);
    final omitted = output.length - maxToolOutputChars;
    return '$kept\n\n[... $omitted characters truncated to protect context window ...]';
  }
}
