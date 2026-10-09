import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_console/dart_console.dart';

/// Bracketed paste mode (DEC 2004). Terminals that honour it wrap a paste in
/// `ESC[200~ … ESC[201~`, which is the only reliable way to tell a paste from
/// typed keystrokes — timing heuristics misfire, and a misfire costs a send.
const String enableBracketedPasteSequence = '\x1B[?2004h';
const String disableBracketedPasteSequence = '\x1B[?2004l';

const String _pasteStartMarker = '\x1B[200~';
const String _pasteEndMarker = '\x1B[201~';

/// A paste, delivered as one literal blob. Never interpreted as Enter, so a
/// multi-line paste cannot send a prompt (feel doctrine rule 3).
class PasteBlob {
  final String text;
  PasteBlob(this.text);

  @override
  String toString() => 'PasteBlob(${text.length} chars)';
}

/// A key pressed with Alt, kept distinct from a standalone Escape press.
///
/// Before this existed, every unrecognised `ESC <char>` decoded as Escape — and
/// Escape is the interrupt gesture, so alt+Enter cancelled the turn it was
/// queueing behind. What an Alt chord *does* is the keyboard surface's call;
/// that it is never an interrupt is not negotiable (feel doctrine rule 7).
class AltKeyEvent {
  /// The underlying key, e.g. Enter for `ESC \r`.
  final Key key;

  /// Human-readable chord, e.g. `alt+enter`, `alt+left`, `alt+a`.
  final String label;

  AltKeyEvent(this.key, this.label);

  @override
  String toString() => 'AltKeyEvent($label)';
}

/// Tells a reader waiting for input that its window is over and it must return
/// control. Used when the stream needs the screen back: the human owned the row
/// while the tool ran, and handing it over must not leave a reader parked on a
/// row the transcript is about to use.
class EndOfWindow {
  const EndOfWindow();

  @override
  String toString() => 'EndOfWindow()';
}

/// Centralized terminal lifecycle manager and async keyboard stream.
///
/// Guarantees that raw mode and bracketed paste mode are NEVER leaked on process
/// termination or unhandled exceptions, and provides a non-blocking broadcast
/// stream of input.
class TerminalManager {
  static final TerminalManager instance = TerminalManager._();

  TerminalManager._();

  final Console _console = Console();
  final StreamController<Object> _inputController =
      StreamController<Object>.broadcast();
  final List<Object> _pending = [];
  final InputDecoder _decoder = InputDecoder();
  Completer<Object>? _pendingNextInput;
  StreamSubscription<List<int>>? _stdinSub;

  bool _isRawMode = false;
  bool _bracketedPaste = false;
  bool _initialized = false;

  /// What the human has typed but not submitted. It lives here rather than in
  /// the reader so that [clearBuffer] — the primitive that discards stale
  /// *keys* — structurally cannot reach it (#23, feel doctrine rule 2).
  ///
  /// Holding it here rather than in the reader is what makes an approval prompt
  /// *hold* the draft instead of losing it (#23): the prompt steals the keys and
  /// reads through [nextKey], which never touches this field, so the draft is
  /// simply still there when the window reopens.
  String draft = '';

  /// Input events: [Key], [PasteBlob], and [AltKeyEvent].
  Stream<Object> get inputStream => _inputController.stream;

  /// Keys only, for consumers that have no use for pastes or Alt chords.
  Stream<Key> get keyStream =>
      _inputController.stream.where((event) => event is Key).cast<Key>();

  /// Whether someone is currently parked on [nextInput].
  bool get hasWaitingReader => _pendingNextInput != null;

  /// Set when a window closes while no reader is parked yet. Closes covers a race
  /// that a queued sentinel cannot: a tool finishing in a few milliseconds can
  /// hand the screen back before the draft reader has reached [nextInput], and a
  /// sentinel left in the queue would then close the *next* window by accident.
  bool _windowClosed = false;

  /// Ends the window, whether or not a reader is parked yet.
  void endWindow() {
    const sentinel = EndOfWindow();
    final waiter = _pendingNextInput;
    if (waiter != null && !waiter.isCompleted) {
      _pendingNextInput = null;
      waiter.complete(sentinel);
      return;
    }
    _windowClosed = true;
  }

  /// Clears any pending close, called when a window opens so it is not closed by
  /// the handover that ended the previous one.
  void clearEndWindowSentinels() {
    _windowClosed = false;
  }

  /// Initializes signal handlers and non-blocking terminal input.
  void initialize() {
    if (_initialized) return;
    _initialized = true;

    // Guaranteed cleanup on SIGTERM
    try {
      if (!Platform.isWindows) {
        ProcessSignal.sigterm.watch().listen((_) => shutdown(143));
      }
    } catch (_) {
      // In piped or non-terminal test environments, signal watch might throw
    }

    if (stdin.hasTerminal) {
      enableRawMode();
      _stdinSub = stdin.listen(_onData, onError: (_) {}, onDone: () {});
    }
  }

  void _onData(List<int> bytes) {
    for (final event in _decoder.add(bytes)) {
      _inputController.add(event);

      if (_pendingNextInput != null) {
        final completer = _pendingNextInput!;
        _pendingNextInput = null;
        completer.complete(event);
      } else {
        _pending.add(event);
      }
    }
  }

  /// Waits asynchronously for the next input event without parking the thread.
  Future<Object> nextInput() {
    if (!stdin.hasTerminal) {
      return Future.value(Key.printable(' '));
    }
    initialize();

    if (_windowClosed) {
      // Consumed, not left set: a caller that only wants keys (an approval prompt)
      // must be able to swallow the sentinel and keep waiting, rather than spin on
      // it forever.
      _windowClosed = false;
      return Future.value(const EndOfWindow());
    }

    if (_pending.isNotEmpty) {
      return Future.value(_pending.removeAt(0));
    }

    final completer = Completer<Object>();
    _pendingNextInput = completer;
    return completer.future;
  }

  /// Waits asynchronously for the next keystroke. Paste blobs are not keys; a
  /// caller that reaches this method owns no draft to insert one into, so an
  /// arriving paste is dropped rather than mis-handled as keystrokes.
  Future<Key> nextKey() async {
    while (true) {
      final event = await nextInput();
      if (event is Key) return event;
    }
  }

  /// Discards buffered keys. By design it cannot touch [draft]: typed text belongs
  /// to the human, and no stale-key purge may eat it.
  void clearBuffer() {
    _pending.clear();
    _decoder.reset();
  }

  /// Enables terminal raw mode safely, plus bracketed paste so a paste arrives
  /// as one blob instead of a burst of Enters. Both are restored together by
  /// [disableRawMode]; neither is ever leaked.
  void enableRawMode() {
    if (_isRawMode || !stdin.hasTerminal) return;
    try {
      _console.rawMode = true;
      _isRawMode = true;
      stdout.write(enableBracketedPasteSequence);
      _bracketedPaste = true;
    } catch (_) {}
  }

  /// Restores terminal cooked mode, leaves bracketed paste mode, and ensures the
  /// cursor is visible.
  void disableRawMode() {
    if (_bracketedPaste) {
      try {
        stdout.write(disableBracketedPasteSequence);
      } catch (_) {}
      _bracketedPaste = false;
    }
    if (_isRawMode) {
      try {
        _console.rawMode = false;
      } catch (_) {}
      _isRawMode = false;
    }
    try {
      stdout.write('\x1B[?25h'); // Show cursor
    } catch (_) {}
  }

  /// Disposes stdin listeners and restores cooked mode.
  void dispose() {
    disableRawMode();
    _stdinSub?.cancel();
    _stdinSub = null;
    _initialized = false;
  }

  /// Shuts down the terminal cleanly and terminates the process.
  Never shutdown([int exitCode = 0]) {
    dispose();
    exit(exitCode);
  }
}

/// Streaming byte→input-event decoder. Holds a partial escape sequence or a
/// half-received paste between reads, so a large paste split across chunks still
/// arrives as one blob.
class InputDecoder {
  final List<int> _partial = [];
  List<int>? _pasteBuffer;

  /// Length result for [_sequenceLength]: a complete sequence of N bytes.
  static const int seqIncomplete = 0;
  static const int seqNotEscape = -1;
  static const int seqPasteStart = -2;

  /// Feed raw bytes; returns the events completed by this chunk. A partial
  /// sequence held from an earlier chunk is transparently rejoined.
  List<Object> add(List<int> bytes) {
    final events = <Object>[];
    final data = (_pasteBuffer == null && _partial.isNotEmpty)
        ? <int>[..._partial, ...bytes]
        : bytes;
    if (_pasteBuffer == null) _partial.clear();

    var i = 0;
    while (i < data.length) {
      if (_pasteBuffer != null) {
        i = _absorbPaste(data, i, events);
        continue;
      }

      final esc = _indexOf(data, i, 0x1B);
      if (esc < 0) {
        // No escape byte in the remainder: it is all literal text.
        events.addAll(_decodeLiteral(data, i, data.length));
        break;
      }
      if (esc > i) {
        events.addAll(_decodeLiteral(data, i, esc));
      }

      final len = _sequenceLength(data, esc);
      if (len == seqIncomplete) {
        _partial.addAll(data.sublist(esc));
        break;
      }
      if (len == seqPasteStart) {
        _pasteBuffer = <int>[];
        i = esc + _pasteStartMarker.length;
        continue;
      }
      if (len == seqNotEscape) {
        events.add(Key.control(ControlCharacter.escape));
        i = esc + 1;
        continue;
      }

      events.addAll(_decodeEscape(data.sublist(esc, esc + len)));
      i = esc + len;
    }

    return events;
  }

  int _absorbPaste(List<int> bytes, int from, List<Object> events) {
    final end = _indexOfSequence(bytes, from, _pasteEndMarker);
    if (end == null) {
      _pasteBuffer!.addAll(bytes.sublist(from));
      return bytes.length;
    }
    _pasteBuffer!.addAll(bytes.sublist(from, end));
    final text = _decodeText(_pasteBuffer!);
    if (text.isNotEmpty) events.add(PasteBlob(text));
    _pasteBuffer = null;
    return end + _pasteEndMarker.length;
  }

  /// Flushes whatever is held — a trailing lone Escape, or a paste that never
  /// got its end marker because the chunk ended.
  List<Object> flush() {
    final events = <Object>[];
    if (_pasteBuffer != null) {
      final text = _decodeText(_pasteBuffer!);
      if (text.isNotEmpty) events.add(PasteBlob(text));
      _pasteBuffer = null;
    }
    // A held partial is only an Escape *press* when it is a lone ESC byte. A
    // truncated CSI is dropped rather than turned into an interrupt: a partial
    // sequence that never completed is not evidence the human meant Esc.
    if (_partial.length == 1 && _partial.first == 0x1B) {
      events.add(Key.control(ControlCharacter.escape));
    }
    _partial.clear();
    return events;
  }

  void reset() {
    _partial.clear();
    _pasteBuffer = null;
  }

  static int _indexOf(List<int> bytes, int from, int byte) {
    for (var i = from; i < bytes.length; i++) {
      if (bytes[i] == byte) return i;
    }
    return -1;
  }

  static int? _indexOfSequence(List<int> bytes, int from, String seq) {
    final pattern = utf8.encode(seq);
    for (var i = from; i + pattern.length <= bytes.length; i++) {
      var matches = true;
      for (var j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return i;
    }
    return null;
  }

  static bool _startsWith(List<int> bytes, int start, List<int> pattern) {
    if (bytes.length - start < pattern.length) return false;
    for (var i = 0; i < pattern.length; i++) {
      if (bytes[start + i] != pattern[i]) return false;
    }
    return true;
  }

  /// Length of the complete escape sequence at [start], or a [seqIncomplete] /
  /// [seqNotEscape] / [seqPasteStart] marker.
  int _sequenceLength(List<int> bytes, int start) {
    final rest = bytes.length - start;
    // A chunk that ends on the Escape byte is an Escape *press*, emitted now
    // rather than held. This is the deliberate discriminator between the
    // interrupt gesture and an Alt chord: a terminal sends alt+<key> as one
    // write, so the chord arrives whole, while a human pressing Escape and then
    // typing produces two reads. Holding the byte instead would make the second
    // read a chord and swallow the interrupt (feel doctrine rule 7) — a worse
    // failure than typing one stray character. #25 owns replacing this with an
    // escape timeout.
    if (rest < 2) return seqNotEscape;

    final paste = utf8.encode(_pasteStartMarker);
    if (rest < paste.length &&
        _startsWith(bytes, start, bytes.sublist(start))) {
      // Shorter than the marker but consistent with it: could still be a paste
      // start that has not fully arrived.
      var consistent = true;
      for (var i = 0; i < rest; i++) {
        if (bytes[start + i] != paste[i]) {
          consistent = false;
          break;
        }
      }
      if (consistent) return seqIncomplete;
    }
    if (rest >= paste.length && _startsWith(bytes, start, paste)) {
      return seqPasteStart;
    }
    // Not a paste marker. Fall through to ordinary CSI / SS3 / Alt parsing — a
    // mismatch with the marker says nothing about whether this is a valid
    // sequence (ESC [ A is an arrow key, and shares the marker's first bytes).

    final b1 = bytes[start + 1];

    if (b1 == 0x5B /* '[' */ ) {
      // CSI: parameter bytes, intermediate bytes, then one final byte 0x40–0x7E.
      var i = start + 2;
      while (i < bytes.length && bytes[i] >= 0x30 && bytes[i] <= 0x3F) {
        i++;
      }
      while (i < bytes.length && bytes[i] >= 0x20 && bytes[i] <= 0x2F) {
        i++;
      }
      if (i >= bytes.length) return seqIncomplete;
      if (bytes[i] >= 0x40 && bytes[i] <= 0x7E) return i + 1 - start;
      return seqNotEscape;
    }

    if (b1 == 0x4F /* 'O' */ ) {
      // SS3, e.g. ESC O P (F1). Needs the third byte.
      return rest < 3 ? seqIncomplete : 3;
    }

    // ESC <printable> arriving in the same chunk is Alt+<char>. A lone Escape
    // press and Alt+key are the same bytes split only by timing; this
    // chunk-boundary rule is the deliberate line that keeps the interrupt gesture
    // reachable (#25 owns whether to replace it with an escape timeout).
    //
    // Control bytes are the exception, and deliberately so: ESC followed by
    // Ctrl+C must surface *both* an interrupt and a Ctrl+C rather than be folded
    // into a chord that swallows the interrupt (feel doctrine rule 7).
    final b2 = bytes[start + 1];
    final isAltChar =
        (b2 >= 0x20 && b2 <= 0x7E) || b2 == 0x0D || b2 == 0x0A || b2 == 0x7F;
    return isAltChar ? 2 : seqNotEscape;
  }

  List<Object> _decodeLiteral(List<int> bytes, int from, int to) {
    final events = <Object>[];
    var i = from;
    while (i < to) {
      final b = bytes[i];

      if (b >= 0x01 && b <= 0x1A) {
        if (b == 0x09) {
          events.add(Key.control(ControlCharacter.tab));
        } else if (b == 0x0D) {
          events.add(Key.control(ControlCharacter.enter));
        } else if (b == 0x0A) {
          // Ctrl+J keeps its own byte. ICRNL is already cleared in raw mode, so
          // the collision with Enter was Nib's decoder, not the terminal.
          events.add(Key.control(ControlCharacter.ctrlJ));
        } else if (b == 0x08) {
          events.add(Key.control(ControlCharacter.backspace));
        } else {
          events.add(Key.control(ControlCharacter.values[b]));
        }
        i++;
        continue;
      }

      if (b == 0x7F) {
        events.add(Key.control(ControlCharacter.backspace));
        i++;
        continue;
      }

      var seqLen = 1;
      if ((b & 0xE0) == 0xC0) {
        seqLen = 2;
      } else if ((b & 0xF0) == 0xE0) {
        seqLen = 3;
      } else if ((b & 0xF8) == 0xF0) {
        seqLen = 4;
      }

      if (i + seqLen <= to) {
        try {
          final str = utf8.decode(bytes.sublist(i, i + seqLen));
          for (final rune in str.runes) {
            // Assigned through `char` rather than the printable constructor:
            // an astral-plane character (emoji) is one rune but two UTF-16
            // units, which the constructor's length-1 assert rejects.
            final key = Key.printable(' ');
            key.char = String.fromCharCode(rune);
            events.add(key);
          }
          i += seqLen;
          continue;
        } catch (_) {}
      }

      events.add(Key.printable(String.fromCharCode(b)));
      i++;
    }
    return events;
  }

  static String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  List<Object> _decodeEscape(List<int> seq) {
    if (seq.length < 2) return [Key.control(ControlCharacter.escape)];

    final b1 = seq[1];

    if (b1 == 0x5B) {
      final body = String.fromCharCodes(seq.sublist(2, seq.length - 1));
      final finalByte = seq[seq.length - 1];
      final mods = _modifiers(body);

      if (finalByte >= 0x41 && finalByte <= 0x5A) {
        final ControlCharacter? arrow;
        switch (finalByte) {
          case 0x41:
            arrow = ControlCharacter.arrowUp;
          case 0x42:
            arrow = ControlCharacter.arrowDown;
          case 0x43:
            arrow = ControlCharacter.arrowRight;
          case 0x44:
            arrow = ControlCharacter.arrowLeft;
          case 0x48:
            return [Key.control(ControlCharacter.home)];
          case 0x46:
            return [Key.control(ControlCharacter.end)];
          case 0x5A: // shift+tab: consumed, not Escape + "[Z". Binding is #25's.
            return const [];
          default:
            arrow = null;
        }
        if (arrow == null) return const [];
        final key = Key.control(arrow);
        if (mods.none) return [key];
        return [AltKeyEvent(key, '${mods.label}+${_arrowName(arrow)}')];
      }

      if (finalByte == 0x7E /* '~' */ ) {
        switch (int.tryParse(body.split(';').first)) {
          case 1:
          case 7:
            return [Key.control(ControlCharacter.home)];
          case 3:
            return [Key.control(ControlCharacter.delete)];
          case 4:
          case 8:
            return [Key.control(ControlCharacter.end)];
          case 5:
            return [Key.control(ControlCharacter.pageUp)];
          case 6:
            return [Key.control(ControlCharacter.pageDown)];
        }
        return const [];
      }

      // Unrecognised CSI: consumed whole. This is the general fix for the
      // defect where an unknown sequence emitted Escape and advanced one byte,
      // leaving the remainder to be typed into the prompt as literal text.
      return const [];
    }

    if (b1 == 0x4F) return const []; // SS3 function keys: consumed.

    final char = _decodeText(seq.sublist(1));
    if (char == '\r' || char == '\n') {
      return [AltKeyEvent(Key.control(ControlCharacter.enter), 'alt+enter')];
    }
    if (char == '\x7F' || char == '\x08') {
      return [
        AltKeyEvent(Key.control(ControlCharacter.backspace), 'alt+backspace'),
      ];
    }
    return [AltKeyEvent(Key.printable(char), 'alt+$char')];
  }

  static String _arrowName(ControlCharacter c) => switch (c) {
    ControlCharacter.arrowUp => 'up',
    ControlCharacter.arrowDown => 'down',
    ControlCharacter.arrowLeft => 'left',
    ControlCharacter.arrowRight => 'right',
    _ => 'arrow',
  };

  static _Mods _modifiers(String body) {
    final parts = body.split(';');
    if (parts.length < 2) return const _Mods();
    final value = (int.tryParse(parts[1]) ?? 1) - 1;
    return _Mods(
      shift: (value & 0x01) != 0,
      alt: (value & 0x02) != 0,
      ctrl: (value & 0x04) != 0,
    );
  }
}

class _Mods {
  final bool shift;
  final bool alt;
  final bool ctrl;
  const _Mods({this.shift = false, this.alt = false, this.ctrl = false});

  bool get none => !shift && !alt && !ctrl;

  String get label {
    final parts = <String>[];
    if (ctrl) parts.add('ctrl');
    if (alt) parts.add('alt');
    if (shift) parts.add('shift');
    return parts.join('+');
  }
}

/// Robust ANSI escape sequence and UTF-8 key decoder.
class KeyDecoder {
  /// Full decode: [Key]s plus [PasteBlob]s and [AltKeyEvent]s.
  static List<Object> decodeInput(List<int> bytes) {
    final decoder = InputDecoder();
    return [...decoder.add(bytes), ...decoder.flush()];
  }

  /// Keys only. A paste is flattened into literal keystrokes — exactly what a
  /// terminal without bracketed paste produces — for callers that cannot act on
  /// a paste, and for tests that assert key sequences.
  static List<Key> decode(List<int> bytes) {
    final keys = <Key>[];
    for (final event in decodeInput(bytes)) {
      if (event is Key) {
        keys.add(event);
      } else if (event is PasteBlob) {
        final flat = InputDecoder();
        keys.addAll(flat.add(utf8.encode(event.text)).whereType<Key>());
        keys.addAll(flat.flush().whereType<Key>());
      }
    }
    return keys;
  }
}
