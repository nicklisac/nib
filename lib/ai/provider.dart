import '../agent/thinking_level.dart';
import '../agent/tool.dart';
import 'chat_message.dart';
import 'event_stream.dart';

/// Abstract provider interface for streaming completions with tool calling.
abstract class LLMProvider {
  /// User-friendly name of the provider (e.g. "OpenAI", "Anthropic", "Ollama", "Mock").
  String get name;

  /// Current model name (e.g. "gpt-4o", "claude-3-5-sonnet", "llama3").
  String get model;

  /// Streams events for the conversation transcript and registered tools.
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
    int? maxTokens,
    ThinkingLevel? thinkingLevel,
  });
}
