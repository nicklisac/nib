import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../agent/tool.dart';
import 'chat_message.dart';
import 'event_stream.dart';
import 'provider.dart';

/// Provider for OpenAI and all OpenAI-compatible APIs:
/// OpenAI, OpenRouter, Groq, DeepSeek, Ollama, vLLM, LM Studio, etc.
class OpenAiProvider implements LLMProvider {
  @override
  final String name;

  @override
  final String model;

  final String apiKey;
  final String baseUrl;

  OpenAiProvider({
    this.name = 'OpenAI-Compatible',
    required this.model,
    required this.apiKey,
    String? baseUrl,
  }) : baseUrl = (baseUrl ?? 'https://api.openai.com/v1').replaceAll(RegExp(r'/+$'), '');

  @override
  Stream<StreamEvent> streamChat({
    required List<ChatMessage> messages,
    required List<AgentTool> tools,
    double? temperature,
  }) async* {
    final client = http.Client();
    try {
      final uri = Uri.parse('$baseUrl/chat/completions');
      final requestBody = <String, dynamic>{
        'model': model,
        'messages': messages.map((m) => m.toOpenAiJson()).toList(),
        'stream': true,
        if (temperature != null) 'temperature': temperature,
      };

      if (tools.isNotEmpty) {
        requestBody['tools'] = tools.map((t) => t.toOpenAiSchema()).toList();
        requestBody['tool_choice'] = 'auto';
      }

      http.StreamedResponse? streamedResponse;
      int attempts = 0;
      const maxAttempts = 3;

      while (attempts < maxAttempts) {
        attempts++;
        final request = http.Request('POST', uri)
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'text/event-stream'
          ..body = jsonEncode(requestBody);

        if (apiKey.isNotEmpty) {
          request.headers['Authorization'] = 'Bearer $apiKey';
        }

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
          yield ErrorEvent('API HTTP ${res.statusCode}: $errorBody');
          return;
        } catch (e) {
          if (attempts < maxAttempts) {
            await Future.delayed(Duration(milliseconds: 1000 * (1 << (attempts - 1))));
            continue;
          }
          yield ErrorEvent('API Connection Error: $e');
          return;
        }
      }

      if (streamedResponse == null) {
        yield ErrorEvent('Failed to connect to API after $maxAttempts attempts.');
        return;
      }

      // Buffer to accumulate pending tool calls
      // Index -> map of accumulated fields
      final toolCallBuffers = <int, Map<String, dynamic>>{};
      String? finishReason;
      int? promptTokens;
      int? completionTokens;

      // Stream lines from SSE
      final lines = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith(':')) {
          continue; // comment or empty heartbeat
        }

        if (!trimmed.startsWith('data:')) {
          continue;
        }

        final data = trimmed.substring(5).trim();
        if (data == '[DONE]') {
          break;
        }

        Map<String, dynamic> parsed;
        try {
          parsed = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        // Usage metadata (if streamed)
        if (parsed.containsKey('usage') && parsed['usage'] is Map) {
          final usage = parsed['usage'] as Map<String, dynamic>;
          promptTokens = usage['prompt_tokens'] as int?;
          completionTokens = usage['completion_tokens'] as int?;
        }

        final choices = parsed['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) {
          continue;
        }

        final choice = choices[0] as Map<String, dynamic>;
        if (choice.containsKey('finish_reason') && choice['finish_reason'] != null) {
          finishReason = choice['finish_reason'] as String;
        }

        final delta = choice['delta'] as Map<String, dynamic>?;
        if (delta == null) {
          continue;
        }

        // Reasoning / thought token (e.g., DeepSeek R1, OpenAI o1/o3 reasoning models)
        final reasoning = delta['reasoning_content'] as String? ?? delta['reasoning'] as String?;
        if (reasoning != null && reasoning.isNotEmpty) {
          yield ThoughtDeltaEvent(reasoning);
        }

        // Content delta token
        final content = delta['content'] as String?;
        if (content != null && content.isNotEmpty) {
          yield TextDeltaEvent(content);
        }

        // Tool call chunk
        final rawToolCalls = delta['tool_calls'] as List<dynamic>?;
        if (rawToolCalls != null) {
          for (final rawCall in rawToolCalls) {
            if (rawCall is! Map<String, dynamic>) continue;
            final index = (rawCall['index'] as num?)?.toInt() ?? 0;
            final id = rawCall['id'] as String?;
            final func = rawCall['function'] as Map<String, dynamic>?;

            final buf = toolCallBuffers.putIfAbsent(index, () => {
                  'id': id ?? '',
                  'name': '',
                  'arguments': StringBuffer(),
                });

            if (id != null && id.isNotEmpty) {
              buf['id'] = id;
            }
            if (func != null) {
              final name = func['name'] as String?;
              if (name != null && name.isNotEmpty) {
                buf['name'] = (buf['name'] as String) + name;
              }
              final argChunk = func['arguments'] as String?;
              if (argChunk != null && argChunk.isNotEmpty) {
                (buf['arguments'] as StringBuffer).write(argChunk);
              }
            }
          }
        }
      }

      // Emit all completed tool calls
      for (final entry in toolCallBuffers.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
        final buf = entry.value;
        final id = buf['id'] as String;
        final name = buf['name'] as String;
        final rawArgs = (buf['arguments'] as StringBuffer).toString();

        Map<String, dynamic> arguments = {};
        if (rawArgs.isNotEmpty) {
          try {
            arguments = jsonDecode(rawArgs) as Map<String, dynamic>;
          } catch (_) {
            arguments = {'raw': rawArgs};
          }
        }

        yield ToolCallCompleteEvent(
          ToolCall(
            id: id.isNotEmpty ? id : 'call_${entry.key}',
            name: name,
            arguments: arguments,
          ),
        );
      }

      yield DoneEvent(
        finishReason: finishReason,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
    } catch (e) {
      yield ErrorEvent('OpenAI provider error: $e', e);
    } finally {
      client.close();
    }
  }
}
