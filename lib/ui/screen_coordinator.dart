import 'dart:io';
import 'dart:math';
import 'theme.dart';

/// Coordinates terminal geometry and hardware scrolling margins (DECSTBM).
///
/// Locks a pinned footer at the bottom of the screen:
/// - Input prompt area: rows `(terminalLines - footerLines + 1) .. (terminalLines - 1)`
///   Can dynamically grow to multi-line when composing or pasting, and shrinks back.
/// - Status line: row `terminalLines` (model, provider, context meter, activity, queue).
/// - Scrolling transcript: rows `1 .. (terminalLines - footerLines)`
///
/// Output written through [writeTranscript] scrolls natively within the top region,
/// never overwriting or colliding with the user's input prompt or status row.
class ScreenCoordinator {
  static ScreenCoordinator? _testInstance;
  static final ScreenCoordinator _singleton = ScreenCoordinator._();
  static ScreenCoordinator get instance => _testInstance ?? _singleton;
  static set testInstance(ScreenCoordinator? inst) => _testInstance = inst;

  ScreenCoordinator._({void Function(String text)? out})
    : _out = out ?? stdout.write;

  /// Visible constructor for unit testing.
  ScreenCoordinator.forTesting({void Function(String text)? out})
    : _out = out ?? stdout.write;

  final void Function(String text) _out;

  bool _active = false;
  bool get isActive => _active;

  int _promptLines = 1;
  int _queueLines = 0;
  List<String> _queuedItems = const [];
  // Pinned footer structure:
  // - Top blank spacer line (separates transcript/messages from input/queue)
  // - Queued items (if any)
  // - Prompt input area (_promptLines)
  // - Bottom blank spacer line (separates prompt from status bar)
  // - Status bar (1 line)
  static const int _topSpacerLines = 1;
  static const int _bottomSpacerLines = 1;
  int _footerLines = _topSpacerLines + 1 + 0 + _bottomSpacerLines + 1;

  int _transcriptRow = 1;
  int _transcriptCol = 1;

  int? _testTerminalLines;
  int? _testTerminalColumns;

  /// Sets mock dimensions for tests.
  void setTestDimensions({int? lines, int? cols}) {
    _testTerminalLines = lines;
    _testTerminalColumns = cols;
  }

  int get terminalLines {
    if (_testTerminalLines != null) return _testTerminalLines!;
    try {
      if (stdout.hasTerminal) return max(stdout.terminalLines, 10);
    } catch (_) {}
    return 24;
  }

  int get terminalColumns {
    if (_testTerminalColumns != null) return _testTerminalColumns!;
    try {
      if (stdout.hasTerminal) return max(stdout.terminalColumns, 40);
    } catch (_) {}
    return 80;
  }

  bool get isSupported =>
      _testTerminalLines != null || (stdout.hasTerminal && stdin.hasTerminal);

  int get queueLines => _queueLines;
  int get promptLines => _promptLines;
  int get footerLines => _footerLines;

  int get scrollBottom => max(1, terminalLines - _footerLines);
  int get queueStartRow => terminalLines - _footerLines + 1 + _topSpacerLines;
  int get promptStartRow => queueStartRow + _queueLines;
  int get statusRow => terminalLines;

  int get transcriptRow => _transcriptRow;
  int get transcriptCol => _transcriptCol;

  /// Activates DECSTBM scrolling margins and establishes the pinned footer.
  void activate({int initialPromptLines = 1}) {
    if (!isSupported) return;
    _active = true;
    _promptLines = max(1, initialPromptLines);
    _queueLines = 0;
    _queuedItems = const [];
    _footerLines =
        _topSpacerLines + _queueLines + _promptLines + _bottomSpacerLines + 1;

    _applyScrollRegion();

    // Position cursor at scrollBottom so initial transcript output streams
    // upward from the bottom without overwriting top rows or dumping blank lines.
    _transcriptRow = scrollBottom;
    _transcriptCol = 1;
    _out('\x1B[$scrollBottom;1H');
  }

  /// Restores normal terminal margins and releases the pinned footer.
  void deactivate() {
    if (!_active) return;
    _active = false;
    if (isSupported) {
      clearPromptArea();
      _out('\x1B[$statusRow;1H\x1B[2K');
      _out('\x1B[r'); // Reset scroll margins to full screen
      _out('\x1B[$terminalLines;1H\n'); // Move to bottom line and newline
      _out('\x1B[?25h'); // Ensure cursor is visible
    }
  }

  /// Updates geometry on window resize.
  void updateTerminalSize() {
    if (!_active || !isSupported) return;
    _applyScrollRegion();
    renderQueue();
  }

  /// Updates the queued messages displayed directly above the prompt box.
  void setQueued(List<String> items) {
    if (!_active || !isSupported) return;
    final maxQueueLines = max(0, terminalLines - _promptLines - 5);
    final clampedItems = items.take(maxQueueLines).toList();

    final oldQueueStart = queueStartRow;
    _queuedItems = clampedItems;
    _queueLines = clampedItems.length;
    _footerLines =
        _topSpacerLines + _queueLines + _promptLines + _bottomSpacerLines + 1;

    _applyScrollRegion();

    // If footer shrank, clear freed lines
    if (queueStartRow > oldQueueStart) {
      for (var r = oldQueueStart; r < queueStartRow; r++) {
        _out('\x1B[$r;1H\x1B[2K');
      }
    }

    renderQueue();
  }

  /// Renders all queued messages pinned directly above the input prompt.
  void renderQueue() {
    if (!_active || !isSupported) return;
    _out('\x1B7');
    final theme = NibTheme.current;
    final cols = terminalColumns;
    for (var i = 0; i < _queuedItems.length; i++) {
      final row = queueStartRow + i;
      final text = _queuedItems[i];
      final maxLen = max(10, cols - 16);
      final singleLine = text.replaceAll('\n', ' ').trim();
      final displayText = singleLine.length > maxLen
          ? '${singleLine.substring(0, maxLen - 3)}...'
          : singleLine;
      final line =
          '  ${theme.info.text('⏎ Queued:')} ${theme.secondary.text(displayText)}';
      _out('\x1B[$row;1H\x1B[2K$line');
    }
    _out('\x1B8');
  }

  /// Dynamically updates the number of lines required by the prompt area.
  /// Adjusts the scroll region if the footer height changed.
  void updatePromptLines(int lines) {
    if (!_active || !isSupported) return;
    final maxAllowed = max(1, terminalLines - _queueLines - 5);
    final clamped = min(max(1, lines), maxAllowed);
    if (clamped == _promptLines) return;

    final oldQueueStart = queueStartRow;
    _promptLines = clamped;
    _footerLines =
        _topSpacerLines + _queueLines + _promptLines + _bottomSpacerLines + 1;

    _applyScrollRegion();

    // If prompt area shrank, clear any rows that were previously part of the prompt
    if (queueStartRow > oldQueueStart) {
      for (var r = oldQueueStart; r < queueStartRow; r++) {
        _out('\x1B[$r;1H\x1B[2K');
      }
    }

    renderQueue();
  }

  void _applyScrollRegion() {
    _out('\x1B[1;${scrollBottom}r');
    if (_transcriptRow > scrollBottom) {
      _transcriptRow = scrollBottom;
    }
  }

  /// Writes streaming transcript output into the scrolling region without
  /// affecting the pinned footer or human cursor position.
  void writeTranscript(String text) {
    if (!_active || !isSupported) {
      _out(text);
      return;
    }

    // Save human cursor position
    _out('\x1B7');

    // Move to transcript cursor position
    _out('\x1B[$_transcriptRow;${_transcriptCol}H');

    var i = 0;
    final buffer = StringBuffer();

    void flushBuffer() {
      if (buffer.isNotEmpty) {
        _out(buffer.toString());
        buffer.clear();
      }
    }

    while (i < text.length) {
      if (text[i] == '\x1B') {
        flushBuffer();
        // ANSI escape sequence: write through to terminal without advancing col
        final start = i;
        i++;
        if (i < text.length && text[i] == '[') {
          i++;
          while (i < text.length && !RegExp(r'[a-zA-Z~]').hasMatch(text[i])) {
            i++;
          }
          if (i < text.length) i++;
        }
        _out(text.substring(start, i));
        continue;
      }

      final char = text[i];
      if (char == '\n') {
        flushBuffer();
        _out('\n');
        _out('\r');
        _transcriptRow = min(_transcriptRow + 1, scrollBottom);
        _transcriptCol = 1;
      } else if (char == '\r') {
        flushBuffer();
        _out('\r');
        _transcriptCol = 1;
      } else {
        buffer.write(char);
        _transcriptCol++;
        if (_transcriptCol > terminalColumns) {
          flushBuffer();
          _transcriptRow = min(_transcriptRow + 1, scrollBottom);
          _transcriptCol = 1;
        }
      }
      i++;
    }

    flushBuffer();

    // Restore human cursor position
    _out('\x1B8');
  }

  /// Clears the prompt area in the pinned footer.
  void clearPromptArea() {
    if (!_active || !isSupported) return;
    _out('\x1B7');
    for (var r = promptStartRow; r < statusRow; r++) {
      _out('\x1B[$r;1H\x1B[2K');
    }
    _out('\x1B8');
  }

  /// Positions the cursor at [rowOffset] and [col] inside the prompt area.
  void positionPromptCursor(int rowOffset, int col) {
    if (!_active || !isSupported) return;
    final targetRow = min(promptStartRow + rowOffset, statusRow - 1);
    final targetCol = max(1, min(col, terminalColumns));
    _out('\x1B[$targetRow;${targetCol}H');
  }

  /// Renders the status bar at the bottom-most row of the screen without
  /// moving the human's cursor.
  void renderStatus(String statusText) {
    if (!_active || !isSupported) return;
    _out('\x1B7');
    _out('\x1B[$statusRow;1H\x1B[2K$statusText');
    _out('\x1B8');
  }
}
