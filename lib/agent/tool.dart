import '../ai/image_attachment.dart';

/// The result returned by executing an [AgentTool].
class ToolResult {
  /// The textual output of the tool execution (rendered in UI, capped by maxToolOutputChars).
  final String content;

  /// Optional images produced or read by the tool for multimodal model context.
  final List<ImageAttachment>? images;

  const ToolResult(this.content, {this.images});
  const ToolResult.text(this.content) : images = null;

  @override
  String toString() => content;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolResult &&
          runtimeType == other.runtimeType &&
          content == other.content;

  @override
  int get hashCode => content.hashCode;
}

/// Definition of a tool that can be invoked by the model.
abstract class AgentTool {
  /// Unique name of the tool (e.g. 'bash', 'read_file').
  String get name;

  /// Human and model-readable description of what the tool does.
  String get description;

  /// JSON Schema parameters object defining required & optional arguments.
  Map<String, dynamic> get parameters;

  /// Executes the tool with the given arguments and returns the [ToolResult].
  Future<ToolResult> execute(Map<String, dynamic> arguments);

  /// Called if the active turn is cancelled by the user.
  void cancel() {}

  /// Optional callback invoked when the tool produces live progress or output lines.
  void Function(String line)? onProgress;

  /// Converts the tool definition into standard OpenAI tool specification.
  Map<String, dynamic> toOpenAiSchema() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };

  /// Converts the tool definition into Anthropic tool specification.
  Map<String, dynamic> toAnthropicSchema() => {
    'name': name,
    'description': description,
    'input_schema': parameters,
  };
}
