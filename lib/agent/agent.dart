import 'dart:async';
import '../ai/chat_message.dart';
import '../ai/event_stream.dart';
import '../ai/provider.dart';
import 'compaction.dart';
import 'session.dart';
import 'tool.dart';

/// Callbacks for streaming events to the UI during agent execution.
class AgentCallbacks {
  final void Function(String text)? onTextDelta;
  final void Function(String thought)? onThoughtDelta;
  final void Function(ToolCall toolCall)? onToolCallStarted;
  final void Function(ToolCall toolCall, String result, Duration duration)? onToolCallFinished;
  final void Function(ToolCall toolCall, String line)? onToolProgress;
  final void Function(String error)? onError;

  AgentCallbacks({
    this.onTextDelta,
    this.onThoughtDelta,
    this.onToolCallStarted,
    this.onToolCallFinished,
    this.onToolProgress,
    this.onError,
  });
}

/// The core agent harness managing model interactions and the tool execution loop.
class Agent {
  LLMProvider provider;
  AgentSession session;
  final Map<String, AgentTool> _tools = {};
  final int maxTurns;

  Agent({
    required this.provider,
    required this.session,
    List<AgentTool> tools = const [],
    this.maxTurns = 20,
  }) {
    for (final t in tools) {
      registerTool(t);
    }
  }

  void registerTool(AgentTool tool) {
    _tools[tool.name] = tool;
  }

  List<AgentTool> get tools => _tools.values.toList();
  bool _isCancelled = false;
  StreamSubscription? _activeStreamSub;
  Completer<void>? _turnStreamCompleter;

  /// Cancels the currently running turn and any active tool processes.
  void cancel() {
    _isCancelled = true;
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
    AgentCallbacks? callbacks,
  }) async {
    _isCancelled = false;
    session.addSystemPromptIfNeeded();
    session.addMessage(ChatMessage.user(userPrompt));

    // Auto-compact history if threshold is reached (Tau-style context window management)
    if (CompactionManager.shouldAutoCompact(session)) {
      callbacks?.onThoughtDelta?.call('\n[Context threshold reached: automatically compacting conversation history...]\n');
      await CompactionManager.compact(session: session, provider: provider);
    }

    int currentTurn = 0;

    while (currentTurn < maxTurns && !_isCancelled) {
      currentTurn++;

      final textBuffer = StringBuffer();
      final thoughtBuffer = StringBuffer();
      final toolCalls = <ToolCall>[];
      String? lastFinishReason;

      final stream = provider.streamChat(
        messages: session.messages,
        tools: tools,
      );

      bool hasError = false;
      final completer = Completer<void>();
      _turnStreamCompleter = completer;

      _activeStreamSub = stream.listen(
        (event) {
          if (_isCancelled) {
            _activeStreamSub?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          switch (event) {
            case TextDeltaEvent(:final text):
              textBuffer.write(text);
              callbacks?.onTextDelta?.call(text);

            case ThoughtDeltaEvent(:final thought):
              thoughtBuffer.write(thought);
              callbacks?.onThoughtDelta?.call(thought);

            case ToolCallCompleteEvent(:final toolCall):
              toolCalls.add(toolCall);

            case DoneEvent(
                finishReason: final fr,
                promptTokens: final pt,
                completionTokens: final ct,
              ):
              lastFinishReason = fr;
              session.recordUsage(pt, ct);

            case ErrorEvent(:final message):
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
        return;
      }

      // Record assistant message
      final assistantContent = textBuffer.toString();
      session.addMessage(
        ChatMessage.assistant(
          assistantContent,
          toolCalls: toolCalls.isNotEmpty ? toolCalls : null,
        ),
      );

      // If no tool calls were requested, this turn is done!
      if (toolCalls.isEmpty || _isCancelled) {
        break;
      }

      // Execute requested tools
      for (final call in toolCalls) {
        if (_isCancelled) break;
        callbacks?.onToolCallStarted?.call(call);

        final tool = _tools[call.name];
        tool?.onProgress = (line) {
          callbacks?.onToolProgress?.call(call, line);
        };

        String result;
        final stopwatch = Stopwatch()..start();

        if (tool == null) {
          result = 'Error: Unknown tool "${call.name}". Available tools: ${_tools.keys.join(', ')}';
        } else {
          try {
            result = await tool.execute(call.arguments);
          } catch (e, st) {
            result = 'Error executing tool "${call.name}": $e\n$st';
          }
        }
        stopwatch.stop();
        tool?.onProgress = null;

        if (_isCancelled) {
          callbacks?.onToolCallFinished?.call(call, 'Cancelled', stopwatch.elapsed);
          break;
        }

        session.toolExecutionsCount++;
        callbacks?.onToolCallFinished?.call(call, result, stopwatch.elapsed);

        // Add tool result to transcript (safely truncated if oversized)
        final sanitizedResult = _truncateToolResult(result);
        session.addMessage(
          ChatMessage.toolResult(
            toolCallId: call.id,
            toolName: call.name,
            content: sanitizedResult,
          ),
        );
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

  static String _truncateToolResult(String output) {
    if (output.length <= maxToolOutputChars) return output;
    final kept = output.substring(0, maxToolOutputChars);
    final omitted = output.length - maxToolOutputChars;
    return '$kept\n\n[... $omitted characters truncated to protect context window ...]';
  }
}
