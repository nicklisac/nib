import 'dart:io';
import 'dart:math';
import 'package:dart_console/dart_console.dart';
import 'theme.dart';

/// Coordinates terminal geometry and hardware scrolling margins (DECSTBM).
///
/// The screen is three pinned bands with the transcript scrolling between them:
/// - Pinned header: rows `1 .. headerLines` — session facts that change only when
///   you switch provider, model, folder, or theme. Empty when there is no room.
/// - Scrolling transcript: rows `(headerLines + 1) .. scrollBottom`
/// - Pinned footer: queue rows, the prompt area, and the live telemetry row at
///   `terminalLines`. The prompt area grows to multi-line while composing and
///   shrinks back, which moves [scrollBottom] and nothing else.
///
/// Output written through [writeTranscript] scrolls natively within the middle
/// region, never overwriting or colliding with the header, the input prompt, or
/// the status row.
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
  List<String> _headerLines = const [];

  /// The unsplit header facts, kept so a resize can re-fit them to a new width
  /// instead of re-wrapping already-joined rows.
  List<String>? _headerSegments;
  // Pinned footer structure:
  // - Top blank spacer line (separates transcript/messages from input/queue)
  // - Queued items (if any)
  // - Prompt input area (_promptLines)
  // - Bottom blank spacer line (separates prompt from status bar)
  // - Status bar (1 line)
  static const int _topSpacerLines = 1;
  static const int _bottomSpacerLines = 1;
  int _footerLines = _topSpacerLines + 1 + 0 + _bottomSpacerLines + 1;

  /// Transcript rows the header must never eat.
  ///
  /// The header is the least essential band on the screen: provider, model, and
  /// workspace also appear in the startup banner and in `/config`, so losing it
  /// costs a human nothing they cannot recover with a keystroke. The footer losing
  /// a row instead would eat the prompt or the telemetry, and the transcript
  /// losing one would eat your place. So the header gives up its rows first.
  static const int _minTranscriptLines = 6;

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

  /// Rows the pinned header occupies at the top of the screen: `0`, `1`, or `2`.
  ///
  /// One row when the facts fit the terminal width, two when they do not, and zero
  /// when the terminal is too short to spare the row. A model name is never
  /// truncated away to make one row work — dropping the fact a human acts on is
  /// worse than spending a row on it (feel doctrine rule 6).
  int get headerLines => _headerLines.length;

  /// The header's content, in screen order. Computed without touching the
  /// terminal so the fit decision is testable rather than eyeballed.
  List<String> get headerContent => _headerLines;

  /// Lays the header out across as few rows as fit, splitting at separators rather
  /// than mid-word, and repaints it. Returns whether the header has any rows:
  /// false means the terminal could not spare them, and the caller should print
  /// the dock instead so the facts are still on screen somewhere.
  bool setHeader(List<String> segments, {required int width}) {
    final oldHeaderLines = _headerLines.length;
    _layoutHeader(segments, width: width);
    if (_active && isSupported) {
      // Paint before moving the region so a row that just stopped being a header
      // row is cleared rather than left to the transcript with stale text on it.
      _paintHeader(replacing: oldHeaderLines);
      _applyScrollRegion();
    }
    return _headerLines.isNotEmpty;
  }

  /// Repaints the pinned header rows in place without moving the human's cursor.
  void renderHeader() {
    if (!_active || !isSupported) return;
    _paintHeader(replacing: headerLines);
  }

  /// Writes rows `1 .. headerLines` and erases any row between them and
  /// [replacing], so a header that collapsed from two rows to one leaves no
  /// orphaned text on row 2.
  void _paintHeader({required int replacing}) {
    _out('\x1B7');
    for (var r = 1; r <= headerLines; r++) {
      _out('\x1B[$r;1H\x1B[2K${_headerLines[r - 1]}');
    }
    for (var r = headerLines + 1; r <= replacing; r++) {
      _out('\x1B[$r;1H\x1B[2K');
    }
    _out('\x1B8');
  }

  /// Decides how many rows the header needs, or zero when the terminal cannot
  /// spare them — the signal for the caller to print the dock instead.
  void _layoutHeader(List<String> segments, {required int width}) {
    _headerSegments = segments;
    final taken = _footerLines + _minTranscriptLines;
    final available = terminalLines - taken;
    if (available < 1 || segments.isEmpty) {
      _headerLines = const [];
      return;
    }
    final packed = _packSegments(segments, width, maxRows: min(2, available));
    // A fact still too wide for every row it can be given would wrap onto the
    // first transcript row, which is a row this header does not own (feel
    // doctrine rule 1). Yield instead: the caller prints the dock, which is
    // allowed to wrap because it scrolls.
    if (packed.any((row) => _plainLength(row) > width)) {
      _headerLines = const [];
      return;
    }
    _headerLines = packed;
  }

  /// Packs header facts onto at most [maxRows] rows, filling row 1 with as many
  /// facts as fit and continuing on row 2. Facts are never dropped or ellipsised:
  /// a fact too long for one row is what a two-row header exists to avoid.
  static List<String> _packSegments(
    List<String> segments,
    int width, {
    required int maxRows,
  }) {
    String join(List<String> parts) => parts.join(' · ');
    if (_plainLength(join(segments)) <= width) return [join(segments)];
    if (maxRows < 2) return [join(segments)];

    // Stop at the last prefix that still fits row 1. A first fact wider than the
    // terminal leaves `count` at 0, and gets the whole run on row 1 anyway rather
    // than vanishing.
    var count = 1;
    for (var i = 1; i < segments.length; i++) {
      if (_plainLength(join(segments.sublist(0, i + 1))) > width) break;
      count = i + 1;
    }
    return [
      join(segments.take(count).toList()),
      join(segments.skip(count).toList()),
    ];
  }

  /// Width of a styled string with its ANSI escapes and zero-width marks removed.
  static int _plainLength(String styled) =>
      styled.stripEscapeCharacters().displayWidth;

  int get scrollTop => headerLines + 1;
  int get scrollBottom => max(scrollTop, terminalLines - _footerLines);
  int get queueStartRow => terminalLines - _footerLines + 1 + _topSpacerLines;
  int get promptStartRow => queueStartRow + _queueLines;
  int get statusRow => terminalLines;

  int get transcriptRow => _transcriptRow;
  int get transcriptCol => _transcriptCol;

  /// Activates DECSTBM scrolling margins and establishes the pinned footer.
  ///
  /// [header] is the static session facts to pin at the top. It is laid out only
  /// if there is room for it; the return value says whether it landed, so the
  /// caller can fall back to printing the dock rather than losing the facts.
  bool activate({int initialPromptLines = 1, List<String> header = const []}) {
    if (!isSupported) return false;
    _active = true;
    _promptLines = max(1, initialPromptLines);
    _queueLines = 0;
    _queuedItems = const [];
    _footerLines =
        _topSpacerLines + _queueLines + _promptLines + _bottomSpacerLines + 1;

    _layoutHeader(header, width: terminalColumns);
    _applyScrollRegion();
    if (_headerLines.isNotEmpty) _paintHeader(replacing: _headerLines.length);

    // Position cursor at scrollBottom so initial transcript output streams
    // upward from the bottom without overwriting top rows or dumping blank lines.
    _transcriptRow = scrollBottom;
    _transcriptCol = 1;
    _out('\x1B[$scrollBottom;1H');
    return _headerLines.isNotEmpty;
  }

  /// Restores normal terminal margins and releases the pinned footer.
  void deactivate() {
    if (!_active) return;
    _active = false;
    if (isSupported) {
      clearPromptArea();
      _out('\x1B[$statusRow;1H\x1B[2K');
      if (headerLines > 0) {
        _out('\x1B[1;1H\x1B[2K');
        if (headerLines > 1) _out('\x1B[2;1H\x1B[2K');
      }
      _out('\x1B[r'); // Reset scroll margins to full screen
      _out('\x1B[$terminalLines;1H\n'); // Move to bottom line and newline
      _out('\x1B[?25h'); // Ensure cursor is visible
    }
  }

  /// Updates geometry on window resize, re-fitting the header to the new width.
  void updateTerminalSize() {
    if (!_active || !isSupported) return;
    final oldHeaderLines = _headerLines.length;
    if (_headerSegments != null) {
      _layoutHeader(_headerSegments!, width: terminalColumns);
      // Repaint before the region moves: row 2 may have just become a header row,
      // or just stopped being one.
      _paintHeader(replacing: oldHeaderLines);
    }
    _applyScrollRegion();
    renderQueue();
  }

  /// Updates the queued messages displayed directly above the prompt box.
  void setQueued(List<String> items) {
    if (!_active || !isSupported) return;

    final oldQueueStart = queueStartRow;
    _queuedItems = items;
    _queueLines = items.length;
    _recomputeFooter();

    // Queue rows come out of the header before they come out of the transcript.
    _refitHeader();
    final maxQueueLines = max(
      0,
      terminalLines - _promptLines - headerLines - 5,
    );
    if (_queueLines > maxQueueLines) {
      _queuedItems = items.take(maxQueueLines).toList();
      _queueLines = _queuedItems.length;
      _recomputeFooter();
    }

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
  /// Re-fits the header after the footer changed size, so the header gives up its
  /// rows before the transcript loses any.
  ///
  /// Without this the promise in [headerLines] only holds at activation: a prompt
  /// growing to three lines on a 12-row terminal would push the transcript under
  /// its floor while a header row sat unused above it.
  void _refitHeader() {
    if (_headerSegments == null) return;
    final old = _headerLines.length;
    _layoutHeader(_headerSegments!, width: terminalColumns);
    if (_headerLines.length != old && _active && isSupported) {
      _paintHeader(replacing: old);
    }
  }

  void updatePromptLines(int lines) {
    if (!_active || !isSupported) return;

    // Settle the footer first, then let the header yield rows to it, then clamp
    // against whatever room is left. Order matters: clamping before the refit
    // would count a header row that is about to be given up.
    final wanted = max(1, lines);
    final probe = min(
      wanted,
      max(1, terminalLines - _queueLines - headerLines - 5),
    );
    if (probe == _promptLines) return;

    final oldQueueStart = queueStartRow;
    _promptLines = wanted;
    _recomputeFooter();
    _refitHeader();

    final maxAllowed = max(1, terminalLines - _queueLines - headerLines - 5);
    if (_promptLines > maxAllowed) {
      _promptLines = maxAllowed;
      _recomputeFooter();
    }

    _applyScrollRegion();

    // If prompt area shrank, clear any rows that were previously part of the prompt
    if (queueStartRow > oldQueueStart) {
      for (var r = oldQueueStart; r < queueStartRow; r++) {
        _out('\x1B[$r;1H\x1B[2K');
      }
    }

    renderQueue();
  }

  void _recomputeFooter() {
    _footerLines =
        _topSpacerLines + _queueLines + _promptLines + _bottomSpacerLines + 1;
  }

  void _applyScrollRegion() {
    // DECSTBM homes the cursor to (1,1) as a side effect (DECSTBM moves the
    // cursor to column 1, line 1 of the page). Row 1 is now the pinned header and
    // outside the region, so a newline emitted there would scroll it off screen.
    // Saving and restoring around the set keeps the cursor where it was.
    _out('\x1B7\x1B[$scrollTop;${scrollBottom}r\x1B8');
    if (_transcriptRow < scrollTop) {
      _transcriptRow = scrollTop;
    }
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
          _out('\n');
          _out('\r');
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
