import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../agent/tool.dart';
import 'chat_message.dart';
import 'event_stream.dart';
import 'provider.dart';

/// Provider for Anthropic Messages API (Claude 3.5 Sonnet, Haiku, Opus, Claude 3.7).
class AnthropicProvider implements LLMProvider {
  @override
  final String name;

  @override
  final String model;

  final String apiKey;
  final String baseUrl;

  AnthropicProvider({
    this.name = 'Anthropic',
    required this.model,
    required this.apiKey,
    String? baseUrl,
  }) : baseUrl = (baseUrl ?? 'https://api.anthropic.com/v1').replaceAll(RegExp(r'/+$'), '');

  @override
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
  }) async* {
    final client = http.Client();
    try {
      final uri = Uri.parse('$baseUrl/messages');

      // Extract system messages for Anthropic top-level system parameter
      final systemMessages = messages.where((m) => m.role == Role.system).toList();
      final systemPrompt = systemMessages.map((m) => m.content ?? '').join('\n\n');

      final conversationMessages = <Map<String, dynamic>>[];
      for (final msg in messages) {
        if (msg.role == Role.system) continue;

        if (msg.role == Role.user) {
          if (conversationMessages.isNotEmpty &&
              conversationMessages.last['role'] == 'user') {
            final prev = conversationMessages.last['content'];
            if (prev is String) {
              conversationMessages.last['content'] = '$prev\n\n${msg.content ?? ''}';
            } else if (prev is List) {
              prev.add({'type': 'text', 'text': msg.content ?? ''});
            }
          } else {
            conversationMessages.add({
              'role': 'user',
              'content': msg.content ?? '',
            });
          }
        } else if (msg.role == Role.assistant) {
          final contentList = <Map<String, dynamic>>[];
          if (msg.content != null && msg.content!.isNotEmpty) {
            contentList.add({'type': 'text', 'text': msg.content!});
          }
          if (msg.toolCalls != null) {
            for (final call in msg.toolCalls!) {
              contentList.add({
                'type': 'tool_use',
                'id': call.id,
                'name': call.name,
                'input': call.arguments,
              });
            }
          }
          conversationMessages.add({
            'role': 'assistant',
            'content': contentList,
          });
        } else if (msg.role == Role.tool) {
          final resultBlock = {
            'type': 'tool_result',
            'tool_use_id': msg.toolCallId ?? '',
            'content': msg.content ?? '',
          };
          if (conversationMessages.isNotEmpty &&
              conversationMessages.last['role'] == 'user' &&
              conversationMessages.last['content'] is List) {
            (conversationMessages.last['content'] as List).add(resultBlock);
          } else {
            conversationMessages.add({
              'role': 'user',
              'content': [resultBlock],
            });
          }
        }
      }

      final requestBody = <String, dynamic>{
        'model': model,
        'messages': conversationMessages,
        'max_tokens': 4096,
        'stream': true,
        if (systemPrompt.isNotEmpty) 'system': systemPrompt,
        if (temperature != null) 'temperature': temperature,
      };

      if (tools.isNotEmpty) {
        requestBody['tools'] = tools.map((t) => t.toAnthropicSchema()).toList();
      }

      http.StreamedResponse? streamedResponse;
      int attempts = 0;
      const maxAttempts = 3;

      while (attempts < maxAttempts) {
        attempts++;
        final request = http.Request('POST', uri)
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'text/event-stream'
          ..headers['x-api-key'] = apiKey
          ..headers['anthropic-version'] = '2023-06-01'
          ..body = jsonEncode(requestBody);

        try {
          final res = await client.send(request);
          if (res.statusCode == 200) {
            streamedResponse = res;
            break;
          }

          if ((res.statusCode == 429 || res.statusCode >= 500) && attempts < maxAttempts) {
            final retryAfterSec = int.tryParse(res.headers['retry-after'] ?? '');
            final delayMs = retryAfterSec != null
                ? retryAfterSec * 1000
                : (1000 * (1 << (attempts - 1)));
            await Future.delayed(Duration(milliseconds: delayMs));
            continue;
          }

          final errorBody = await res.stream.bytesToString();
          yield ErrorEvent('Anthropic API HTTP ${res.statusCode}: $errorBody');
          return;
        } catch (e) {
          if (attempts < maxAttempts) {
            await Future.delayed(Duration(milliseconds: 1000 * (1 << (attempts - 1))));
            continue;
          }
          yield ErrorEvent('Anthropic API Connection Error: $e');
          return;
        }
      }

      if (streamedResponse == null) {
        yield ErrorEvent('Failed to connect to Anthropic API after $maxAttempts attempts.');
        return;
      }

      String? finishReason;
      int? promptTokens;
      int? completionTokens;

      // Track active tool block: id, name, jsonAccumulator
      String? currentToolId;
      String? currentToolName;
      final currentToolJson = StringBuffer();

      final lines = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;

        final data = trimmed.substring(5).trim();
        if (data.isEmpty) continue;

        Map<String, dynamic> event;
        try {
          event = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final type = event['type'] as String?;
        if (type == null) continue;

        switch (type) {
          case 'message_start':
            final message = event['message'] as Map<String, dynamic>?;
            if (message != null && message['usage'] is Map) {
              final usage = message['usage'] as Map<String, dynamic>;
              promptTokens = usage['input_tokens'] as int?;
            }
            break;

          case 'content_block_start':
            final block = event['content_block'] as Map<String, dynamic>?;
            if (block != null && block['type'] == 'tool_use') {
              currentToolId = block['id'] as String?;
              currentToolName = block['name'] as String?;
              currentToolJson.clear();
            }
            break;

          case 'content_block_delta':
            final delta = event['delta'] as Map<String, dynamic>?;
            if (delta != null) {
              final deltaType = delta['type'] as String?;
              if (deltaType == 'text_delta') {
                final text = delta['text'] as String?;
                if (text != null) yield TextDeltaEvent(text);
              } else if (deltaType == 'input_json_delta') {
                final partial = delta['partial_json'] as String?;
                if (partial != null) currentToolJson.write(partial);
              } else if (deltaType == 'thinking_delta') {
                final thinking = delta['thinking'] as String?;
                if (thinking != null) yield ThoughtDeltaEvent(thinking);
              }
            }
            break;

          case 'content_block_stop':
            if (currentToolId != null && currentToolName != null) {
              final raw = currentToolJson.toString();
              Map<String, dynamic> args = {};
              if (raw.isNotEmpty) {
                try {
                  args = jsonDecode(raw) as Map<String, dynamic>;
                } catch (_) {
                  args = {'raw': raw};
                }
              }
              yield ToolCallCompleteEvent(
                ToolCall(
                  id: currentToolId,
                  name: currentToolName,
                  arguments: args,
                ),
              );
              currentToolId = null;
              currentToolName = null;
              currentToolJson.clear();
            }
            break;

          case 'message_delta':
            final delta = event['delta'] as Map<String, dynamic>?;
            if (delta != null && delta['stop_reason'] != null) {
              finishReason = delta['stop_reason'] as String;
            }
            final usage = event['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              completionTokens = usage['output_tokens'] as int?;
            }
            break;

          case 'message_stop':
            yield DoneEvent(
              finishReason: finishReason,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
            );
            break;
        }
      }
    } catch (e) {
      yield ErrorEvent('Anthropic provider error: $e', e);
    } finally {
      client.close();
    }
  }
}
