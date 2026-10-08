import 'dart:async';
import '../agent/tool.dart';
import 'chat_message.dart';
import 'event_stream.dart';
import 'provider.dart';

/// Offline mock provider for demonstration, testing, and zero-key local usage.
class MockProvider implements LLMProvider {
  @override
  final String name = 'Mock (Offline Demo)';

  @override
  final String model = 'mock-agent-v1';

  int _turnCount = 0;

  @override
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
  }) async* {
    final lastMessage = messages.last;

    // If the last message was a tool result, synthesize an explanation
    if (lastMessage.role == Role.tool) {
      final toolName = lastMessage.toolName ?? 'tool';
      final resultPreview = (lastMessage.content ?? '').split('\n').take(3).join(' ');

      yield ThoughtDeltaEvent('Analyzing tool result from $toolName...\n');
      await Future.delayed(const Duration(milliseconds: 100));

      yield TextDeltaEvent('I have executed `$toolName` and reviewed the output.\n\n');
      await Future.delayed(const Duration(milliseconds: 80));

      yield TextDeltaEvent('Here is what I found:\n');
      yield TextDeltaEvent('> $resultPreview...\n\n');
      await Future.delayed(const Duration(milliseconds: 80));

      yield TextDeltaEvent('The operation succeeded. Let me know what you would like to do next!');
      yield DoneEvent(finishReason: 'stop', promptTokens: 120, completionTokens: 45);
      return;
    }

    _turnCount++;
    final userText = (lastMessage.content ?? '').toLowerCase();

    // Check if this is a compaction summarization request
    if (userText.contains('<conversation>') || userText.contains('checkpoint summary')) {
      yield ThoughtDeltaEvent('Compacting conversation history...\n');
      yield TextDeltaEvent('## Goal\nAccomplish user development goals.\n\n## Progress\n### Done\n- [x] Processed prior turns.\n\n## Critical Context\n- Retained workspace state.');
      yield DoneEvent(finishReason: 'stop', promptTokens: 80, completionTokens: 30);
      return;
    }

    // Check if user is asking for a table
    if (userText.contains('table')) {
      yield ThoughtDeltaEvent('Generating breakdown table...\n');
      await Future.delayed(const Duration(milliseconds: 100));

      final tableMarkdown = 'Here is the summary table:\n\n'
          '| Component | Status | Speed |\n'
          '|:---|:---:|---:|\n'
          '| `StreamingPrinter` | active | instant |\n'
          '| `MarkdownRenderer` | active | fast |\n'
          '| `PromptReader` | active | responsive |\n\n'
          'All components are ready.';

      for (final line in tableMarkdown.split('\n')) {
        yield TextDeltaEvent('$line\n');
        await Future.delayed(const Duration(milliseconds: 50));
      }
      yield DoneEvent(finishReason: 'stop', promptTokens: 60, completionTokens: 40);
      return;
    }

    // Check if user is asking to list, read, or run something
    if (userText.contains('ls') || userText.contains('list') || userText.contains('files')) {
      yield ThoughtDeltaEvent('User requested file inspection. Invoking list_dir...\n');
      await Future.delayed(const Duration(milliseconds: 120));

      yield TextDeltaEvent("Let me check the files in this directory for you.\n");
      await Future.delayed(const Duration(milliseconds: 80));

      yield ToolCallCompleteEvent(
        ToolCall(
          id: 'mock_call_$_turnCount',
          name: 'list_dir',
          arguments: {'path': '.'},
        ),
      );
      yield DoneEvent(finishReason: 'tool_calls');
      return;
    }

    if (userText.contains('read') || userText.contains('cat') || userText.contains('pubspec')) {
      yield ThoughtDeltaEvent('User wants to read pubspec.yaml. Invoking read_file...\n');
      await Future.delayed(const Duration(milliseconds: 120));

      yield TextDeltaEvent("I'll read `pubspec.yaml` to check the project dependencies.\n");
      await Future.delayed(const Duration(milliseconds: 80));

      yield ToolCallCompleteEvent(
        ToolCall(
          id: 'mock_call_$_turnCount',
          name: 'read_file',
          arguments: {'path': 'pubspec.yaml'},
        ),
      );
      yield DoneEvent(finishReason: 'tool_calls');
      return;
    }

    if (userText.contains('git') || userText.contains('status')) {
      yield ThoughtDeltaEvent('Executing bash command: git status...\n');
      await Future.delayed(const Duration(milliseconds: 120));

      yield TextDeltaEvent("Running `git status` via the bash tool.\n");
      await Future.delayed(const Duration(milliseconds: 80));

      yield ToolCallCompleteEvent(
        ToolCall(
          id: 'mock_call_$_turnCount',
          name: 'bash',
          arguments: {'command': 'git status -s'},
        ),
      );
      yield DoneEvent(finishReason: 'tool_calls');
      return;
    }

    // Default conversational response
    yield ThoughtDeltaEvent('Formulating helpful response...\n');
    await Future.delayed(const Duration(milliseconds: 100));

    final reply = "Hello! I am Nib, your Dart-powered terminal coding agent (inspired by Pi & Tau).\n\n"
        "I can explore your workspace, read and edit files, and execute shell commands.\n\n"
        "Try asking me:\n"
        "  • *'List files in this project'*\n"
        "  • *'Read pubspec.yaml'*\n"
        "  • *'Check git status'*\n\n"
        "Or configure an API key via environment variable (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `OPENROUTER_API_KEY`) to connect to live models!";

    for (final word in reply.split(' ')) {
      yield TextDeltaEvent('$word ');
      await Future.delayed(const Duration(milliseconds: 25));
    }

    yield DoneEvent(finishReason: 'stop', promptTokens: 95, completionTokens: 80);
  }
}
