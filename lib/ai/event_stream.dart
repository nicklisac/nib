import 'chat_message.dart';

/// Base class for all model streaming events.
sealed class StreamEvent {}

/// Text token emitted by the model during generation.
class TextDeltaEvent extends StreamEvent {
  final String text;
  TextDeltaEvent(this.text);
}

/// Thought / reasoning delta token emitted by reasoning models (e.g. DeepSeek-R1, o3-mini).
class ThoughtDeltaEvent extends StreamEvent {
  final String thought;
  ThoughtDeltaEvent(this.thought);
}

/// A complete tool call produced by the model.
class ToolCallCompleteEvent extends StreamEvent {
  final ToolCall toolCall;
  ToolCallCompleteEvent(this.toolCall);
}

/// Model has finished generating for this turn.
class DoneEvent extends StreamEvent {
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;

  DoneEvent({this.finishReason, this.promptTokens, this.completionTokens});
}

/// An error occurred during streaming.
class ErrorEvent extends StreamEvent {
  final String message;
  final Object? error;
  ErrorEvent(this.message, [this.error]);
}
