import 'dart:io';
import 'dart:math';
import 'package:dart_console/dart_console.dart';
import 'theme.dart';
import 'transcript_writer.dart';

/// Coordinates terminal geometry and hardware scrolling margins (DECSTBM).
///
/// The scroll region starts at row 1 on purpose: emulators push lines into
/// scrollback only when the region's top margin is the screen's top row, so a
/// pinned *top* band would silently cost the human wheel scrollback through
/// the session. Chrome therefore lives at the bottom, where pinning it costs
/// nothing:
/// - Scrolling transcript: rows `1 .. scrollBottom`
/// - Pinned footer: queue rows, the prompt area, the inverted facts band at
///   [bandRow] (provider, model, workspace, compact-at), and the live
///   telemetry row at `terminalLines`. The prompt area grows to multi-line
///   while composing and shrinks back, which moves [scrollBottom] and
///   nothing else.
///
/// Output written through [writeTranscript] scrolls natively within the region
/// and into scrollback above it, never overwriting or colliding with the
/// prompt, the facts band, or the status row. It is also the
/// [TranscriptWriter] slash commands and the session picker write through
/// while this coordinator owns the screen.
class ScreenCoordinator implements TranscriptWriter {
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
  List<String> _bandLines = const [];

  /// The unsplit facts, kept so a resize can re-fit them to a new width
  /// instead of re-wrapping already-joined rows.
  List<String>? _bandSegments;
  // Pinned footer structure, bottom-up:
  // - Facts band (0, 1, or 2 lines; owns the last row of the screen)
  // - Status bar (1 line)
  // - Blank spacer (separates prompt from status)
  // - Prompt input area (_promptLines)
  // - Queued items (if any)
  // - Blank spacer (separates transcript from queue/prompt)
  static const int _topSpacerLines = 1;
  static const int _bandSpacerLines = 1;
  int _footerLines = _topSpacerLines + 1 + 0 + _bandSpacerLines + 1;

  /// Transcript rows the facts band must never eat.
  ///
  /// The band is the least essential pinned thing on the screen: provider,
  /// model, and workspace also appear in the startup banner and in `/config`,
  /// so losing it costs a human nothing they cannot recover with a keystroke.
  /// The rest of the footer losing a row would eat the prompt or the
  /// telemetry, and the transcript losing one would eat your place. So the
  /// band gives up its rows first, and the caller prints the scrolling dock
  /// in its place.
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

  /// Rows the pinned facts band occupies at the bottom of the screen: `0`, `1`,
  /// or `2`.
  ///
  /// One row when the facts fit the terminal width, two when they do not, and
  /// zero when the terminal cannot spare the row. A model name is never
  /// truncated away to make one row work — dropping the fact a human acts on
  /// is worse than spending a row on it (feel doctrine rule 6).
  int get bandLines => _bandLines.length;

  /// The band's content, in screen order. Computed without touching the
  /// terminal so the fit decision is testable rather than eyeballed.
  List<String> get bandContent => _bandLines;

  /// Lays the facts out across as few rows as the footer budget allows, and
  /// repaints. Returns whether the band has any rows: false means the terminal
  /// could not spare them, and the caller should print the dock instead so the
  /// facts are still on screen somewhere.
  bool setBand(List<String> segments, {required int width}) {
    final old = _bandLines.length;
    _layoutBand(segments, width: width);
    if (_active && isSupported) {
      _recomputeFooter();
      // Repaint before moving the region so a row that just stopped being a
      // band row is cleared rather than left with stale text on it.
      _paintBand(replacing: old);
      _applyScrollRegion();
    }
    return _bandLines.isNotEmpty;
  }

  /// Repaints the pinned band rows in place without moving the human's cursor.
  void renderBand() {
    if (!_active || !isSupported) return;
    _paintBand(replacing: _bandLines.length);
  }

  /// Writes the band rows at the bottom of the screen and erases any row the
  /// band just gave up, so a band that collapsed from two rows to one leaves
  /// no orphaned text.
  ///
  /// The band carries no background of its own: segments arrive themed and the
  /// rows erase plain. Rows being given up are erased with no attribute at
  /// all, returning them to whatever band or footer comes next.
  void _paintBand({required int replacing}) {
    _out('\x1B7');
    // The band is anchored to the last screen row, so rows it gives up sit
    // above its new start: a band that shrank from two rows to one leaves its
    // old top row to erase.
    final oldStart = terminalLines - replacing + 1;
    for (var r = oldStart; r < bandStartRow; r++) {
      _out('\x1B[$r;1H\x1B[0m\x1B[2K');
    }
    for (var i = 0; i < _bandLines.length; i++) {
      final r = bandStartRow + i;
      _out('\x1B[$r;1H\x1B[2K${_bandLines[i]}');
    }
    _out('\x1B8');
  }

  /// Decides how many rows the band needs, or zero when the footer cannot
  /// spare them — the signal for the caller to print the dock instead.
  ///
  /// Budget: rows left after the rest of the footer and the transcript floor.
  /// The band spacer only exists while the band does; when the band yields, so
  /// does the spacer, and the prompt sits one row closer to the status row.
  void _layoutBand(List<String> segments, {required int width}) {
    _bandSegments = segments;
    final rest =
        _topSpacerLines + _queueLines + _promptLines + _bandSpacerLines + 1;
    final available = terminalLines - rest - _minTranscriptLines;
    if (available < 1 || segments.isEmpty) {
      _bandLines = const [];
      return;
    }
    final packed = _packSegments(segments, width, maxRows: min(2, available));
    // A fact still too wide for every row it can be given would wrap, and a
    // wrapped pinned row smears into rows the band does not own. Yield
    // instead: the caller prints the dock, which is allowed to wrap because
    // it scrolls.
    if (packed.any((row) => _plainLength(row) > width)) {
      _bandLines = const [];
      return;
    }
    _bandLines = packed;
  }

  /// Packs band facts onto at most [maxRows] rows, filling the first row with as
  /// many facts as fit and continuing on the next. Facts are never dropped or
  /// ellipsised: a fact too long for one row is what a two-row band exists to
  /// avoid.
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

  /// Row 1, always. The region top must be the screen top or emulators stop
  /// pushing scrolled-off lines into scrollback: a pinned top band would cost
  /// the human wheel scrollback through the whole session.
  int get scrollTop => 1;
  int get scrollBottom => max(scrollTop, terminalLines - _footerLines);
  int get queueStartRow => terminalLines - _footerLines + 1 + _topSpacerLines;
  int get promptStartRow => queueStartRow + _queueLines;

  /// The live telemetry row, sitting directly above the facts band. Equals
  /// [terminalLines] when the band has no rows.
  int get statusRow => terminalLines - _bandLines.length;

  /// First row of the facts band, which owns the bottom of the screen.
  /// One past the last row when the band has no rows.
  int get bandStartRow => statusRow + 1;

  /// One past the last row the prompt area and its spacer own. Prompt-side
  /// clearing stops here; everything below belongs to the status row or the
  /// band (feel doctrine rule 1).
  int get promptAreaEnd => statusRow;

  /// Last row the prompt input itself can occupy.
  int get _promptLastRow => statusRow - _bandSpacerLines - 1;

  /// Prompt rows the footer can hold with the band yielded entirely. The band
  /// gives up its rows before the transcript floor or the rest of the footer
  /// loses any.
  int get _maxPromptLines => max(
    1,
    terminalLines -
        _queueLines -
        _topSpacerLines -
        _bandSpacerLines -
        1 -
        _minTranscriptLines,
  );

  int get transcriptRow => _transcriptRow;
  int get transcriptCol => _transcriptCol;

  /// Activates DECSTBM scrolling margins and establishes the pinned footer.
  ///
  /// [band] is the static session facts to pin at the bottom of the screen,
  /// directly above the telemetry row. It is laid out only if the footer can
  /// spare the rows; the return value says whether it landed, so the caller
  /// can fall back to printing the dock rather than losing the facts.
  bool activate({int initialPromptLines = 1, List<String> band = const []}) {
    if (!isSupported) return false;
    _active = true;
    _promptLines = max(1, initialPromptLines);
    _queueLines = 0;
    _queuedItems = const [];

    _layoutBand(band, width: terminalColumns);
    _recomputeFooter();
    _applyScrollRegion();
    if (_bandLines.isNotEmpty) _paintBand(replacing: _bandLines.length);

    // Position cursor at scrollBottom so initial transcript output streams
    // upward from the bottom without overwriting top rows or dumping blank lines.
    _transcriptRow = scrollBottom;
    _transcriptCol = 1;
    _out('\x1B[$scrollBottom;1H');
    return _bandLines.isNotEmpty;
  }

  /// Restores normal terminal margins and releases the pinned footer.
  void deactivate() {
    if (!_active) return;
    _active = false;
    if (isSupported) {
      clearPromptArea();
      _out('\x1B[$statusRow;1H\x1B[2K');
      _out('\x1B[0m');
      for (var r = bandStartRow; r <= terminalLines; r++) {
        _out('\x1B[$r;1H\x1B[2K');
      }
      _out('\x1B[r'); // Reset scroll margins to full screen
      _out('\x1B[$terminalLines;1H\n'); // Move to bottom line and newline
      _out('\x1B[?25h'); // Ensure cursor is visible
    }
  }

  /// Clears the entire terminal screen and re-establishes margins and chrome.
  void resetAndClearScreen() {
    if (!isSupported) return;
    _out('\x1B[r'); // Reset scroll margins to full terminal
    _out('\x1B[2J\x1B[H'); // Clear entire screen and home cursor
    if (_active) {
      _applyScrollRegion();
      if (_bandLines.isNotEmpty) _paintBand(replacing: _bandLines.length);
      renderQueue();
      _transcriptRow = scrollTop;
      _transcriptCol = 1;
      _out('\x1B[$scrollTop;1H');
    }
  }

  /// Updates geometry on window resize, re-fitting the band to the new width.
  void updateTerminalSize() {
    if (!_active || !isSupported) return;
    if (_bandSegments != null) {
      final old = _bandLines.length;
      _layoutBand(_bandSegments!, width: terminalColumns);
      _recomputeFooter();
      // Repaint before the region moves: rows may have just changed owner.
      _paintBand(replacing: old);
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

    // Queue rows come out of the band before they come out of the transcript.
    _refitBand();
    final maxQueueLines = max(
      0,
      terminalLines - _promptLines - _bandLines.length - 5,
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
  /// Re-fits the band after the footer changed size, so the band gives up its
  /// rows before the transcript loses any.
  ///
  /// Without this the promise in [bandLines] only holds at activation: a prompt
  /// growing to three lines on a 12-row terminal would push the transcript under
  /// its floor while a band row sat unused above the footer.
  void _refitBand() {
    if (_bandSegments == null) return;
    final old = _bandLines.length;
    _layoutBand(_bandSegments!, width: terminalColumns);
    _recomputeFooter();
    if (_bandLines.length != old && _active && isSupported) {
      _paintBand(replacing: old);
    }
  }

  void updatePromptLines(int lines) {
    if (!_active || !isSupported) return;

    // Settle the footer first, then let the band yield rows to it, then clamp
    // against whatever room is left. Order matters: clamping before the refit
    // would count a band row that is about to be given up.
    final wanted = max(1, lines);
    final probe = min(wanted, _maxPromptLines);
    if (probe == _promptLines) return;

    final oldQueueStart = queueStartRow;
    _promptLines = wanted;
    _recomputeFooter();
    _refitBand();

    if (_promptLines > _maxPromptLines) {
      _promptLines = _maxPromptLines;
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
        _topSpacerLines +
        _queueLines +
        _promptLines +
        _bandSpacerLines +
        _bandLines.length +
        1;
  }

  void _applyScrollRegion() {
    // DECSTBM homes the cursor to (1,1) as a side effect. Row 1 is inside the
    // region here, so a newline there scrolls a transcript line into scrollback
    // rather than eating chrome — but the save/restore still keeps the human's
    // cursor where it was.
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

  /// Gives back the last [rows] rows of transcript output without writing, so a
  /// caller that appended a fixed-height block can rewrite them in place.
  ///
  /// The cursor can never rise above [scrollTop]: a block taller than the
  /// region scrolled while being written, and the row tracking already
  /// clamped to [scrollBottom], so the rows to rewind are always the last
  /// [rows] rows of the region. The rewound rows are erased down to
  /// [scrollBottom] — never with `ESC[J`, which would clear into the pinned
  /// footer, rows this coordinator owns and a caller does not.
  @override
  void rewind(int rows) {
    if (!_active || !isSupported) return;
    _transcriptRow = max(scrollTop, _transcriptRow - rows);
    _transcriptCol = 1;
    _out('\x1B7');
    for (var r = _transcriptRow; r <= scrollBottom; r++) {
      _out('\x1B[$r;1H\x1B[2K');
    }
    _out('\x1B8');
  }

  @override
  void writeLine(String line) => writeTranscript('$line\n');

  /// Clears the prompt area in the pinned footer, up to but not including the
  /// facts band: the band paints itself, and clearing through it would flash
  /// the facts out and back on every prompt repaint.
  void clearPromptArea() {
    if (!_active || !isSupported) return;
    _out('\x1B7');
    for (var r = promptStartRow; r < promptAreaEnd; r++) {
      _out('\x1B[$r;1H\x1B[2K');
    }
    _out('\x1B8');
  }

  /// Positions the cursor at [rowOffset] and [col] inside the prompt area.
  void positionPromptCursor(int rowOffset, int col) {
    if (!_active || !isSupported) return;
    final targetRow = min(promptStartRow + rowOffset, _promptLastRow);
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
