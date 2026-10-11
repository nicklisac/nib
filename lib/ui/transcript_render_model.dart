import 'dart:math';
import 'ansi.dart';
import 'markdown_renderer.dart';
import 'theme.dart';

/// Semantic block representing a piece of conversation in the transcript render model.
sealed class TranscriptBlock {
  /// Renders this block to a list of terminal lines according to active visibility flags.
  List<String> render({
    required NibTheme theme,
    required int terminalWidth,
    bool thinkingExpanded = true,
    bool toolsExpanded = true,
  });
}

/// A user input prompt block.
class UserPromptBlock extends TranscriptBlock {
  final String text;

  UserPromptBlock(this.text);

  @override
  List<String> render({
    required NibTheme theme,
    required int terminalWidth,
    bool thinkingExpanded = true,
    bool toolsExpanded = true,
  }) {
    final lines = <String>[];
    lines.add('');
    lines.add(
      '  ${theme.muted.text('╭──')} ${theme.accent.text('✒')} ${Ansi.boldText(theme.primary.text('You'))} ${theme.muted.text('─' * 28)}',
    );
    for (final line in text.split('\n')) {
      lines.add('    ${Ansi.boldText(line)}');
    }
    lines.add('  ${theme.muted.text('╰──${'─' * 35}')}');
    lines.add('');
    return lines;
  }
}

/// A model reasoning / thinking trace block.
class ThoughtBlock extends TranscriptBlock {
  final String thought;

  ThoughtBlock(this.thought);

  @override
  List<String> render({
    required NibTheme theme,
    required int terminalWidth,
    bool thinkingExpanded = true,
    bool toolsExpanded = true,
  }) {
    final clean = thought.trim();
    if (clean.isEmpty) return const [];

    final lines = <String>[];
    if (thinkingExpanded) {
      lines.add('  ${theme.muted.text('§ ')}${theme.muted.text(clean)}');
      lines.add('');
    } else {
      // Collapsed: single compact summary line
      lines.add(
        '  ${theme.muted.text('§ ')}${theme.muted.text('[thinking collapsed — Ctrl+T to expand]')}',
      );
    }
    return lines;
  }
}

/// An assistant markdown response text block.
class AssistantTextBlock extends TranscriptBlock {
  final String text;

  AssistantTextBlock(this.text);

  @override
  List<String> render({
    required NibTheme theme,
    required int terminalWidth,
    bool thinkingExpanded = true,
    bool toolsExpanded = true,
  }) {
    final clean = text.trim();
    if (clean.isEmpty) return const [];

    final rendered = MarkdownRenderer.render(clean, theme);
    final lines = <String>[];
    for (final line in rendered.split('\n')) {
      lines.add(line);
    }
    return lines;
  }
}

/// A tool execution block (card header, arguments summary, diff/preview or full stdout, done status).
class ToolCallBlock extends TranscriptBlock {
  final String toolName;
  final Map<String, dynamic> arguments;
  final String result;
  final int durationMs;

  ToolCallBlock({
    required this.toolName,
    required this.arguments,
    required this.result,
    required this.durationMs,
  });

  @override
  List<String> render({
    required NibTheme theme,
    required int terminalWidth,
    bool thinkingExpanded = true,
    bool toolsExpanded = true,
  }) {
    final lines = <String>[];
    final argsSummary = formatArgsSummary(toolName, arguments);
    final topUsed = 10 + toolName.length;
    final topRule = max(2, 40 - topUsed);

    lines.add(
      '  ${theme.muted.text('╭──')} ${theme.warning.text('›_')} ${theme.accent.text(toolName)} ${theme.muted.text('─' * topRule)}',
    );

    if (argsSummary.isNotEmpty) {
      for (final line in argsSummary.split('\n')) {
        lines.add('    ${theme.secondary.text(line)}');
      }
    }

    final preview = formatPreview(
      toolName: toolName,
      result: result,
      terminalWidth: terminalWidth,
      fullOutput: toolsExpanded,
      theme: theme,
    );
    for (final line in preview) {
      lines.add('    $line');
    }

    final doneText = 'done (${durationMs}ms)';
    final bottomUsed = 9 + doneText.length;
    final bottomRule = max(2, 40 - bottomUsed);
    lines.add(
      '  ${theme.muted.text('╰──')} ${theme.success.text('✔')} ${theme.muted.text(doneText)} ${theme.muted.text('─' * bottomRule)}',
    );
    lines.add('');
    return lines;
  }

  static String formatArgsSummary(String toolName, Map<String, dynamic> args) {
    if (toolName == 'bash' && args.containsKey('command')) {
      return '"${args['command']}"';
    }
    if ((toolName == 'read_file' ||
            toolName == 'write_file' ||
            toolName == 'edit_file') &&
        args.containsKey('path')) {
      final path = args['path'] as String;
      if (args.containsKey('start_line') || args.containsKey('end_line')) {
        return '$path (${args['start_line'] ?? 1}-${args['end_line'] ?? 'end'})';
      }
      return path;
    }
    if (toolName == 'list_dir' && args.containsKey('path')) {
      return args['path'] as String;
    }
    if (toolName == 'search_files' && args.containsKey('query')) {
      return '"${args['query']}"';
    }
    if (args.isEmpty) return '';
    return args.entries.map((e) => '${e.key}: ${e.value}').take(2).join(', ');
  }

  static List<String> formatPreview({
    required String toolName,
    required String result,
    required int terminalWidth,
    required bool fullOutput,
    required NibTheme theme,
  }) {
    final rawLines = result.split('\n');
    if (rawLines.isEmpty || (rawLines.length == 1 && rawLines[0].isEmpty)) {
      return [];
    }

    final cardWidth = terminalWidth > 100 ? 100 : terminalWidth;
    final innerWidth = max(20, cardWidth - 8);

    if (toolName == 'edit_file') {
      final maxDiff = fullOutput ? rawLines.length : 14;
      final shown = rawLines.take(maxDiff).toList();
      final res = <String>[];
      for (final line in shown) {
        res.addAll(_wrapText(line, innerWidth));
      }
      if (!fullOutput && rawLines.length > maxDiff) {
        res.add(
          theme.muted.text('... (${rawLines.length - maxDiff} more lines)'),
        );
      }
      return res;
    }

    final maxPreview = fullOutput ? rawLines.length : 6;
    final shown = rawLines.take(maxPreview).toList();
    final res = <String>[];
    for (final line in shown) {
      for (final w in _wrapText(line, innerWidth)) {
        res.add(theme.muted.text(w));
      }
    }
    if (!fullOutput && rawLines.length > maxPreview) {
      res.add(
        theme.muted.text('... (${rawLines.length - maxPreview} more lines)'),
      );
    }
    return res;
  }

  static List<String> _wrapText(String text, int width) {
    final result = <String>[];
    for (final paragraph in text.split('\n')) {
      if (paragraph.length <= width) {
        result.add(paragraph);
        continue;
      }
      final words = paragraph.split(' ');
      final current = StringBuffer();
      for (final word in words) {
        if (current.isEmpty) {
          if (word.length <= width) {
            current.write(word);
          } else {
            var w = word;
            while (w.length > width) {
              result.add(w.substring(0, width));
              w = w.substring(width);
            }
            current.write(w);
          }
        } else if (current.length + 1 + word.length <= width) {
          current.write(' $word');
        } else {
          result.add(current.toString());
          current.clear();
          current.write(word);
        }
      }
      if (current.isNotEmpty) {
        result.add(current.toString());
      }
    }
    return result;
  }
}

/// An arbitrary separator or status announcement block in the transcript.
class StatusBlock extends TranscriptBlock {
  final String message;

  StatusBlock(this.message);

  @override
  List<String> render({
    required NibTheme theme,
    required int terminalWidth,
    bool thinkingExpanded = true,
    bool toolsExpanded = true,
  }) => [message];
}

/// The in-memory retained model of transcript blocks for replay and filtering.
class TranscriptRenderModel {
  final List<TranscriptBlock> _blocks = [];

  List<TranscriptBlock> get blocks => List.unmodifiable(_blocks);

  void add(TranscriptBlock block) {
    _blocks.add(block);
  }

  void clear() {
    _blocks.clear();
  }

  /// Renders all blocks to terminal lines using current visibility settings.
  List<String> renderAll({
    required NibTheme theme,
    required int terminalWidth,
    bool thinkingExpanded = true,
    bool toolsExpanded = true,
  }) {
    final lines = <String>[];
    for (final block in _blocks) {
      lines.addAll(
        block.render(
          theme: theme,
          terminalWidth: terminalWidth,
          thinkingExpanded: thinkingExpanded,
          toolsExpanded: toolsExpanded,
        ),
      );
    }
    return lines;
  }
}
