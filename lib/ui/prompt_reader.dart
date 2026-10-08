import 'dart:io';
import 'dart:math';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;
import 'autocomplete.dart';
import 'theme.dart';

/// Interactive terminal prompt reader supporting persistent history, Up/Down recall, and Tab completion.
class PromptReader {
  final Console _console = Console();
  final List<String> _history = [];
  int _historyIndex = -1;
  String _savedDraft = '';
  late final File _historyFile;

  PromptReader() {
    _initHistoryFile();
  }

  void _initHistoryFile() {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        final dir = Directory(p.join(home, '.nib'));
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        _historyFile = File(p.join(dir.path, 'history'));
        if (_historyFile.existsSync()) {
          final lines = _historyFile.readAsLinesSync();
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty) {
              _history.add(trimmed);
            }
          }
          // Cap in-memory history to last 1000 entries
          if (_history.length > 1000) {
            _history.removeRange(0, _history.length - 1000);
          }
        }
      }
    } catch (_) {}
  }

  /// Appends a new prompt to history and persists to disk.
  void addToHistory(String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;

    // Do not duplicate immediate last entry
    if (_history.isNotEmpty && _history.last == trimmed) return;

    _history.add(trimmed);
    try {
      _historyFile.writeAsStringSync('$trimmed\n', mode: FileMode.append);
    } catch (_) {}
  }

  int _cursorRow = 0;

  static int visibleWidth(String text) {
    return text.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '').length;
  }

  int get _terminalCols =>
      (stdout.hasTerminal && stdout.terminalColumns > 0) ? stdout.terminalColumns : 80;

  /// Reads a line with interactive editing, history cycling, and Tab completions.
  String? readLine({required String prompt}) {
    if (!stdin.hasTerminal) {
      stdout.write(prompt);
      return stdin.readLineSync();
    }

    stdout.write(prompt);
    var buffer = '';
    var cursor = 0;
    _historyIndex = -1;
    _savedDraft = '';
    _cursorRow = 0;

    while (true) {
      final key = _console.readKey();

      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.enter:
            final cols = _terminalCols;
            final promptLen = visibleWidth(prompt);
            final endRow = (promptLen + buffer.length) ~/ cols;
            if (endRow > _cursorRow) {
              stdout.write('\x1B[${endRow - _cursorRow}B');
            }
            stdout.writeln();
            _cursorRow = 0;
            final result = buffer.trim();
            if (result.isNotEmpty) {
              addToHistory(result);
            }
            return buffer;

          case ControlCharacter.ctrlC:
            if (buffer.isNotEmpty) {
              if (_cursorRow > 0) {
                stdout.write('\x1B[${_cursorRow}A');
              }
              stdout.write('\r\x1B[J$prompt');
              buffer = '';
              cursor = 0;
              _cursorRow = 0;
              continue;
            } else {
              return null;
            }

          case ControlCharacter.ctrlD:
            if (buffer.isEmpty) {
              return null;
            }
            break;

          case ControlCharacter.arrowUp:
            // Recall older history entry (Tau-style)
            if (_history.isNotEmpty) {
              if (_historyIndex == -1) {
                _savedDraft = buffer;
              }
              if (_historyIndex < _history.length - 1) {
                _historyIndex++;
                buffer = _history[_history.length - 1 - _historyIndex];
                cursor = buffer.length;
                _repaint(prompt, buffer, cursor);
              }
            }
            break;

          case ControlCharacter.arrowDown:
            // Move toward newer history entry or back to draft
            if (_historyIndex > 0) {
              _historyIndex--;
              buffer = _history[_history.length - 1 - _historyIndex];
              cursor = buffer.length;
              _repaint(prompt, buffer, cursor);
            } else if (_historyIndex == 0) {
              _historyIndex = -1;
              buffer = _savedDraft;
              cursor = buffer.length;
              _repaint(prompt, buffer, cursor);
            }
            break;

          case ControlCharacter.arrowLeft:
            if (cursor > 0) {
              cursor--;
              _repaint(prompt, buffer, cursor);
            }
            break;

          case ControlCharacter.arrowRight:
            if (cursor < buffer.length) {
              cursor++;
              _repaint(prompt, buffer, cursor);
            }
            break;

          case ControlCharacter.home:
          case ControlCharacter.ctrlA:
            cursor = 0;
            _repaint(prompt, buffer, cursor);
            break;

          case ControlCharacter.end:
          case ControlCharacter.ctrlE:
            cursor = buffer.length;
            _repaint(prompt, buffer, cursor);
            break;

          case ControlCharacter.backspace:
          case ControlCharacter.ctrlH:
            if (cursor > 0) {
              buffer = buffer.substring(0, cursor - 1) + buffer.substring(cursor);
              cursor--;
              _repaint(prompt, buffer, cursor);
            }
            break;

          case ControlCharacter.delete:
            if (cursor < buffer.length) {
              buffer = buffer.substring(0, cursor) + buffer.substring(cursor + 1);
              _repaint(prompt, buffer, cursor);
            }
            break;

          case ControlCharacter.tab:
            // Handle auto-completion
            final completion = _tryComplete(buffer, cursor);
            if (completion != null) {
              buffer = completion.newBuffer;
              cursor = completion.newCursor;
              if (completion.previewOptions != null && completion.previewOptions!.isNotEmpty) {
                _showCompletionPreview(prompt, buffer, cursor, completion.previewOptions!);
              } else {
                _repaint(prompt, buffer, cursor);
              }
            }
            break;

          default:
            break;
        }
      } else {
        // Printable character
        final char = key.char;
        if (char.isNotEmpty) {
          buffer = buffer.substring(0, cursor) + char + buffer.substring(cursor);
          cursor += char.length;
          _repaint(prompt, buffer, cursor);
        }
      }
    }
  }

  void _repaint(String prompt, String buffer, int cursor) {
    final cols = _terminalCols;
    final promptLen = visibleWidth(prompt);

    // 1. Return cursor back up to the prompt start row
    if (_cursorRow > 0) {
      stdout.write('\x1B[${_cursorRow}A');
    }

    // 2. Clear from beginning of prompt line down to bottom of screen
    stdout.write('\r\x1B[J');

    // 3. Print prompt and buffer (wraps naturally)
    stdout.write('$prompt$buffer');

    // 4. Calculate where cursor ended up vs where it should be
    final totalLen = promptLen + buffer.length;
    final endRow = totalLen ~/ cols;

    final targetOffset = promptLen + cursor;
    final targetRow = targetOffset ~/ cols;
    final targetCol = targetOffset % cols;

    // 5. Move cursor vertically up to target row if needed
    if (endRow > targetRow) {
      stdout.write('\x1B[${endRow - targetRow}A');
    }

    // 6. Move cursor horizontally to target column
    stdout.write('\r');
    if (targetCol > 0) {
      stdout.write('\x1B[${targetCol}C');
    }

    // 7. Update tracked cursor row
    _cursorRow = targetRow;
  }

  void _showCompletionPreview(String prompt, String buffer, int cursor, List<String> options) {
    final cols = _terminalCols;
    final promptLen = visibleWidth(prompt);
    final endRow = (promptLen + buffer.length) ~/ cols;
    if (endRow > _cursorRow) {
      stdout.write('\x1B[${endRow - _cursorRow}B');
    }
    stdout.writeln();
    final theme = NibTheme.current;
    stdout.writeln('  ${theme.muted.text('Suggestions:')} ${options.map((o) => theme.accent.text(o)).join(theme.muted.text('  '))}');
    stdout.write(prompt + buffer);
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
        return _CompletionResult(newBuffer: newBuffer, newCursor: completed.length);
      } else if (matches.length > 1) {
        // Find longest common prefix
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
        final newBuffer = buffer.substring(0, lastAt) + replacement + buffer.substring(cursor);
        final newCursor = lastAt + replacement.length;
        return _CompletionResult(newBuffer: newBuffer, newCursor: newCursor);
      } else if (matches.length > 1) {
        final common = _commonPrefix(matches);
        final newBuffer = buffer.substring(0, lastAt) + common + buffer.substring(cursor);
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
