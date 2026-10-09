import 'dart:io';
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:dart_console/dart_console.dart';
import 'package:val_highlight/languages/all.dart';
import 'package:val_highlight/val_highlight.dart';
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

  /// Highlights inline elements like `code`, **bold**, *italic*, ~~strikethrough~~, and [links](url).
  static String formatInline(
    String text,
    NibTheme theme, {
    bool inTable = false,
  }) {
    // 1. Preserve escaped markdown characters like \* \# \` \[ \]
    final escapes = <String, String>{};
    int escapeCounter = 0;
    var result = text.replaceAllMapped(RegExp(r'\\([*#_`~\[\]\(\)\\])'), (m) {
      final key = '\uE000${escapeCounter++}\uE001';
      escapes[key] = m.group(1)!;
      return key;
    });

    // 2. Inline code `...`
    result = result.replaceAllMapped(RegExp(r'`([^`]+)`'), (match) {
      final code = match.group(1)!;
      return '${theme.surface.bg}${theme.code.fg}$code\x1B[0m';
    });

    // 3. Strikethrough ~~...~~
    result = result.replaceAllMapped(RegExp(r'~~([^~]+)~~'), (match) {
      final struck = match.group(1)!;
      return '\x1B[9m$struck\x1B[29m';
    });

    // 4. Bold + Italic ***...*** or ___...___
    result = result.replaceAllMapped(
      RegExp(r'\*\*\*([^*]+)\*\*\*|___([^_]+)___'),
      (match) {
        final bi = (match.group(1) ?? match.group(2))!;
        return Ansi.boldText('\x1B[3m$bi\x1B[23m');
      },
    );

    // 5. Bold **...** or __...__
    result = result.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*|__([^_]+)__'), (
      match,
    ) {
      final bold = (match.group(1) ?? match.group(2))!;
      return Ansi.boldText(bold);
    });

    // 6. Italic *...* or _..._
    result = result.replaceAllMapped(
      RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)|(?<!_)_([^_]+)_(?!_)'),
      (match) {
        final it = (match.group(1) ?? match.group(2))!;
        return '\x1B[3m$it\x1B[23m';
      },
    );

    // 7. Links [text](url) (supports optional "hover title")
    result = result.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)'),
      (match) {
        final linkText = match.group(1)!;
        final url = match.group(2)!;
        return '${theme.accent.text(linkText)} ${theme.muted.text('($url)')}';
      },
    );

    // 8. Restore escaped characters
    escapes.forEach((key, val) {
      result = result.replaceAll(key, val);
    });

    return result;
  }

  static final Highlighter _highlighter = Highlighter(
    registry: allLanguagesRegistry(),
  );

  /// Multi-language syntax tinting using val_highlight across 55+ languages.
  static String highlightCodeLine(String line, String lang, NibTheme theme) {
    if (line.isEmpty) return line;

    try {
      final cleanLang = lang.trim().toLowerCase();
      final grammar =
          _highlighter.registry?.lookup(cleanLang) ??
          _highlighter.registry?.resolve(cleanLang);

      if (grammar != null) {
        final result = _highlighter.highlight(line, language: grammar);
        final buffer = StringBuffer();
        for (final token in result.tokens) {
          buffer.write(_styleToken(token, theme));
        }
        return buffer.toString();
      }
    } catch (_) {}

    return line;
  }

  static String _styleToken(HighlightToken token, NibTheme theme) {
    final scope = token.scope;
    if (scope == null) return token.text;

    if (scope.startsWith('comment')) {
      return theme.muted.text(token.text);
    } else if (scope.startsWith('string') ||
        scope.startsWith('interpolation')) {
      return theme.diffAdd.text(token.text);
    } else if (scope.startsWith('keyword') || scope.startsWith('operator')) {
      return theme.secondary.text(token.text);
    } else if (scope.startsWith('number') || scope.startsWith('literal')) {
      return theme.code.text(token.text);
    } else if (scope.startsWith('type') || scope.startsWith('function')) {
      return theme.accent.text(token.text);
    } else if (scope.startsWith('variable') || scope.startsWith('property')) {
      return theme.primary.text(token.text);
    } else if (scope.startsWith('tag') || scope.startsWith('meta')) {
      return theme.warning.text(token.text);
    }

    return token.text;
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
    if (trimmed.endsWith('|')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed.split('|').map((c) => c.trim()).toList();
  }

  /// Renders a full markdown table from a list of markdown lines with rounded unicode borders,
  /// automatically flexing and wrapping cell widths to fit within [maxTableWidth] or the terminal width.
  static String renderTable(
    List<String> lines, [
    NibTheme? theme,
    int? maxTableWidth,
  ]) {
    final activeTheme = theme ?? NibTheme.current;
    if (lines.length < 2) return lines.join('\n');

    final headerLine = lines[0].trim();
    final delimLine = lines[1].trim();

    final rawHeaders = splitRow(headerLine);
    final delimCells = splitRow(delimLine);

    final columnCount = rawHeaders.length;
    if (columnCount == 0) return lines.join('\n');

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

    final formattedHeaders = <String>[];
    for (int col = 0; col < columnCount; col++) {
      formattedHeaders.add(
        formatInline(rawHeaders[col], activeTheme, inTable: true),
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

    // Measure natural width of each column (longest cell display width)
    final naturalWidths = List<int>.filled(columnCount, 0);
    for (int col = 0; col < columnCount; col++) {
      int maxCol = formattedHeaders[col].stripEscapeCharacters().displayWidth;
      for (final row in rows) {
        if (col < row.length) {
          final w = row[col].stripEscapeCharacters().displayWidth;
          if (w > maxCol) maxCol = w;
        }
      }
      naturalWidths[col] = max(maxCol, 1);
    }

    // Determine available width for table content.
    // dart_console Table grid frame overhead: (columns + 1) borders + (2 * columns) padding spaces = 3 * columns + 1.
    // Plus 2 spaces indentation when writing out: total framing overhead = 3 * columns + 3.
    int termWidth = 80;
    try {
      if (stdout.hasTerminal) {
        termWidth = stdout.terminalColumns;
      }
    } catch (_) {}

    // Sane upper ceiling for prose readability per #24
    final maxAllowedWidth = maxTableWidth ?? min(termWidth, 120);
    final frameOverhead = 3 * columnCount + 3;
    final availableContentWidth = max(
      columnCount * 4,
      maxAllowedWidth - frameOverhead,
    );

    final totalNatural = naturalWidths.fold<int>(0, (a, b) => a + b);
    final columnWidths = List<int>.from(naturalWidths);

    if (totalNatural > availableContentWidth) {
      // Flex allocation pass:
      // Lock columns that already fit within their fair share, and proportionally shrink wider columns.
      var remainingWidth = availableContentWidth;
      var remainingCols = columnCount;
      final needsFlex = List<bool>.filled(columnCount, true);

      bool changed = true;
      while (changed && remainingCols > 0) {
        changed = false;
        final fairShare = max(1, remainingWidth ~/ remainingCols);
        for (int col = 0; col < columnCount; col++) {
          if (needsFlex[col] && naturalWidths[col] <= fairShare) {
            needsFlex[col] = false;
            columnWidths[col] = naturalWidths[col];
            remainingWidth -= naturalWidths[col];
            remainingCols--;
            changed = true;
          }
        }
      }

      if (remainingCols > 0 && remainingWidth > 0) {
        final flexNaturalSum = [
          for (int c = 0; c < columnCount; c++)
            if (needsFlex[c]) naturalWidths[c],
        ].fold<int>(0, (a, b) => a + b);

        final minColWidth = max(4, remainingWidth ~/ (remainingCols * 2));
        for (int col = 0; col < columnCount; col++) {
          if (needsFlex[col]) {
            final share = (naturalWidths[col] / flexNaturalSum * remainingWidth)
                .floor();
            columnWidths[col] = max(minColWidth, share);
          }
        }

        var currentSum = columnWidths.fold<int>(0, (a, b) => a + b);

        // Reconcile any rounding difference so total matches availableContentWidth exactly
        while (currentSum > availableContentWidth) {
          int largestCol = -1;
          int largestVal = minColWidth;
          for (int c = 0; c < columnCount; c++) {
            if (needsFlex[c] && columnWidths[c] > largestVal) {
              largestVal = columnWidths[c];
              largestCol = c;
            }
          }
          if (largestCol == -1) break;
          columnWidths[largestCol]--;
          currentSum--;
        }
        while (currentSum < availableContentWidth) {
          int deficitCol = -1;
          int maxDeficit = -1;
          for (int c = 0; c < columnCount; c++) {
            if (needsFlex[c]) {
              final deficit = naturalWidths[c] - columnWidths[c];
              if (deficit > maxDeficit) {
                maxDeficit = deficit;
                deficitCol = c;
              }
            }
          }
          if (deficitCol == -1) break;
          columnWidths[deficitCol]++;
          currentSum++;
        }
      }
    }
    final topBorder =
        '  ╭${[for (int i = 0; i < columnCount; i++) '─' * (columnWidths[i] + 2)].join('┬')}╮';

    final rowSeparator =
        '  ├${[for (int i = 0; i < columnCount; i++) '─' * (columnWidths[i] + 2)].join('┼')}┤';

    final bottomBorder =
        '  ╰${[for (int i = 0; i < columnCount; i++) '─' * (columnWidths[i] + 2)].join('┴')}╯';

    final buf = StringBuffer();
    buf.writeln();
    buf.writeln(topBorder);

    void renderRow(List<String> rowCells, {required bool isHeader}) {
      final wrappedCells = <List<String>>[];
      for (int c = 0; c < columnCount; c++) {
        final cellText = c < rowCells.length ? rowCells[c] : '';
        wrappedCells.add(_wrapCellText(cellText, columnWidths[c]));
      }

      final rowHeight = wrappedCells.map((c) => c.length).fold<int>(1, max);

      for (int line = 0; line < rowHeight; line++) {
        buf.write('  │');
        for (int c = 0; c < columnCount; c++) {
          final cellLine = line < wrappedCells[c].length
              ? wrappedCells[c][line]
              : '';
          final aligned = _alignCell(cellLine, columnWidths[c], alignments[c]);
          if (isHeader) {
            buf.write(' \x1B[1m$aligned\x1B[0m │');
          } else {
            buf.write(' $aligned\x1B[0m │');
          }
        }
        buf.writeln();
      }
    }

    renderRow(formattedHeaders, isHeader: true);
    buf.writeln(rowSeparator);

    for (int r = 0; r < rows.length; r++) {
      renderRow(rows[r], isHeader: false);
      if (r < rows.length - 1) {
        buf.writeln(rowSeparator);
      }
    }

    buf.writeln(bottomBorder);

    return buf.toString();
  }

  static String _alignCell(String text, int width, TextAlignment alignment) {
    final dw = text.stripEscapeCharacters().displayWidth;
    final pad = max(0, width - dw);
    switch (alignment) {
      case TextAlignment.right:
        return (' ' * pad) + text;
      case TextAlignment.center:
        final left = pad ~/ 2;
        final right = pad - left;
        return (' ' * left) + text + (' ' * right);
      case TextAlignment.left:
        return text + (' ' * pad);
    }
  }

  static List<String> _wrapCellText(String text, int width) {
    if (text.isEmpty) return [''];
    final words = text.split(' ');
    final lines = <String>[];
    var currentLine = StringBuffer();
    var currentWidth = 0;

    for (final word in words) {
      if (word.isEmpty) continue;
      final wordWidth = word.stripEscapeCharacters().displayWidth;

      if (currentWidth == 0) {
        if (wordWidth <= width) {
          currentLine.write(word);
          currentWidth = wordWidth;
        } else {
          final chunks = _breakWord(word, width);
          for (int i = 0; i < chunks.length - 1; i++) {
            lines.add(chunks[i]);
          }
          currentLine.write(chunks.last);
          currentWidth = chunks.last.stripEscapeCharacters().displayWidth;
        }
      } else {
        if (currentWidth + 1 + wordWidth <= width) {
          currentLine.write(' $word');
          currentWidth += 1 + wordWidth;
        } else {
          lines.add(currentLine.toString());
          currentLine = StringBuffer();
          currentWidth = 0;

          if (wordWidth <= width) {
            currentLine.write(word);
            currentWidth = wordWidth;
          } else {
            final chunks = _breakWord(word, width);
            for (int i = 0; i < chunks.length - 1; i++) {
              lines.add(chunks[i]);
            }
            currentLine.write(chunks.last);
            currentWidth = chunks.last.stripEscapeCharacters().displayWidth;
          }
        }
      }
    }

    if (currentLine.isNotEmpty || lines.isEmpty) {
      lines.add(currentLine.toString());
    }
    return lines;
  }

  static List<String> _breakWord(String word, int width) {
    if (width <= 0) return [word];
    final ansiRegex = RegExp(r'\x1B\[[0-9;]*[a-zA-Z]');
    final tokens = <String>[];
    var lastEnd = 0;
    for (final match in ansiRegex.allMatches(word)) {
      if (match.start > lastEnd) {
        tokens.add(word.substring(lastEnd, match.start));
      }
      tokens.add(match.group(0)!);
      lastEnd = match.end;
    }
    if (lastEnd < word.length) {
      tokens.add(word.substring(lastEnd));
    }

    final chunks = <String>[];
    var chunk = StringBuffer();
    var currentWidth = 0;

    for (final token in tokens) {
      if (token.startsWith('\x1B')) {
        chunk.write(token);
      } else {
        for (final char in token.characters) {
          final cw = char.displayWidth;
          if (currentWidth + cw > width && currentWidth > 0) {
            chunks.add(chunk.toString());
            chunk = StringBuffer();
            currentWidth = 0;
          }
          chunk.write(char);
          currentWidth += cw;
        }
      }
    }
    if (chunk.isNotEmpty) {
      chunks.add(chunk.toString());
    }
    return chunks.isEmpty ? [word] : chunks;
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
        final isRow =
            trimmed.isNotEmpty &&
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
        final langTag = _codeBlockLang.isNotEmpty ? _codeBlockLang : 'code';
        final topUsed = 9 + langTag.length;
        final ruleLen = max(2, 40 - topUsed);
        _out(
          '  ${theme.muted.text('╭──')} ${theme.accent.text(langTag)} ${theme.muted.text('─' * ruleLen)}\n',
        );
      } else {
        _inCodeBlock = false;
        _codeBlockLang = '';
        _out('  ${theme.muted.text('╰──${'─' * 35}')}\n');
      }
      return;
    }

    if (_inCodeBlock) {
      if (line.isEmpty) {
        _out('\n');
      } else {
        _out(
          '    ${MarkdownRenderer.highlightCodeLine(line, _codeBlockLang, theme)}\n',
        );
      }
      return;
    }

    // Horizontal rule
    if (trimmed == '---' ||
        trimmed == '***' ||
        trimmed == '___' ||
        RegExp(r'^-{3,}$').hasMatch(trimmed)) {
      _out('\n  ${theme.muted.text('─' * 38)}\n');
      return;
    }

    // Headers
    if (trimmed.startsWith('# ')) {
      final title = trimmed.substring(2);
      _out(
        '\n  ${Ansi.boldText(theme.accent.text(title))}\n  ${theme.muted.text('━' * (title.length + 2))}\n',
      );
      return;
    } else if (trimmed.startsWith('## ')) {
      final title = trimmed.substring(3);
      _out(
        '\n  ${Ansi.boldText(theme.secondary.text(title))}\n  ${theme.muted.text('─' * (title.length + 2))}\n',
      );
      return;
    } else if (trimmed.startsWith('### ')) {
      final title = trimmed.substring(4);
      _out('\n  ${Ansi.boldText(theme.info.text(title))}\n');
      return;
    }

    // Blockquotes
    if (trimmed.startsWith('> ')) {
      final quoteContent = MarkdownRenderer.formatInline(
        trimmed.substring(2),
        theme,
      );
      _out('  ${theme.muted.text('│')} $quoteContent\n');
      return;
    }

    // Preserve hierarchical indentation for nested lists
    final leadingSpaces = line.length - line.trimLeft().length;
    final indent = ' ' * (2 + leadingSpaces);
    final trimmedLeft = line.trimLeft();

    // Task lists: - [x] or - [ ] or * [x] or * [ ]
    final taskMatch = RegExp(
      r'^[-*]\s+\[([ xX])\]\s+(.+)$',
    ).firstMatch(trimmedLeft);
    if (taskMatch != null) {
      final isDone = taskMatch.group(1)!.toLowerCase() == 'x';
      final taskContent = MarkdownRenderer.formatInline(
        taskMatch.group(2)!,
        theme,
      );
      final checkIcon = isDone
          ? theme.success.text('✔')
          : theme.muted.text('☐');
      _out('$indent$checkIcon $taskContent\n');
      return;
    }

    // Bullet lists: - item or * item
    if (trimmedLeft.startsWith('- ') || trimmedLeft.startsWith('* ')) {
      final content = trimmedLeft.substring(2);
      _out(
        '$indent${theme.accent.text('•')} ${MarkdownRenderer.formatInline(content, theme)}\n',
      );
      return;
    }

    // Numbered lists: 1. item
    final numMatch = RegExp(r'^(\d+\.)\s+(.+)$').firstMatch(trimmedLeft);
    if (numMatch != null) {
      final numPart = numMatch.group(1)!;
      final rest = numMatch.group(2)!;
      _out(
        '$indent${theme.accent.text(numPart)} ${MarkdownRenderer.formatInline(rest, theme)}\n',
      );
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
        _out(
          '  ${theme.muted.text('│')} ${MarkdownRenderer.highlightCodeLine(text, _codeBlockLang, theme)}\n',
        );
      } else {
        _out(MarkdownRenderer.formatInline(text, theme));
      }
    }

    if (_inCodeBlock) {
      _out(
        '  ${theme.muted.text('╰──────────────────────────────────────────────────╯')}\n',
      );
      _inCodeBlock = false;
      _codeBlockLang = '';
    }
  }
}
