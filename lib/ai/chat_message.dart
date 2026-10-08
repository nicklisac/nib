import 'dart:convert';

/// Represents a role in the conversation.
enum Role {
  system,
  user,
  assistant,
  tool,
}

/// A tool call requested by the model.
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      };

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final func = json['function'] as Map<String, dynamic>? ?? {};
    final rawArgs = func['arguments'];
    Map<String, dynamic> args = {};
    if (rawArgs is String && rawArgs.isNotEmpty) {
      try {
        args = jsonDecode(rawArgs) as Map<String, dynamic>;
      } catch (_) {
        args = {'raw': rawArgs};
      }
    } else if (rawArgs is Map<String, dynamic>) {
      args = rawArgs;
    }

    return ToolCall(
      id: json['id'] as String? ?? 'call_${DateTime.now().millisecondsSinceEpoch}',
      name: func['name'] as String? ?? json['name'] as String? ?? '',
      arguments: args,
    );
  }
}

/// A message in the conversation transcript.
class ChatMessage {
  final Role role;
  final String? content;
  final List<ToolCall>? toolCalls;
  final String? toolCallId;
  final String? toolName;

  ChatMessage({
    required this.role,
    this.content,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
  });

  factory ChatMessage.system(String content) =>
      ChatMessage(role: Role.system, content: content);

  factory ChatMessage.user(String content) =>
      ChatMessage(role: Role.user, content: content);

  factory ChatMessage.assistant(String content, {List<ToolCall>? toolCalls}) =>
      ChatMessage(role: Role.assistant, content: content, toolCalls: toolCalls);

  factory ChatMessage.toolResult({
    required String toolCallId,
    required String toolName,
    required String content,
  }) =>
      ChatMessage(
        role: Role.tool,
        toolCallId: toolCallId,
        toolName: toolName,
        content: content,
      );

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content,
        'tool_calls': toolCalls?.map((t) => t.toJson()).toList(),
        'tool_call_id': toolCallId,
        'tool_name': toolName,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final roleStr = json['role'] as String? ?? 'user';
    final role = Role.values.firstWhere(
      (r) => r.name == roleStr,
      orElse: () => Role.user,
    );

    List<ToolCall>? toolCalls;
    if (json['tool_calls'] is List) {
      toolCalls = (json['tool_calls'] as List)
          .whereType<Map>()
          .map((m) => ToolCall.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    }

    return ChatMessage(
      role: role,
      content: json['content'] as String?,
      toolCalls: toolCalls,
      toolCallId: json['tool_call_id'] as String?,
      toolName: json['tool_name'] as String?,
    );
  }

  Map<String, dynamic> toOpenAiJson() {
    switch (role) {
      case Role.system:
        return {'role': 'system', 'content': content ?? ''};
      case Role.user:
        return {'role': 'user', 'content': content ?? ''};
      case Role.assistant:
        final map = <String, dynamic>{
          'role': 'assistant',
        };
        if (content != null && content!.isNotEmpty) {
          map['content'] = content;
        }
        if (toolCalls != null && toolCalls!.isNotEmpty) {
          map['tool_calls'] = toolCalls!.map((t) => t.toJson()).toList();
        } else if (!map.containsKey('content')) {
          map['content'] = '';
        }
        return map;
      case Role.tool:
        return {
          'role': 'tool',
          'tool_call_id': toolCallId ?? '',
          'name': toolName ?? '',
          'content': content ?? '',
        };
    }
  }
}
