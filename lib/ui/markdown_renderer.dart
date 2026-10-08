import 'package:dart_console/dart_console.dart';
import 'ansi.dart';
import 'theme.dart';

/// Formatter that decorates Markdown elements with ANSI escape codes for terminal CLI display.
class MarkdownRenderer {
  /// Renders a full markdown string with terminal styling and TrueColor syntax highlighting.
  static String render(String markdown) {
    final theme = NibTheme.current;
    final lines = markdown.split('\n');
    final buffer = StringBuffer();
    bool inCodeBlock = false;
    String codeBlockLang = '';

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Code block start / end
      if (trimmed.startsWith('```')) {
        if (!inCodeBlock) {
          inCodeBlock = true;
          codeBlockLang = trimmed.substring(3).trim().toLowerCase();
          final langTag = codeBlockLang.isNotEmpty ? ' $codeBlockLang ' : ' code ';
          buffer.writeln('  ${theme.muted.text('╭─')}${theme.accent.text(langTag)}${theme.muted.text('─────────────────────────────────────────╮')}');
        } else {
          inCodeBlock = false;
          codeBlockLang = '';
          buffer.writeln('  ${theme.muted.text('╰──────────────────────────────────────────────────╯')}');
        }
        continue;
      }

      if (inCodeBlock) {
        // Indent and syntax-tint code block lines
        buffer.writeln('  ${theme.muted.text('│')} ${_highlightCodeLine(line, codeBlockLang, theme)}');
        continue;
      }

      // Headers
      if (trimmed.startsWith('# ')) {
        final title = trimmed.substring(2);
        buffer.writeln();
        buffer.writeln('  ${Ansi.boldText(theme.accent.text(title))}');
        buffer.writeln('  ${theme.muted.text('━' * (title.length + 2))}');
        continue;
      } else if (trimmed.startsWith('## ')) {
        final title = trimmed.substring(3);
        buffer.writeln();
        buffer.writeln('  ${Ansi.boldText(theme.secondary.text(title))}');
        buffer.writeln('  ${theme.muted.text('─' * (title.length + 2))}');
        continue;
      } else if (trimmed.startsWith('### ')) {
        final title = trimmed.substring(4);
        buffer.writeln();
        buffer.writeln('  ${Ansi.boldText(theme.info.text(title))}');
        continue;
      }

      // Markdown Tables
      if (_isTableStart(lines, i)) {
        final (tableOutput, nextIndex) = _renderTable(lines, i, theme);
        buffer.write(tableOutput);
        i = nextIndex - 1;
        continue;
      }

      // Bullet lists
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        final content = trimmed.substring(2);
        buffer.writeln('  ${theme.accent.text('•')} ${_formatInline(content, theme)}');
        continue;
      }

      // Numbered lists
      final numMatch = RegExp(r'^(\d+\.)\s+(.+)$').firstMatch(trimmed);
      if (numMatch != null) {
        final numPart = numMatch.group(1)!;
        final rest = numMatch.group(2)!;
        buffer.writeln('  ${theme.accent.text(numPart)} ${_formatInline(rest, theme)}');
        continue;
      }

      // Blockquotes
      if (trimmed.startsWith('> ')) {
        buffer.writeln('  ${theme.muted.text('│')} ${theme.muted.text(trimmed.substring(2))}');
        continue;
      }

      // Regular line with inline formatting
      buffer.writeln(_formatInline(line, theme));
    }

    return buffer.toString().trimRight();
  }

  /// Highlights inline elements like `code`, **bold**, *italic*, and [links](url).
  static String _formatInline(String text, NibTheme theme) {
    var result = text;

    // Inline code `...`
    result = result.replaceAllMapped(RegExp(r'`([^`]+)`'), (match) {
      final code = match.group(1)!;
      return '${theme.surface.bg}${theme.code.fg} $code \x1B[0m';
    });

    // Bold **...**
    result = result.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (match) {
      final bold = match.group(1)!;
      return Ansi.boldText(bold);
    });

    // Italic *...*
    result = result.replaceAllMapped(RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)'), (match) {
      final it = match.group(1)!;
      return '\x1B[3m$it\x1B[23m';
    });

    // Links [text](url)
    result = result.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (match) {
      final linkText = match.group(1)!;
      final url = match.group(2)!;
      return '${theme.accent.text(linkText)} ${theme.muted.text('($url)')}';
    });

    return result;
  }

  /// Multi-language syntax tinting based on detected code block language.
  static String _highlightCodeLine(String line, String lang, NibTheme theme) {
    var res = line;

    // Comments
    final trimmed = res.trim();
    if (trimmed.startsWith('//') ||
        trimmed.startsWith('#') ||
        trimmed.startsWith('/*') ||
        trimmed.startsWith('--')) {
      return theme.muted.text(res);
    }

    // Strings in quotes ('...' or "...")
    res = res.replaceAllMapped(
      RegExp(r'''('[^']*'|"[^"]*")'''),
      (m) => theme.diffAdd.text(m.group(0)!),
    );

    // Numbers
    res = res.replaceAllMapped(
      RegExp(r'\b\d+(\.\d+)?\b'),
      (m) => theme.code.text(m.group(0)!),
    );

    // Language-specific keywords
    final keywords = _getKeywordsForLanguage(lang);
    for (final kw in keywords) {
      res = res.replaceAllMapped(
        RegExp('\\b$kw\\b'),
        (m) => theme.secondary.text(m.group(0)!),
      );
    }

    return res;
  }

  static List<String> _getKeywordsForLanguage(String lang) {
    switch (lang) {
      case 'dart':
        return [
          'import', 'export', 'library', 'part', 'as', 'show', 'hide',
          'class', 'enum', 'extension', 'mixin', 'typedef',
          'final', 'const', 'var', 'late', 'void', 'static', 'dynamic',
          'int', 'double', 'String', 'bool', 'List', 'Map', 'Set', 'Future', 'Stream',
          'async', 'await', 'return', 'yield',
          'if', 'else', 'switch', 'case', 'default', 'for', 'while', 'do', 'in',
          'break', 'continue', 'try', 'catch', 'finally', 'throw', 'rethrow',
          'get', 'set', 'this', 'super', 'new', 'is', 'required', 'true', 'false', 'null',
        ];

      case 'py':
      case 'python':
        return [
          'def', 'class', 'import', 'from', 'as', 'return', 'yield',
          'if', 'elif', 'else', 'for', 'while', 'break', 'continue',
          'try', 'except', 'finally', 'raise', 'with', 'lambda', 'pass',
          'async', 'await', 'self', 'None', 'True', 'False',
          'int', 'str', 'float', 'bool', 'list', 'dict', 'set', 'tuple',
        ];

      case 'js':
      case 'javascript':
      case 'ts':
      case 'typescript':
        return [
          'function', 'const', 'let', 'var', 'return', 'yield',
          'if', 'else', 'switch', 'case', 'default', 'for', 'while', 'do',
          'break', 'continue', 'try', 'catch', 'finally', 'throw',
          'async', 'await', 'class', 'interface', 'type', 'extends', 'implements',
          'import', 'from', 'export', 'default', 'new', 'this', 'super',
          'true', 'false', 'null', 'undefined',
        ];

      case 'bash':
      case 'sh':
      case 'shell':
      case 'zsh':
        return [
          'if', 'then', 'else', 'elif', 'fi', 'case', 'esac',
          'for', 'while', 'do', 'done', 'in', 'until',
          'echo', 'export', 'set', 'unset', 'exit', 'return', 'local',
          'function', 'source', 'alias',
        ];

      case 'sql':
        return [
          'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'UPDATE', 'DELETE',
          'CREATE', 'TABLE', 'DROP', 'ALTER', 'JOIN', 'LEFT', 'RIGHT', 'INNER',
          'GROUP', 'BY', 'ORDER', 'HAVING', 'LIMIT', 'OFFSET', 'AND', 'OR',
          'NOT', 'NULL', 'AS', 'ON', 'IN', 'IS', 'DISTINCT', 'COUNT', 'PRIMARY', 'KEY',
          'select', 'from', 'where', 'insert', 'into', 'update', 'delete',
          'create', 'table', 'drop', 'alter', 'join', 'left', 'right', 'inner',
          'group', 'by', 'order', 'having', 'limit', 'offset', 'and', 'or',
          'not', 'null', 'as', 'on', 'in', 'is', 'distinct', 'count', 'primary', 'key',
        ];

      case 'json':
      case 'yaml':
      case 'yml':
        return ['true', 'false', 'null', 'TRUE', 'FALSE', 'NULL'];

      default:
        return [
          'import', 'class', 'function', 'def', 'return', 'if', 'else',
          'for', 'while', 'const', 'final', 'var', 'let', 'async', 'await',
          'true', 'false', 'null',
        ];
    }
  }

  static bool _isTableStart(List<String> lines, int i) {
    if (i + 1 >= lines.length) return false;
    final current = lines[i].trim();
    final next = lines[i + 1].trim();
    if (!current.contains('|') || !next.contains('|') || !next.contains('-')) {
      return false;
    }
    return _isDelimiterRow(next);
  }

  static bool _isDelimiterRow(String line) {
    final cells = _splitRow(line);
    if (cells.isEmpty) return false;
    return cells.every((cell) => RegExp(r'^\s*:?-{2,}:?\s*$').hasMatch(cell));
  }

  static List<String> _splitRow(String row) {
    var trimmed = row.trim();
    if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
    if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
    return trimmed.split('|').map((c) => c.trim()).toList();
  }

  static (String, int) _renderTable(List<String> lines, int startIndex, NibTheme theme) {
    final headerLine = lines[startIndex].trim();
    final delimLine = lines[startIndex + 1].trim();

    final rawHeaders = _splitRow(headerLine);
    final delimCells = _splitRow(delimLine);

    final columnCount = rawHeaders.length;
    final alignments = <TextAlignment>[];

    for (int col = 0; col < columnCount; col++) {
      if (col < delimCells.length) {
        final d = delimCells[col].trim();
        if (d.startsWith(':') && d.endsWith(':')) {
          alignments.add(TextAlignment.center);
        } else if (d.endsWith(':')) {
          alignments.add(TextAlignment.right);
        } else {
          alignments.add(TextAlignment.left);
        }
      } else {
        alignments.add(TextAlignment.left);
      }
    }

    final table = Table()
      ..borderStyle = BorderStyle.rounded
      ..borderType = BorderType.grid
      ..headerStyle = FontStyle.bold;

    for (int col = 0; col < columnCount; col++) {
      final headerText = _formatInline(rawHeaders[col], theme);
      table.insertColumn(
        header: headerText,
        alignment: alignments[col],
      );
    }

    int currentIndex = startIndex + 2;
    final rows = <List<String>>[];

    while (currentIndex < lines.length) {
      final line = lines[currentIndex].trim();
      if (line.isEmpty || line.startsWith('```') || !line.contains('|')) {
        break;
      }
      if (_isDelimiterRow(line)) {
        break;
      }

      final cells = _splitRow(line);
      final row = <String>[];
      for (int col = 0; col < columnCount; col++) {
        if (col < cells.length) {
          row.add(_formatInline(cells[col], theme));
        } else {
          row.add('');
        }
      }
      rows.add(row);
      currentIndex++;
    }

    if (rows.isNotEmpty) {
      table.insertRows(rows);
    }

    final buf = StringBuffer();
    buf.writeln();
    final rendered = table.render();
    for (final tLine in rendered.split('\n')) {
      if (tLine.isNotEmpty) {
        buf.writeln('  $tLine');
      }
    }

    return (buf.toString(), currentIndex);
  }
}
