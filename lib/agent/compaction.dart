import 'package:nib/agent/session.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/event_stream.dart';
import 'package:nib/ai/provider.dart';

/// Context window management & compaction inspired directly by Tau's context_window.py.
class CompactionManager {
  static const int defaultContextWindowTokens = 128000;
  static const int defaultCompactionReserveTokens = 16384;
  static const int defaultKeepRecentMessages = 4; // Keep recent turns intact
  static const int summaryMessageCharLimit = 500;
  static const String compactionSummaryPrefix = 'Previous conversation summary:\n';

  static const String summarizationSystemPrompt =
      'You are a context summarization assistant. Your task is to read a conversation '
      'between a user and an AI coding assistant, then produce a structured summary '
      'following the exact format specified.\n\n'
      'Do NOT continue the conversation. Do NOT respond to any questions in the '
      'conversation. ONLY output the structured summary.';

  static const String summarizationPrompt =
      'The messages above are a conversation to summarize. Create a structured context '
      'checkpoint summary that another LLM will use to continue the work.\n\n'
      'Use this EXACT format:\n\n'
      '## Goal\n'
      '[What is the user trying to accomplish? Can be multiple items if the session '
      'covers different tasks.]\n\n'
      '## Constraints & Preferences\n'
      '- [Any constraints, preferences, or requirements mentioned by user]\n'
      '- [Or "(none)" if none were mentioned]\n\n'
      '## Progress\n'
      '### Done\n'
      '- [x] [Completed tasks/changes]\n\n'
      '### In Progress\n'
      '- [ ] [Current work]\n\n'
      '### Blocked\n'
      '- [Issues preventing progress, if any]\n\n'
      '## Key Decisions\n'
      '- **[Decision]**: [Brief rationale]\n\n'
      '## Next Steps\n'
      '1. [Ordered list of what should happen next]\n\n'
      '## Critical Context\n'
      '- [Any data, examples, or references needed to continue]\n'
      '- [Or "(none)" if not applicable]\n\n'
      'Keep each section concise. Preserve exact file paths, function names, and error messages.';

  static int estimateTokens(List<ChatMessage> messages, {String? systemPrompt}) {
    int chars = systemPrompt?.length ?? 0;
    for (final m in messages) {
      chars += (m.content?.length ?? 0) + 16;
      if (m.toolCalls != null) {
        for (final tc in m.toolCalls!) {
          chars += tc.name.length + tc.arguments.toString().length + 32;
        }
      }
    }
    return (chars / 4).ceil();
  }

  /// Determines if automatic compaction should trigger based on context token limit.
  static bool shouldAutoCompact(
    AgentSession session, {
    int contextWindow = defaultContextWindowTokens,
    int reserve = defaultCompactionReserveTokens,
  }) {
    if (session.messages.length <= defaultKeepRecentMessages + 2) {
      return false;
    }
    final threshold = contextWindow - reserve;
    final estimated = estimateTokens(session.messages, systemPrompt: session.systemPrompt);
    return estimated >= threshold;
  }

  /// Compacts older session history into a structured summary (Tau-style).
  ///
  /// Preserves the most recent [keepRecentCount] messages and replaces the older
  /// history with a single `Previous conversation summary:\n...` user message.
  static Future<CompactionResult> compact({
    required AgentSession session,
    required LLMProvider provider,
    String? customInstructions,
    int keepRecentCount = defaultKeepRecentMessages,
  }) async {
    final allMessages = List<ChatMessage>.from(session.messages);

    if (allMessages.length <= keepRecentCount) {
      return CompactionResult(
        success: false,
        summary: '',
        replacedMessageCount: 0,
        tokensBefore: estimateTokens(allMessages, systemPrompt: session.systemPrompt),
        tokensAfter: estimateTokens(allMessages, systemPrompt: session.systemPrompt),
      );
    }

    final splitIndex = allMessages.length - keepRecentCount;
    final messagesToSummarize = allMessages.sublist(0, splitIndex);
    final messagesToKeep = allMessages.sublist(splitIndex);

    final tokensBefore = estimateTokens(allMessages, systemPrompt: session.systemPrompt);

    // Build the serialized conversation log for summarization
    final serialized = _serializeMessagesForCompaction(messagesToSummarize);

    String summary;
    try {
      summary = await _generateSummaryWithProvider(
        provider: provider,
        serializedConversation: serialized,
        customInstructions: customInstructions,
      );
    } catch (_) {
      // Deterministic fallback if LLM request fails or in offline/mock mode
      summary = _deterministicFallbackSummary(messagesToSummarize);
    }

    // Reconstruct messages list:
    // [0] = summary message
    // [1..] = preserved recent messages
    session.clearMessages();
    session.addMessage(ChatMessage.user('$compactionSummaryPrefix$summary'));
    for (final kept in messagesToKeep) {
      session.addMessage(kept);
    }

    await session.saveToDisk();

    final tokensAfter = estimateTokens(session.messages, systemPrompt: session.systemPrompt);

    return CompactionResult(
      success: true,
      summary: summary,
      replacedMessageCount: messagesToSummarize.length,
      tokensBefore: tokensBefore,
      tokensAfter: tokensAfter,
    );
  }

  static String _serializeMessagesForCompaction(List<ChatMessage> messages) {
    final buf = StringBuffer();
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final role = msg.role;
      buf.writeln('<message index="${i + 1}" role="$role">');
      if (msg.content != null && msg.content!.isNotEmpty) {
        buf.writeln(msg.content);
      }
      if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
        buf.writeln('<tool-calls>');
        for (final tc in msg.toolCalls!) {
          buf.writeln('- ${tc.name}: ${tc.arguments}');
        }
        buf.writeln('</tool-calls>');
      }
      buf.writeln('</message>');
    }
    return buf.toString();
  }

  static Future<String> _generateSummaryWithProvider({
    required LLMProvider provider,
    required String serializedConversation,
    String? customInstructions,
  }) async {
    final prompt = StringBuffer();
    prompt.writeln('<conversation>');
    prompt.writeln(serializedConversation);
    prompt.writeln('</conversation>\n');
    prompt.writeln(summarizationPrompt);

    if (customInstructions != null && customInstructions.trim().isNotEmpty) {
      prompt.writeln('\nAdditional focus: ${customInstructions.trim()}');
    }

    final summaryMessages = [
      ChatMessage.system(summarizationSystemPrompt),
      ChatMessage.user(prompt.toString()),
    ];

    final stream = provider.streamChat(
      messages: summaryMessages,
      tools: const [],
    );
    final buffer = StringBuffer();

    await for (final event in stream) {
      if (event is TextDeltaEvent) {
        buffer.write(event.text);
      } else if (event is ErrorEvent) {
        throw Exception(event.message);
      }
    }

    final result = buffer.toString().trim();
    if (result.isEmpty) {
      throw Exception('Empty summary generated');
    }
    return result;
  }

  static String _deterministicFallbackSummary(List<ChatMessage> messages) {
    final buf = StringBuffer();
    buf.writeln('## Goal');
    // Extract first user message
    final firstUser = messages.firstWhere(
      (m) => m.role == Role.user,
      orElse: () => messages.first,
    );
    final userText = firstUser.content ?? '';
    buf.writeln(userText.length > 200
        ? '${userText.substring(0, 197)}...'
        : userText);

    buf.writeln('\n## Progress');
    buf.writeln('### Done');
    int toolCount = 0;
    for (final m in messages) {
      if (m.toolCalls != null) toolCount += m.toolCalls!.length;
    }
    buf.writeln('- [x] Compacted ${messages.length} prior conversation entries ($toolCount tool actions executed).');

    buf.writeln('\n## Critical Context');
    buf.writeln('- Retained active working directory & recent turns.');
    return buf.toString();
  }
}

class CompactionResult {
  final bool success;
  final String summary;
  final int replacedMessageCount;
  final int tokensBefore;
  final int tokensAfter;

  CompactionResult({
    required this.success,
    required this.summary,
    required this.replacedMessageCount,
    required this.tokensBefore,
    required this.tokensAfter,
  });
}
