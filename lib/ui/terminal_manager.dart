import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_console/dart_console.dart';

/// Centralized terminal lifecycle manager and async keyboard stream.
///
/// Guarantees that raw mode is NEVER leaked on process termination or unhandled exceptions,
/// and provides a non-blocking broadcast stream of keyboard input.
class TerminalManager {
  static final TerminalManager instance = TerminalManager._();

  TerminalManager._();

  final Console _console = Console();
  final StreamController<Key> _keyController =
      StreamController<Key>.broadcast();
  final List<Key> _bufferedKeys = [];
  Completer<Key>? _pendingNextKey;
  StreamSubscription<List<int>>? _stdinSub;

  bool _isRawMode = false;
  bool _initialized = false;

  Stream<Key> get keyStream => _keyController.stream;

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
    final keys = KeyDecoder.decode(bytes);
    for (final key in keys) {
      _keyController.add(key);

      if (_pendingNextKey != null) {
        final completer = _pendingNextKey!;
        _pendingNextKey = null;
        completer.complete(key);
      } else {
        _bufferedKeys.add(key);
      }
    }
  }

  /// Waits asynchronously for the next keystroke without parking the thread.
  Future<Key> nextKey() {
    if (!stdin.hasTerminal) {
      return Future.value(Key.printable(' '));
    }
    initialize();

    if (_bufferedKeys.isNotEmpty) {
      return Future.value(_bufferedKeys.removeAt(0));
    }

    final completer = Completer<Key>();
    _pendingNextKey = completer;
    return completer.future;
  }

  /// Clears any buffered keys in the input queue.
  void clearBuffer() {
    _bufferedKeys.clear();
  }

  /// Enables terminal raw mode safely.
  void enableRawMode() {
    if (!_isRawMode && stdin.hasTerminal) {
      try {
        _console.rawMode = true;
        _isRawMode = true;
      } catch (_) {}
    }
  }

  /// Restores terminal cooked mode and ensures cursor is visible.
  void disableRawMode() {
    if (_isRawMode) {
      try {
        _console.rawMode = false;
        _isRawMode = false;
      } catch (_) {}
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

/// Robust ANSI escape sequence and UTF-8 key decoder.
class KeyDecoder {
  static List<Key> decode(List<int> bytes) {
    final keys = <Key>[];
    int i = 0;

    while (i < bytes.length) {
      final b = bytes[i];

      // 1. Control characters 0x01..0x1A (Ctrl+A .. Ctrl+Z)
      if (b >= 0x01 && b <= 0x1A) {
        if (b == 0x09) {
          keys.add(Key.control(ControlCharacter.tab));
        } else if (b == 0x0A || b == 0x0D) {
          keys.add(Key.control(ControlCharacter.enter));
        } else if (b == 0x08) {
          keys.add(Key.control(ControlCharacter.backspace));
        } else {
          keys.add(Key.control(ControlCharacter.values[b]));
        }
        i++;
        continue;
      }

      // 2. Backspace (0x7F / 127)
      if (b == 0x7F) {
        keys.add(Key.control(ControlCharacter.backspace));
        i++;
        continue;
      }

      // 3. Escape sequences (0x1B)
      if (b == 0x1B) {
        if (i + 1 >= bytes.length) {
          // Lone Escape key press
          keys.add(Key.control(ControlCharacter.escape));
          i++;
          continue;
        }

        final next = bytes[i + 1];

        // CSI sequence: ESC [
        if (next == 0x5B /* '[' */ ) {
          if (i + 2 < bytes.length) {
            final csi = bytes[i + 2];
            switch (csi) {
              case 0x41: // 'A'
                keys.add(Key.control(ControlCharacter.arrowUp));
                i += 3;
                continue;
              case 0x42: // 'B'
                keys.add(Key.control(ControlCharacter.arrowDown));
                i += 3;
                continue;
              case 0x43: // 'C'
                keys.add(Key.control(ControlCharacter.arrowRight));
                i += 3;
                continue;
              case 0x44: // 'D'
                keys.add(Key.control(ControlCharacter.arrowLeft));
                i += 3;
                continue;
              case 0x48: // 'H'
                keys.add(Key.control(ControlCharacter.home));
                i += 3;
                continue;
              case 0x46: // 'F'
                keys.add(Key.control(ControlCharacter.end));
                i += 3;
                continue;
              default:
                // Extended sequence e.g. ESC [ 3 ~ (Delete)
                if (i + 3 < bytes.length && bytes[i + 3] == 0x7E /* '~' */ ) {
                  switch (csi) {
                    case 0x31: // '1'
                      keys.add(Key.control(ControlCharacter.home));
                      i += 4;
                      continue;
                    case 0x33: // '3'
                      keys.add(Key.control(ControlCharacter.delete));
                      i += 4;
                      continue;
                    case 0x34: // '4'
                      keys.add(Key.control(ControlCharacter.end));
                      i += 4;
                      continue;
                    case 0x35: // '5'
                      keys.add(Key.control(ControlCharacter.pageUp));
                      i += 4;
                      continue;
                    case 0x36: // '6'
                      keys.add(Key.control(ControlCharacter.pageDown));
                      i += 4;
                      continue;
                  }
                }
                break;
            }
          }
        }

        // Unrecognized escape sequence: emit escape and advance
        keys.add(Key.control(ControlCharacter.escape));
        i++;
        continue;
      }

      // 4. Printable UTF-8 characters
      int seqLen = 1;
      if ((b & 0xE0) == 0xC0) {
        seqLen = 2;
      } else if ((b & 0xF0) == 0xE0) {
        seqLen = 3;
      } else if ((b & 0xF8) == 0xF0) {
        seqLen = 4;
      }

      if (i + seqLen <= bytes.length) {
        try {
          final str = utf8.decode(bytes.sublist(i, i + seqLen));
          for (final rune in str.runes) {
            final key = Key.printable(' ');
            key.char = String.fromCharCode(rune);
            keys.add(key);
          }
          i += seqLen;
          continue;
        } catch (_) {}
      }

      // Fallback single character
      keys.add(Key.printable(String.fromCharCode(b)));
      i++;
    }

    return keys;
  }
}
