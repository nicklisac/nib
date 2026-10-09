import 'dart:io';
import 'dart:math';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;
import 'ansi.dart';
import 'autocomplete.dart';
import 'key_binding.dart';
import 'screen_coordinator.dart';
import 'terminal_manager.dart';
import 'theme.dart';

/// What the human did with the line they were composing.
enum SubmitKind {
  /// Enter on a non-empty line: submit it.
  submit,

  /// Enter on an empty line while a draft is queued: hand the queue over.
  flushQueue,

  /// Alt+Enter: the draft is complete, send it when the turn ends.
  queue,

  /// The human-owned window closed under the reader — the stream needs the screen
  /// back, or an approval prompt is taking the keys. The draft survives and the
  /// caller must not treat this as EOF.
  windowEnded,

  /// EOF (Ctrl+D, or double Ctrl+C).
  eof,
}

class SubmitResult {
  final String text;
  final SubmitKind kind;
  SubmitResult(this.text, this.kind);
}

/// Interactive terminal prompt reader supporting persistent history, live command palette,
/// Tab completion, and bracketed paste.
///
/// One reader serves the idle prompt and the mid-turn draft, because both are the
/// human-owned window (#20): while a tool runs nothing is being written, so the
/// draft line opens at the current cursor on the same code path.
class PromptReader {
  final List<String> _history = [];
  int _historyIndex = -1;
  String _savedDraft = '';
  late final File _historyFile;

  final List<String> _queuedMessages = [];

  /// Text composed during a turn, waiting for the turn to end.
  String get queued => _queuedMessages.join('\n');

  /// List of individual queued messages.
  List<String> get queuedMessages => List.unmodifiable(_queuedMessages);

  /// Called whenever the queue changes, so the ambient line can show a queue
  /// indicator. Presentation only — it writes nothing.
  void Function(String queued)? onCompose;

  final void Function(String text) _out;

  PromptReader({void Function(String text)? out}) : _out = out ?? stdout.write {
    _initHistoryFile();
  }

  bool get hasQueued => _queuedMessages.isNotEmpty;

  /// Compose [text] into the queue slot. Never overwrites what
  /// is already there (feel doctrine rule 2).
  void enqueue(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _queuedMessages.add(trimmed);
    onCompose?.call(queued);
  }

  /// Empties the queue slot and hands back its text joined by newlines.
  String takeQueued() {
    final text = queued;
    _queuedMessages.clear();
    onCompose?.call(queued);
    return text;
  }

  /// Takes and removes the next queued message.
  String takeNextQueued() {
    if (_queuedMessages.isEmpty) return '';
    final text = _queuedMessages.removeAt(0);
    onCompose?.call(queued);
    return text;
  }

  /// Takes and removes all queued messages as a list.
  List<String> takeAllQueued() {
    final copy = List<String>.from(_queuedMessages);
    _queuedMessages.clear();
    onCompose?.call(queued);
    return copy;
  }

  void _initHistoryFile() {
    try {
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isNotEmpty) {
        final dir = Directory(p.join(home, '.nib'));
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        _historyFile = File(p.join(dir.path, 'history'));
        if (_historyFile.existsSync()) {
          final lines = _historyFile.readAsLinesSync();
          _history.addAll(lines.where((l) => l.trim().isNotEmpty));
        }
      }
    } catch (_) {}
  }

  /// Adds a command or user prompt to persistent history.
  void addToHistory(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    // Avoid immediate duplicate
    if (_history.isNotEmpty && _history.last == trimmed) {
      return;
    }

    _history.add(trimmed);
    try {
      if (_historyFile.existsSync()) {
        _historyFile.writeAsStringSync('$trimmed\n', mode: FileMode.append);
      }
    } catch (_) {}
  }

  KeyBindings keyBindings = KeyBindings.defaults();

  /// Callbacks for actions triggered via key bindings
  void Function()? onSessionPicker;
  void Function()? onThinkingCycle;
  void Function()? onModelCycle;

  static int prevWordBoundary(String text, int index) {
    if (index <= 0) return 0;
    var i = index;
    // Skip trailing whitespace to the left
    while (i > 0 && text[i - 1].trim().isEmpty) {
      i--;
    }
    // Skip non-whitespace word characters to the left
    while (i > 0 && text[i - 1].trim().isNotEmpty) {
      i--;
    }
    return i;
  }

  static int nextWordBoundary(String text, int index) {
    if (index >= text.length) return text.length;
    var i = index;
    // Skip whitespace to the right
    while (i < text.length && text[i].trim().isEmpty) {
      i++;
    }
    // Skip non-whitespace word characters to the right
    while (i < text.length && text[i].trim().isNotEmpty) {
      i++;
    }
    return i;
  }

  int get _terminalCols {
    try {
      if (stdout.hasTerminal) {
        return max(stdout.terminalColumns, 40);
      }
    } catch (_) {}
    return 80;
  }

  static int visibleWidth(String str) {
    return str.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '').length;
  }

  /// Row and column the cursor lands on after [to] characters of a buffer,
  /// counting the hard newlines a paste or Ctrl+J can put inside it as well as
  /// the soft wraps a long buffer causes. Without the newline term a multi-line
  /// buffer miscounts its own height and the repaint walks over the transcript.
  static (int, int) cursorPosition(
    String prompt,
    String buffer,
    int to,
    int cols,
  ) {
    final promptLen = visibleWidth(prompt);
    // The buffer only. The prompt contributes [promptLen] *visible* cells to the
    // first line; the raw prompt must not be counted as well, because its SGR
    // escape bytes are never printed and the cursor would land a whole prompt's
    // worth of bytes to the right of the text.
    final text = buffer.substring(0, to);
    final lines = text.split('\n');
    var row = 0;
    var col = 0;
    for (var i = 0; i < lines.length; i++) {
      final width = (i == 0 ? promptLen : 0) + lines[i].length;
      if (i == lines.length - 1) {
        row += width ~/ cols;
        col = width % cols;
      } else {
        row += width ~/ cols + 1;
        col = 0;
      }
    }
    return (row, col);
  }

  int _cursorRow = 0;
  int _paletteLines = 0;
  DateTime? _lastCtrlCTime;
  bool _windowEnded = false;

  bool _inReadLine = false;
  bool _isSilent = false;
  bool _isSuspended = false;
  String _currentPrompt = '';
  String _currentBuffer = '';
  int _currentCursor = 0;

  bool get isDrafting => _inReadLine && !_isSilent;

  void eraseCurrentLine() {
    if (!_inReadLine || _isSilent || _isSuspended) return;
    _clearPalette();
    if (_cursorRow > 0) {
      _out('\x1B[${_cursorRow}A');
    }
    _out('\r\x1B[J');
    _cursorRow = 0;
    _isSuspended = true;
  }

  void repaintCurrentLine() {
    if (!_inReadLine) return;
    if (ScreenCoordinator.instance.isActive) {
      _repaint(_currentPrompt, _currentBuffer, _currentCursor);
      return;
    }
    if (_isSilent || !_isSuspended) return;
    _isSuspended = false;
    _repaint(_currentPrompt, _currentBuffer, _currentCursor);
  }

  /// Reads one line, reporting what the human meant. Returns null at EOF.
  ///
  /// [initial] seeds the buffer — this is how a draft held across an approval
  /// prompt, or restored after an interrupt, comes back for editing.
  Future<SubmitResult?> readSubmit({
    required String prompt,
    String initial = '',
    bool window = false,
    bool silent = false,
    void Function()? onStartTyping,
    bool hasQueued = false,
  }) async {
    final first = await readLine(
      prompt: prompt,
      initial: initial,
      window: window,
      silent: silent,
      onStartTyping: onStartTyping,
    );
    if (first == null) {
      return SubmitResult(
        '',
        _windowEnded ? SubmitKind.windowEnded : SubmitKind.eof,
      );
    }
    if (_pendingKind == SubmitKind.queue) {
      _pendingKind = null;
      return SubmitResult(first, SubmitKind.queue);
    }
    if (_pendingKind == SubmitKind.flushQueue) {
      _pendingKind = null;
      return SubmitResult(first, SubmitKind.flushQueue);
    }
    return SubmitResult(first, SubmitKind.submit);
  }

  SubmitKind? _pendingKind;

  /// Called when the human makes the interrupt gesture (Esc or Ctrl+C) while this
  /// reader holds the keys. The mid-turn draft window sets it, because there Esc
  /// must stop the turn rather than dismiss a palette (#20: Esc and Ctrl+C are the
  /// exclusive "stop it" gesture, and composed text is never an interrupt). The
  /// idle prompt leaves it null, where Esc keeps dismissing the palette.
  void Function(String keyName)? onInterrupt;

  /// Reads a line from terminal stdin with live command palette when typing `/`.
  ///
  /// [window] marks this read as the human-owned window during a turn, where Esc
  /// and Ctrl+C interrupt and Alt+Enter queues.
  /// [silent] defers prompt rendering until typing starts, so fast tools don't flicker.
  /// [onStartTyping] is fired the instant the user begins typing.
  Future<String?> readLine({
    required String prompt,
    String initial = '',
    bool window = false,
    bool silent = false,
    void Function()? onStartTyping,
  }) async {
    if (!stdin.hasTerminal) {
      _out(prompt);
      return stdin.readLineSync();
    }

    _inReadLine = true;
    _isSilent =
        !ScreenCoordinator.instance.isActive && silent && initial.isEmpty;
    _isSuspended = false;
    _currentPrompt = prompt;
    _currentBuffer = initial;
    _currentCursor = initial.length;
    TerminalManager.instance.isDrafting = !_isSilent;
    TerminalManager.instance.draft = initial;
    if (ScreenCoordinator.instance.isActive) {
      _repaint(prompt, initial, initial.length);
    } else if (!_isSilent) {
      _out('$prompt$initial');
    }

    var buffer = initial;
    var cursor = initial.length;
    _windowEnded = false;
    _historyIndex = -1;
    _savedDraft = '';
    _cursorRow = 0;
    _paletteLines = 0;
    var paletteIndex = 0;
    onCompose?.call(queued);

    void breakSilence() {
      if (_isSilent) {
        _isSilent = false;
        _isSuspended = false;
        TerminalManager.instance.isDrafting = true;
        onStartTyping?.call();
        _out(prompt);
      }
    }

    try {
      while (true) {
        final event = await TerminalManager.instance.nextInput();

        // The window closed under us: the stream needs the row back, or an approval
        // prompt is taking the keys. Nothing typed is lost — the buffer is already
        // published on TerminalManager.draft, which neither purge nor close reaches.
        if (event is EndOfWindow) {
          _windowEnded = true;
          // Hand the row back clean. The draft prompt was written at a fresh row, so
          // erasing from there down removes the draft line and leaves nothing behind
          // for the transcript to be appended to. What was typed is already on
          // TerminalManager.draft, where neither this nor a purge can reach it.
          if (ScreenCoordinator.instance.isActive) {
            ScreenCoordinator.instance.clearPromptArea();
            ScreenCoordinator.instance.updatePromptLines(1);
          } else if (!_isSilent) {
            if (_cursorRow > 0) {
              _out('\x1B[${_cursorRow}A');
            }
            _out('\r\x1B[J');
          }
          _cursorRow = 0;
          _paletteLines = 0;
          return null;
        }

        // A paste is one literal blob. It never submits, no matter how many
        // newlines it carries (feel doctrine rule 3).
        if (event is PasteBlob) {
          breakSilence();
          _clearPalette();
          final text = event.text
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n');
          buffer =
              buffer.substring(0, cursor) + text + buffer.substring(cursor);
          cursor += text.length;
          _currentBuffer = buffer;
          _currentCursor = cursor;
          paletteIndex = 0;
          _publishDraft(buffer);
          _repaint(prompt, buffer, cursor);
          continue;
        }

        final isSlashCommandMode =
            buffer.startsWith('/') && !buffer.contains(' ');
        final paletteMatches = isSlashCommandMode
            ? AutoCompleter.completeSlashInfo(buffer)
            : <SlashCommandInfo>[];

        // Alt chords and multi-key sequences
        if (event is AltKeyEvent) {
          if (window &&
              event.label == 'alt+enter' &&
              buffer.trim().isNotEmpty) {
            _clearPalette(prompt, buffer);
            if (ScreenCoordinator.instance.isActive) {
              ScreenCoordinator.instance.clearPromptArea();
              ScreenCoordinator.instance.updatePromptLines(1);
            } else {
              if (_cursorRow > 0) {
                _out('\x1B[${_cursorRow}A');
              }
              _out('\r\x1B[2K');
            }
            _cursorRow = 0;
            _paletteLines = 0;
            _pendingKind = SubmitKind.queue;
            TerminalManager.instance.draft = '';
            TerminalManager.instance.isDrafting = false;
            onCompose?.call(queued);
            return buffer;
          }

          // Word jump backward: alt+left, ctrl+left, alt+b
          if (event.label == 'alt+left' ||
              event.label == 'ctrl+left' ||
              event.label == 'alt+b') {
            final newPos = prevWordBoundary(buffer, cursor);
            if (newPos != cursor) {
              cursor = newPos;
              _repaint(
                prompt,
                buffer,
                cursor,
                paletteMatches: paletteMatches,
                paletteIndex: paletteIndex,
              );
            }
            continue;
          }

          // Word jump forward: alt+right, ctrl+right, alt+f
          if (event.label == 'alt+right' ||
              event.label == 'ctrl+right' ||
              event.label == 'alt+f') {
            final newPos = nextWordBoundary(buffer, cursor);
            if (newPos != cursor) {
              cursor = newPos;
              _repaint(
                prompt,
                buffer,
                cursor,
                paletteMatches: paletteMatches,
                paletteIndex: paletteIndex,
              );
            }
            continue;
          }

          // Backward word deletion: alt+backspace
          if (event.label == 'alt+backspace') {
            if (cursor > 0) {
              breakSilence();
              final newPos = prevWordBoundary(buffer, cursor);
              buffer = buffer.substring(0, newPos) + buffer.substring(cursor);
              cursor = newPos;
              paletteIndex = 0;
              final newMatches = buffer.startsWith('/') && !buffer.contains(' ')
                  ? AutoCompleter.completeSlashInfo(buffer)
                  : <SlashCommandInfo>[];
              _publishDraft(buffer);
              _repaint(
                prompt,
                buffer,
                cursor,
                paletteMatches: newMatches,
                paletteIndex: paletteIndex,
              );
            }
            continue;
          }

          // Check key action bindings (e.g. shift+tab for thinking cycle)
          final action = keyBindings.match(event);
          if (action != null) {
            switch (action) {
              case KeyAction.thinkingCycle:
                onThinkingCycle?.call();
                _repaint(prompt, buffer, cursor);
                continue;
              case KeyAction.sessionPicker:
                onSessionPicker?.call();
                continue;
              case KeyAction.modelCycle:
                onModelCycle?.call();
                _repaint(prompt, buffer, cursor);
                continue;
              default:
                break;
            }
          }

          continue;
        }

        final key = event as Key;

        if (key.isControl) {
          // Inside the human-owned window, Esc and Ctrl+C are the interrupt and
          // nothing else. The draft they leave behind is already published where a
          // purge cannot reach it.
          if (window &&
              (key.controlChar == ControlCharacter.escape ||
                  key.controlChar == ControlCharacter.ctrlC)) {
            _windowEnded = true;
            _clearPalette();
            if (ScreenCoordinator.instance.isActive) {
              ScreenCoordinator.instance.clearPromptArea();
              ScreenCoordinator.instance.updatePromptLines(1);
            } else if (!_isSilent) {
              if (_cursorRow > 0) {
                _out('\x1B[${_cursorRow}A');
              }
              _out('\r\x1B[J');
            }
            onInterrupt?.call(
              key.controlChar == ControlCharacter.escape ? 'Esc' : 'Ctrl+C',
            );
            return null;
          }

          switch (key.controlChar) {
            case ControlCharacter.enter:
              if (window) {
                if (buffer.trim().isNotEmpty) {
                  _clearPalette(prompt, buffer);
                  if (ScreenCoordinator.instance.isActive) {
                    ScreenCoordinator.instance.clearPromptArea();
                    ScreenCoordinator.instance.updatePromptLines(1);
                  } else {
                    if (_cursorRow > 0) {
                      _out('\x1B[${_cursorRow}A');
                    }
                    _out('\r\x1B[2K');
                  }
                  _cursorRow = 0;
                  _paletteLines = 0;
                  _pendingKind = SubmitKind.queue;
                  final result = buffer.trim();
                  addToHistory(result);
                  TerminalManager.instance.draft = '';
                  TerminalManager.instance.isDrafting = false;
                  onCompose?.call(queued);
                  return buffer;
                }
                continue;
              }

              // Enter on an empty line while a message is queued hands the queue
              // over; typing it again is the confirmation.
              if (!window &&
                  hasQueued &&
                  buffer.trim().isEmpty &&
                  queued.trim().isNotEmpty) {
                _clearPalette(prompt, buffer);
                if (ScreenCoordinator.instance.isActive) {
                  ScreenCoordinator.instance.clearPromptArea();
                  ScreenCoordinator.instance.updatePromptLines(1);
                } else {
                  _out('\n');
                }
                _cursorRow = 0;
                _paletteLines = 0;
                _pendingKind = SubmitKind.flushQueue;
                TerminalManager.instance.draft = '';
                TerminalManager.instance.isDrafting = false;
                onCompose?.call(queued);
                return buffer;
              }

              // If palette is open and user pressed enter on a partial match
              if (paletteMatches.isNotEmpty &&
                  buffer.length < paletteMatches[paletteIndex].command.length) {
                final selectedCmd = paletteMatches[paletteIndex].command;
                if (selectedCmd == '/theme' ||
                    selectedCmd == '/provider' ||
                    selectedCmd == '/model' ||
                    selectedCmd == '/compact') {
                  buffer = '$selectedCmd ';
                  cursor = buffer.length;
                  _currentBuffer = buffer;
                  _currentCursor = cursor;
                  paletteIndex = 0;
                  _repaint(prompt, buffer, cursor);
                  continue;
                } else {
                  buffer = selectedCmd;
                }
              }

              _clearPalette(prompt, buffer);
              if (ScreenCoordinator.instance.isActive) {
                ScreenCoordinator.instance.clearPromptArea();
                ScreenCoordinator.instance.updatePromptLines(1);
              } else {
                _out('\n');
              }
              _cursorRow = 0;
              _paletteLines = 0;
              final result = buffer.trim();
              if (result.isNotEmpty) {
                addToHistory(result);
              }
              TerminalManager.instance.draft = '';
              TerminalManager.instance.isDrafting = false;
              onCompose?.call(queued);
              return buffer;

            case ControlCharacter.ctrlC:
              _clearPalette();
              if (buffer.isNotEmpty) {
                // Ctrl+C on a non-empty line used to wipe the line. An interrupt
                // never discards a draft (feel doctrine rule 2), so it stops
                // clearing and falls through to the exit hint instead.
                if (_cursorRow > 0) {
                  _out('\x1B[${_cursorRow}A');
                }
                _out('\n');
                _cursorRow = 0;
                _paletteLines = 0;
                _out(prompt);
                _repaint(prompt, buffer, cursor);
                continue;
              } else {
                final now = DateTime.now();
                if (_lastCtrlCTime != null &&
                    now.difference(_lastCtrlCTime!) <
                        const Duration(seconds: 2)) {
                  _out('\n');
                  return null;
                } else {
                  _lastCtrlCTime = now;
                  _out('\n');
                  _out(
                    '  ${NibTheme.current.muted.text('(Press Ctrl+C again to exit, or /exit)')}\n',
                  );
                  _out(prompt);
                  continue;
                }
              }

            case ControlCharacter.ctrlD:
              if (buffer.isEmpty) {
                return null;
              }
              break;

            case ControlCharacter.ctrlJ:
              // Ctrl+J inserts a newline instead of submitting. Its byte is
              // distinct from Enter's — raw mode clears ICRNL — so the old
              // collision was Nib's decoder, not the terminal.
              breakSilence();
              buffer =
                  '${buffer.substring(0, cursor)}\n${buffer.substring(cursor)}';
              cursor += 1;
              paletteIndex = 0;
              _publishDraft(buffer);
              _repaint(prompt, buffer, cursor);
              break;

            case ControlCharacter.arrowUp:
              if (paletteMatches.isNotEmpty) {
                // Navigate command palette upward
                paletteIndex =
                    (paletteIndex - 1 + paletteMatches.length) %
                    paletteMatches.length;
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: paletteMatches,
                  paletteIndex: paletteIndex,
                );
              } else if (_history.isNotEmpty) {
                // Recall older history entry (Tau-style)
                if (_historyIndex == -1) {
                  _savedDraft = buffer;
                }
                if (_historyIndex < _history.length - 1) {
                  _historyIndex++;
                  buffer = _history[_history.length - 1 - _historyIndex];
                  cursor = buffer.length;
                  _publishDraft(buffer);
                  _repaint(prompt, buffer, cursor);
                }
              }
              break;

            case ControlCharacter.arrowDown:
              if (paletteMatches.isNotEmpty) {
                // Navigate command palette downward
                paletteIndex = (paletteIndex + 1) % paletteMatches.length;
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: paletteMatches,
                  paletteIndex: paletteIndex,
                );
              } else if (_historyIndex > 0) {
                _historyIndex--;
                buffer = _history[_history.length - 1 - _historyIndex];
                cursor = buffer.length;
                _publishDraft(buffer);
                _repaint(prompt, buffer, cursor);
              } else if (_historyIndex == 0) {
                _historyIndex = -1;
                buffer = _savedDraft;
                cursor = buffer.length;
                _publishDraft(buffer);
                _repaint(prompt, buffer, cursor);
              }
              break;

            case ControlCharacter.arrowLeft:
              if (cursor > 0) {
                cursor--;
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: paletteMatches,
                  paletteIndex: paletteIndex,
                );
              }
              break;

            case ControlCharacter.arrowRight:
              if (cursor < buffer.length) {
                cursor++;
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: paletteMatches,
                  paletteIndex: paletteIndex,
                );
              }
              break;

            case ControlCharacter.home:
            case ControlCharacter.ctrlA:
              cursor = 0;
              _repaint(
                prompt,
                buffer,
                cursor,
                paletteMatches: paletteMatches,
                paletteIndex: paletteIndex,
              );
              break;

            case ControlCharacter.end:
            case ControlCharacter.ctrlE:
              cursor = buffer.length;
              _repaint(
                prompt,
                buffer,
                cursor,
                paletteMatches: paletteMatches,
                paletteIndex: paletteIndex,
              );
              break;

            case ControlCharacter.backspace:
            case ControlCharacter.ctrlH:
              if (cursor > 0) {
                breakSilence();
                buffer =
                    buffer.substring(0, cursor - 1) + buffer.substring(cursor);
                cursor--;
                paletteIndex = 0;
                final newMatches =
                    buffer.startsWith('/') && !buffer.contains(' ')
                    ? AutoCompleter.completeSlashInfo(buffer)
                    : <SlashCommandInfo>[];
                _publishDraft(buffer);
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: newMatches,
                  paletteIndex: paletteIndex,
                );
              }
              break;

            case ControlCharacter.delete:
              if (cursor < buffer.length) {
                breakSilence();
                buffer =
                    buffer.substring(0, cursor) + buffer.substring(cursor + 1);
                final newMatches =
                    buffer.startsWith('/') && !buffer.contains(' ')
                    ? AutoCompleter.completeSlashInfo(buffer)
                    : <SlashCommandInfo>[];
                _publishDraft(buffer);
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: newMatches,
                  paletteIndex: paletteIndex,
                );
              }
              break;

            case ControlCharacter.ctrlU:
              if (cursor > 0 || buffer.isNotEmpty) {
                breakSilence();
                // Ctrl+U deletes from start of line/buffer to cursor
                buffer = buffer.substring(cursor);
                cursor = 0;
                paletteIndex = 0;
                final newMatches =
                    buffer.startsWith('/') && !buffer.contains(' ')
                    ? AutoCompleter.completeSlashInfo(buffer)
                    : <SlashCommandInfo>[];
                _publishDraft(buffer);
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: newMatches,
                  paletteIndex: paletteIndex,
                );
              }
              break;

            case ControlCharacter.ctrlW:
              if (cursor > 0) {
                breakSilence();
                final newPos = prevWordBoundary(buffer, cursor);
                buffer = buffer.substring(0, newPos) + buffer.substring(cursor);
                cursor = newPos;
                paletteIndex = 0;
                final newMatches =
                    buffer.startsWith('/') && !buffer.contains(' ')
                    ? AutoCompleter.completeSlashInfo(buffer)
                    : <SlashCommandInfo>[];
                _publishDraft(buffer);
                _repaint(
                  prompt,
                  buffer,
                  cursor,
                  paletteMatches: newMatches,
                  paletteIndex: paletteIndex,
                );
              }
              break;

            case ControlCharacter.tab:
              // If command palette is open, Tab selects the highlighted command
              if (paletteMatches.isNotEmpty) {
                breakSilence();
                final selectedCmd = paletteMatches[paletteIndex].command;
                buffer = '$selectedCmd ';
                cursor = buffer.length;
                paletteIndex = 0;
                _publishDraft(buffer);
                _repaint(prompt, buffer, cursor);
              } else {
                // File completion
                final completion = _tryComplete(buffer, cursor);
                if (completion != null) {
                  breakSilence();
                  buffer = completion.newBuffer;
                  cursor = completion.newCursor;
                  if (completion.previewOptions != null &&
                      completion.previewOptions!.isNotEmpty) {
                    _showCompletionPreview(
                      prompt,
                      buffer,
                      cursor,
                      completion.previewOptions!,
                    );
                  } else {
                    _publishDraft(buffer);
                    _repaint(prompt, buffer, cursor);
                  }
                }
              }
              break;

            default:
              final action = keyBindings.match(key);
              if (action != null) {
                switch (action) {
                  case KeyAction.thinkingCycle:
                    onThinkingCycle?.call();
                    _repaint(prompt, buffer, cursor);
                    break;
                  case KeyAction.sessionPicker:
                    onSessionPicker?.call();
                    break;
                  case KeyAction.modelCycle:
                    onModelCycle?.call();
                    _repaint(prompt, buffer, cursor);
                    break;
                  default:
                    break;
                }
              }
              break;
          }
        } else {
          // Printable character
          final char = key.char;
          if (char == '\x1B') {
            // Escape pressed: dismiss palette. During a turn Escape is the
            // interrupt gesture and reaches this reader only while an approval
            // prompt holds the keys, where it dismisses the palette and nothing
            // else (feel doctrine rule 7).
            _clearPalette();
            _repaint(prompt, buffer, cursor);
            continue;
          }

          if (char.isNotEmpty) {
            breakSilence();
            buffer =
                buffer.substring(0, cursor) + char + buffer.substring(cursor);
            cursor += char.length;
            paletteIndex = 0;

            final newMatches = buffer.startsWith('/') && !buffer.contains(' ')
                ? AutoCompleter.completeSlashInfo(buffer)
                : <SlashCommandInfo>[];
            _publishDraft(buffer);
            _repaint(
              prompt,
              buffer,
              cursor,
              paletteMatches: newMatches,
              paletteIndex: paletteIndex,
            );
          }
        }
      }
    } finally {
      _inReadLine = false;
      _isSilent = true;
      _isSuspended = false;
      TerminalManager.instance.isDrafting = false;
    }
  }

  /// Publishes the composing buffer where [TerminalManager.clearBuffer] cannot
  /// reach it, and tells the ambient line about it.
  void _publishDraft(String buffer) {
    TerminalManager.instance.draft = buffer;
    _currentBuffer = buffer;
    onCompose?.call(queued);
  }

  void _clearPalette([String? prompt, String? buffer]) {
    if (_paletteLines > 0) {
      if (ScreenCoordinator.instance.isActive) {
        ScreenCoordinator.instance.clearPromptArea();
        if (prompt != null && buffer != null) {
          _repaint(prompt, buffer, buffer.length);
        }
      } else {
        if (_cursorRow > 0) {
          _out('\x1B[${_cursorRow}A');
        }
        _out('\r\x1B[J');
        if (prompt != null && buffer != null) {
          _out('$prompt$buffer');
        }
      }
      _paletteLines = 0;
      _cursorRow = 0;
    }
  }

  void _repaint(
    String prompt,
    String buffer,
    int cursor, {
    List<SlashCommandInfo>? paletteMatches,
    int paletteIndex = 0,
  }) {
    _currentPrompt = prompt;
    _currentBuffer = buffer;
    _currentCursor = cursor;
    if (_isSuspended) return;
    final cols = _terminalCols;

    final end = cursorPosition(prompt, buffer, buffer.length, cols);
    final endRow = end.$1;

    final target = cursorPosition(prompt, buffer, cursor, cols);
    final targetRow = target.$1;
    final targetCol = target.$2;

    if (ScreenCoordinator.instance.isActive) {
      var extraLines = 0;
      List<SlashCommandInfo>? visibleMatches;
      int start = 0;
      if (paletteMatches != null && paletteMatches.isNotEmpty) {
        const maxShow = 6;
        start = (paletteIndex >= maxShow) ? (paletteIndex - maxShow + 1) : 0;
        visibleMatches = paletteMatches.skip(start).take(maxShow).toList();
        extraLines = visibleMatches.length + 4;
      }

      final neededLines = endRow + 1 + extraLines;
      ScreenCoordinator.instance.updatePromptLines(neededLines);
      ScreenCoordinator.instance.clearPromptArea();

      final promptStart = ScreenCoordinator.instance.promptStartRow;
      _out('\x1B[$promptStart;1H');

      final formattedBuffer = buffer
          .replaceAll('\r\n', '\n')
          .replaceAll('\n', '\r\n');
      _out('$prompt$formattedBuffer');

      if (visibleMatches != null && visibleMatches.isNotEmpty) {
        final theme = NibTheme.current;
        final paletteStartRow = promptStart + endRow + 1;
        _out('\x1B[$paletteStartRow;1H');
        _out(
          '  ${theme.muted.text('╭──')} ${theme.accent.text('Commands')} ${theme.muted.text('─' * 20)}\r\n',
        );

        for (int i = 0; i < visibleMatches.length; i++) {
          final actualIndex = start + i;
          final cmd = visibleMatches[i];
          final pointer = actualIndex == paletteIndex
              ? theme.accent.text('▸')
              : ' ';
          final cmdName = cmd.command.padRight(10);
          final desc = cmd.description;
          final truncatedDesc = desc.length > 44
              ? '${desc.substring(0, 41)}...'
              : desc;

          if (actualIndex == paletteIndex) {
            _out(
              '    $pointer ${Ansi.boldText(theme.accent.text(cmdName))} ${theme.surface.bg}${theme.accent.text(" $truncatedDesc ")}\x1B[0m\r\n',
            );
          } else {
            _out(
              '    $pointer ${theme.secondary.text(cmdName)} ${theme.muted.text(truncatedDesc)}\r\n',
            );
          }
        }

        _out('  ${theme.muted.text('╰──${'─' * 35}')}\r\n');
        _out(
          '  ${theme.muted.text('↑/↓ navigate  Tab/Enter select  Esc dismiss')}',
        );
      }

      ScreenCoordinator.instance.positionPromptCursor(targetRow, targetCol + 1);
      _cursorRow = targetRow;
      _paletteLines = extraLines;
      return;
    }

    // 1. Return cursor back up to the prompt start row
    if (_cursorRow > 0) {
      _out('\x1B[${_cursorRow}A');
    }

    // 2. Clear from beginning of prompt line down to bottom of screen
    _out('\r\x1B[J');

    // 3. Print prompt and buffer, then clear the rest of the line it ends on. The
    // prompt row is ours, and without this a wider previous render — an ambient
    // row, or a longer draft before an edit — leaves fragments to the right.
    _out('$prompt$buffer\x1B[K');

    var extraLines = 0;

    // 5. If command palette is active, render palette directly below prompt line
    if (paletteMatches != null && paletteMatches.isNotEmpty) {
      final theme = NibTheme.current;
      const maxShow = 6;
      final start = (paletteIndex >= maxShow)
          ? (paletteIndex - maxShow + 1)
          : 0;
      final visibleMatches = paletteMatches.skip(start).take(maxShow).toList();

      _out('\n');
      _out(
        '  ${theme.muted.text('╭──')} ${theme.accent.text('Commands')} ${theme.muted.text('─' * 20)}\n',
      );
      extraLines += 2;

      for (int i = 0; i < visibleMatches.length; i++) {
        final actualIndex = start + i;
        final cmd = visibleMatches[i];
        final pointer = actualIndex == paletteIndex
            ? theme.accent.text('▸')
            : ' ';
        final cmdName = cmd.command.padRight(10);
        final desc = cmd.description;
        final truncatedDesc = desc.length > 44
            ? '${desc.substring(0, 41)}...'
            : desc;

        if (actualIndex == paletteIndex) {
          _out(
            '    $pointer ${Ansi.boldText(theme.accent.text(cmdName))} ${theme.surface.bg}${theme.accent.text(" $truncatedDesc ")}\x1B[0m\n',
          );
        } else {
          _out(
            '    $pointer ${theme.secondary.text(cmdName)} ${theme.muted.text(truncatedDesc)}\n',
          );
        }
        extraLines++;
      }

      _out('  ${theme.muted.text('╰──${'─' * 35}')}\n');
      _out(
        '  ${theme.muted.text('↑/↓ navigate  Tab/Enter select  Esc dismiss')}',
      );
      extraLines += 2;

      _paletteLines = extraLines;

      // Move cursor back up to prompt row
      _out('\x1B[${extraLines}A');
    } else {
      _paletteLines = 0;
    }

    // 6. Move cursor vertically up to target row if needed
    if (endRow > targetRow) {
      _out('\x1B[${endRow - targetRow}A');
    }

    // 7. Move cursor horizontally to target column
    _out('\r');
    if (targetCol > 0) {
      _out('\x1B[${targetCol}C');
    }

    // 8. Update tracked cursor row
    _cursorRow = targetRow;
  }

  void _showCompletionPreview(
    String prompt,
    String buffer,
    int cursor,
    List<String> options,
  ) {
    final cols = _terminalCols;
    final endRow = cursorPosition(prompt, buffer, buffer.length, cols).$1;
    if (endRow > _cursorRow) {
      _out('\x1B[${endRow - _cursorRow}B');
    }
    _out('\n');
    final theme = NibTheme.current;
    _out(
      '  ${theme.muted.text('Suggestions:')} ${options.map((o) => theme.accent.text(o)).join(theme.muted.text('  '))}\n',
    );
    _out(prompt + buffer);
    _cursorRow = endRow;
    _repaint(prompt, buffer, cursor);
  }

  _CompletionResult? _tryComplete(String buffer, int cursor) {
    final textBefore = buffer.substring(0, cursor);

    // 1. Slash command completion: if text starts with '/'
    if (textBefore.startsWith('/')) {
      final matches = AutoCompleter.completeSlash(textBefore);
      if (matches.length == 1) {
        final completed = '${matches.first} ';
        final newBuffer = completed + buffer.substring(cursor);
        return _CompletionResult(
          newBuffer: newBuffer,
          newCursor: completed.length,
        );
      } else if (matches.length > 1) {
        final common = _commonPrefix(matches);
        final newBuffer = common + buffer.substring(cursor);
        return _CompletionResult(
          newBuffer: newBuffer,
          newCursor: common.length,
          previewOptions: matches,
        );
      }
      return null;
    }

    // 2. @file mention completion
    final lastAt = textBefore.lastIndexOf('@');
    if (lastAt != -1 && !textBefore.substring(lastAt).contains(' ')) {
      final query = textBefore.substring(lastAt);
      final matches = AutoCompleter.completeFile(query);
      if (matches.length == 1) {
        final replacement = '${matches.first} ';
        final newBuffer =
            buffer.substring(0, lastAt) +
            replacement +
            buffer.substring(cursor);
        final newCursor = lastAt + replacement.length;
        return _CompletionResult(newBuffer: newBuffer, newCursor: newCursor);
      } else if (matches.length > 1) {
        final common = _commonPrefix(matches);
        final newBuffer =
            buffer.substring(0, lastAt) + common + buffer.substring(cursor);
        final newCursor = lastAt + common.length;
        return _CompletionResult(
          newBuffer: newBuffer,
          newCursor: newCursor,
          previewOptions: matches,
        );
      }
    }

    return null;
  }

  static String _commonPrefix(List<String> list) {
    if (list.isEmpty) return '';
    var prefix = list.first;
    for (int i = 1; i < list.length; i++) {
      while (!list[i].startsWith(prefix)) {
        prefix = prefix.substring(0, prefix.length - 1);
        if (prefix.isEmpty) return '';
      }
    }
    return prefix;
  }
}

class _CompletionResult {
  final String newBuffer;
  final int newCursor;
  final List<String>? previewOptions;

  _CompletionResult({
    required this.newBuffer,
    required this.newCursor,
    this.previewOptions,
  });
}
