import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'ansi.dart';
import 'theme.dart';

/// Formatter that decorates Markdown elements with ANSI escape codes for terminal CLI display.
class MarkdownRenderer {
  /// Renders a full markdown string with terminal styling and TrueColor syntax highlighting.
  static String render(String markdown, [NibTheme? theme]) {
    final activeTheme = theme ?? NibTheme.current;
    final buffer = StringBuffer();
    final printer = StreamingMarkdownPrinter(
      theme: activeTheme,
      out: (s) => buffer.write(s),
    );
    printer.addDelta(markdown);
    printer.flush();
    return buffer.toString().trimRight();
  }

  /// Highlights inline elements like `code`, **bold**, *italic*, and [links](url).
  ///
  /// When [inTable] is true, inline code does not have extra padding spaces added,
  /// preserving column alignment and exact cell widths in table grids.
  static String formatInline(String text, NibTheme theme, {bool inTable = false}) {
    var result = text;

    // Inline code `...`
    result = result.replaceAllMapped(RegExp(r'`([^`]+)`'), (match) {
      final code = match.group(1)!;
      final pad = inTable ? '' : ' ';
      return '${theme.surface.bg}${theme.code.fg}$pad$code$pad\x1B[0m';
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
  static String highlightCodeLine(String line, String lang, NibTheme theme) {
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

  static bool isTableStart(List<String> lines, int i) {
    if (i + 1 >= lines.length) return false;
    final current = lines[i].trim();
    final next = lines[i + 1].trim();
    if (!current.contains('|') || !next.contains('|') || !next.contains('-')) {
      return false;
    }
    return isDelimiterRow(next);
  }

  static bool isDelimiterRow(String line) {
    final cells = splitRow(line);
    if (cells.isEmpty) return false;
    return cells.every((cell) => RegExp(r'^\s*:?-{2,}:?\s*$').hasMatch(cell));
  }

  static List<String> splitRow(String row) {
    var trimmed = row.trim();
    if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
    if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
    return trimmed.split('|').map((c) => c.trim()).toList();
  }

  /// Renders a full markdown table from a list of markdown lines with rounded unicode borders.
  static String renderTable(List<String> lines, [NibTheme? theme]) {
    final activeTheme = theme ?? NibTheme.current;
    if (lines.length < 2) return lines.join('\n');

    final headerLine = lines[0].trim();
    final delimLine = lines[1].trim();

    final rawHeaders = splitRow(headerLine);
    final delimCells = splitRow(delimLine);

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
      final headerText = formatInline(rawHeaders[col], activeTheme, inTable: true);
      table.insertColumn(
        header: headerText,
        alignment: alignments[col],
      );
    }

    final rows = <List<String>>[];
    for (int i = 2; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('```') || !line.contains('|')) {
        continue;
      }
      if (isDelimiterRow(line)) {
        continue;
      }

      final cells = splitRow(line);
      final row = <String>[];
      for (int col = 0; col < columnCount; col++) {
        if (col < cells.length) {
          row.add(formatInline(cells[col], activeTheme, inTable: true));
        } else {
          row.add('');
        }
      }
      rows.add(row);
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

    return buf.toString();
  }
}

/// Buffers and renders incoming streaming tokens in real time, handling line formatting,
/// code-fence boxes with syntax highlighting, and Unicode rounded tables.
class StreamingMarkdownPrinter {
  final NibTheme theme;
  final void Function(String text) _out;

  String _charBuffer = '';
  bool _inCodeBlock = false;
  String _codeBlockLang = '';
  final List<String> _pendingTableLines = [];

  StreamingMarkdownPrinter({NibTheme? theme, void Function(String text)? out})
      : theme = theme ?? NibTheme.current,
        _out = out ?? stdout.write;

  /// Adds an incoming token or text delta from the model stream.
  void addDelta(String delta) {
    _charBuffer += delta;

    while (_charBuffer.contains('\n')) {
      final newlineIndex = _charBuffer.indexOf('\n');
      final line = _charBuffer.substring(0, newlineIndex);
      _charBuffer = _charBuffer.substring(newlineIndex + 1);
      _processLine(line);
    }
  }

  void _processLine(String line) {
    // Inside a code fence, lines are code (even if they contain pipes)
    if (_inCodeBlock) {
      _emitFormattedLine(line);
      return;
    }

    final trimmed = line.trim();

    // If we have pending table lines:
    if (_pendingTableLines.isNotEmpty) {
      if (_pendingTableLines.length == 1) {
        // Line 1 was buffered. Is this line the delimiter row?
        if (MarkdownRenderer.isDelimiterRow(line)) {
          _pendingTableLines.add(line);
          return;
        } else {
          // Not a table! Flush the buffered first line as normal markdown.
          final first = _pendingTableLines.removeAt(0);
          _emitFormattedLine(first);
          // Fall through to evaluate the current line below.
        }
      } else {
        // We have header + delimiter (+ optionally some rows).
        // Is this line another row of the table?
        final isRow = trimmed.isNotEmpty &&
            trimmed.contains('|') &&
            !trimmed.startsWith('```') &&
            !MarkdownRenderer.isDelimiterRow(line);

        if (isRow) {
          _pendingTableLines.add(line);
          return;
        } else {
          // Table ended! Render and flush the table.
          _renderAndFlushPendingTable();
          // Fall through to evaluate the current line below.
        }
      }
    }

    // Check if this line could be the start of a table
    if (trimmed.isNotEmpty &&
        trimmed.contains('|') &&
        !trimmed.startsWith('```')) {
      _pendingTableLines.add(line);
      return;
    }

    // Normal line
    _emitFormattedLine(line);
  }

  void _emitFormattedLine(String line) {
    final trimmed = line.trim();

    // Code block start / end
    if (trimmed.startsWith('```')) {
      if (!_inCodeBlock) {
        _inCodeBlock = true;
        _codeBlockLang = trimmed.substring(3).trim().toLowerCase();
        final langTag = _codeBlockLang.isNotEmpty ? ' $_codeBlockLang ' : ' code ';
        _out('  ${theme.muted.text('╭─')}${theme.accent.text(langTag)}${theme.muted.text('─────────────────────────────────────────╮')}\n');
      } else {
        _inCodeBlock = false;
        _codeBlockLang = '';
        _out('  ${theme.muted.text('╰──────────────────────────────────────────────────╯')}\n');
      }
      return;
    }

    if (_inCodeBlock) {
      if (line.isEmpty) {
        _out('  ${theme.muted.text('│')}\n');
      } else {
        _out('  ${theme.muted.text('│')} ${MarkdownRenderer.highlightCodeLine(line, _codeBlockLang, theme)}\n');
      }
      return;
    }

    // Headers
    if (trimmed.startsWith('# ')) {
      final title = trimmed.substring(2);
      _out('\n  ${Ansi.boldText(theme.accent.text(title))}\n  ${theme.muted.text('━' * (title.length + 2))}\n');
      return;
    } else if (trimmed.startsWith('## ')) {
      final title = trimmed.substring(3);
      _out('\n  ${Ansi.boldText(theme.secondary.text(title))}\n  ${theme.muted.text('─' * (title.length + 2))}\n');
      return;
    } else if (trimmed.startsWith('### ')) {
      final title = trimmed.substring(4);
      _out('\n  ${Ansi.boldText(theme.info.text(title))}\n');
      return;
    }

    // Bullet lists
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      final content = trimmed.substring(2);
      _out('  ${theme.accent.text('•')} ${MarkdownRenderer.formatInline(content, theme)}\n');
      return;
    }

    // Numbered lists
    final numMatch = RegExp(r'^(\d+\.)\s+(.+)$').firstMatch(trimmed);
    if (numMatch != null) {
      final numPart = numMatch.group(1)!;
      final rest = numMatch.group(2)!;
      _out('  ${theme.accent.text(numPart)} ${MarkdownRenderer.formatInline(rest, theme)}\n');
      return;
    }

    // Blockquotes
    if (trimmed.startsWith('> ')) {
      _out('  ${theme.muted.text('│')} ${theme.muted.text(trimmed.substring(2))}\n');
      return;
    }

    // Empty line
    if (trimmed.isEmpty) {
      _out('\n');
      return;
    }

    // Regular line with inline formatting
    _out('${MarkdownRenderer.formatInline(line, theme)}\n');
  }

  void _renderAndFlushPendingTable() {
    if (_pendingTableLines.isEmpty) return;
    final tableOutput = MarkdownRenderer.renderTable(_pendingTableLines, theme);
    _out(tableOutput);
    _pendingTableLines.clear();
  }

  /// Flushes any buffered content at the end of a stream turn or before tool execution.
  void flush() {
    if (_pendingTableLines.isNotEmpty) {
      if (_pendingTableLines.length >= 2 &&
          _charBuffer.trim().isNotEmpty &&
          _charBuffer.contains('|')) {
        _pendingTableLines.add(_charBuffer);
        _charBuffer = '';
      }

      if (_pendingTableLines.length >= 2 &&
          MarkdownRenderer.isDelimiterRow(_pendingTableLines[1])) {
        _renderAndFlushPendingTable();
      } else {
        for (final line in _pendingTableLines) {
          _emitFormattedLine(line);
        }
        _pendingTableLines.clear();
      }
    }

    if (_charBuffer.isNotEmpty) {
      final text = _charBuffer;
      _charBuffer = '';
      if (_inCodeBlock) {
        _out('  ${theme.muted.text('│')} ${MarkdownRenderer.highlightCodeLine(text, _codeBlockLang, theme)}\n');
      } else {
        _out(MarkdownRenderer.formatInline(text, theme));
      }
    }

    if (_inCodeBlock) {
      _out('  ${theme.muted.text('╰──────────────────────────────────────────────────╯')}\n');
      _inCodeBlock = false;
      _codeBlockLang = '';
    }
  }
}
