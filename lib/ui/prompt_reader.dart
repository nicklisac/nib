import 'dart:io';
import 'dart:math';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;
import 'ansi.dart';
import 'autocomplete.dart';
import 'terminal_manager.dart';
import 'theme.dart';

/// Interactive terminal prompt reader supporting persistent history, live command palette,
/// and Tab completion.
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

  int _cursorRow = 0;
  int _paletteLines = 0;

  /// Reads a line from terminal stdin with live command palette when typing `/`.
  Future<String?> readLine({required String prompt}) async {
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
    _paletteLines = 0;
    var paletteIndex = 0;

    while (true) {
      final key = await TerminalManager.instance.nextKey();

      // Check if command palette is active
      final isSlashCommandMode = buffer.startsWith('/') && !buffer.contains(' ');
      final paletteMatches = isSlashCommandMode ? AutoCompleter.completeSlashInfo(buffer) : <SlashCommandInfo>[];

      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.enter:
            // If palette is open and user pressed enter on a partial match
            if (paletteMatches.isNotEmpty && buffer.length < paletteMatches[paletteIndex].command.length) {
              final selectedCmd = paletteMatches[paletteIndex].command;
              if (selectedCmd == '/theme' || selectedCmd == '/provider' || selectedCmd == '/model' || selectedCmd == '/compact') {
                buffer = '$selectedCmd ';
                cursor = buffer.length;
                paletteIndex = 0;
                _repaint(prompt, buffer, cursor);
                continue;
              } else {
                buffer = selectedCmd;
              }
            }

            _clearPalette(prompt, buffer);
            stdout.writeln();
            _cursorRow = 0;
            _paletteLines = 0;
            final result = buffer.trim();
            if (result.isNotEmpty) {
              addToHistory(result);
            }
            return buffer;

          case ControlCharacter.ctrlC:
            _clearPalette();
            if (buffer.isNotEmpty) {
              if (_cursorRow > 0) {
                stdout.write('\x1B[${_cursorRow}A');
              }
              stdout.write('\r\x1B[J$prompt');
              buffer = '';
              cursor = 0;
              _cursorRow = 0;
              _paletteLines = 0;
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
            if (paletteMatches.isNotEmpty) {
              // Navigate command palette upward
              paletteIndex = (paletteIndex - 1 + paletteMatches.length) % paletteMatches.length;
              _repaint(prompt, buffer, cursor, paletteMatches: paletteMatches, paletteIndex: paletteIndex);
            } else if (_history.isNotEmpty) {
              // Recall older history entry (Tau-style)
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
            if (paletteMatches.isNotEmpty) {
              // Navigate command palette downward
              paletteIndex = (paletteIndex + 1) % paletteMatches.length;
              _repaint(prompt, buffer, cursor, paletteMatches: paletteMatches, paletteIndex: paletteIndex);
            } else if (_historyIndex > 0) {
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
              _repaint(prompt, buffer, cursor, paletteMatches: paletteMatches, paletteIndex: paletteIndex);
            }
            break;

          case ControlCharacter.arrowRight:
            if (cursor < buffer.length) {
              cursor++;
              _repaint(prompt, buffer, cursor, paletteMatches: paletteMatches, paletteIndex: paletteIndex);
            }
            break;

          case ControlCharacter.home:
          case ControlCharacter.ctrlA:
            cursor = 0;
            _repaint(prompt, buffer, cursor, paletteMatches: paletteMatches, paletteIndex: paletteIndex);
            break;

          case ControlCharacter.end:
          case ControlCharacter.ctrlE:
            cursor = buffer.length;
            _repaint(prompt, buffer, cursor, paletteMatches: paletteMatches, paletteIndex: paletteIndex);
            break;

          case ControlCharacter.backspace:
          case ControlCharacter.ctrlH:
            if (cursor > 0) {
              buffer = buffer.substring(0, cursor - 1) + buffer.substring(cursor);
              cursor--;
              paletteIndex = 0;
              final newMatches = buffer.startsWith('/') && !buffer.contains(' ')
                  ? AutoCompleter.completeSlashInfo(buffer)
                  : <SlashCommandInfo>[];
              _repaint(prompt, buffer, cursor, paletteMatches: newMatches, paletteIndex: paletteIndex);
            }
            break;

          case ControlCharacter.delete:
            if (cursor < buffer.length) {
              buffer = buffer.substring(0, cursor) + buffer.substring(cursor + 1);
              final newMatches = buffer.startsWith('/') && !buffer.contains(' ')
                  ? AutoCompleter.completeSlashInfo(buffer)
                  : <SlashCommandInfo>[];
              _repaint(prompt, buffer, cursor, paletteMatches: newMatches, paletteIndex: paletteIndex);
            }
            break;

          case ControlCharacter.tab:
            // If command palette is open, Tab selects the highlighted command
            if (paletteMatches.isNotEmpty) {
              final selectedCmd = paletteMatches[paletteIndex].command;
              buffer = '$selectedCmd ';
              cursor = buffer.length;
              paletteIndex = 0;
              _repaint(prompt, buffer, cursor);
            } else {
              // File completion
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
            }
            break;

          default:
            break;
        }
      } else {
        // Printable character
        final char = key.char;
        if (char == '\x1B') {
          // Escape pressed: dismiss palette
          _clearPalette();
          _repaint(prompt, buffer, cursor);
          continue;
        }

        if (char.isNotEmpty) {
          buffer = buffer.substring(0, cursor) + char + buffer.substring(cursor);
          cursor += char.length;
          paletteIndex = 0;

          final newMatches = buffer.startsWith('/') && !buffer.contains(' ')
              ? AutoCompleter.completeSlashInfo(buffer)
              : <SlashCommandInfo>[];
          _repaint(prompt, buffer, cursor, paletteMatches: newMatches, paletteIndex: paletteIndex);
        }
      }
    }
  }

  void _clearPalette([String? prompt, String? buffer]) {
    if (_paletteLines > 0) {
      if (_cursorRow > 0) {
        stdout.write('\x1B[${_cursorRow}A');
      }
      stdout.write('\r\x1B[J');
      if (prompt != null && buffer != null) {
        stdout.write('$prompt$buffer');
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
    final cols = _terminalCols;
    final promptLen = visibleWidth(prompt);

    // 1. Return cursor back up to the prompt start row
    if (_cursorRow > 0) {
      stdout.write('\x1B[${_cursorRow}A');
    }

    // 2. Clear from beginning of prompt line down to bottom of screen
    stdout.write('\r\x1B[J');

    // 3. Print prompt and buffer
    stdout.write('$prompt$buffer');

    // 4. Calculate where cursor ended up on prompt
    final totalLen = promptLen + buffer.length;
    final endRow = totalLen ~/ cols;

    final targetOffset = promptLen + cursor;
    final targetRow = targetOffset ~/ cols;
    final targetCol = targetOffset % cols;

    var extraLines = 0;

    // 5. If command palette is active, render palette directly below prompt line
    if (paletteMatches != null && paletteMatches.isNotEmpty) {
      final theme = NibTheme.current;
      const maxShow = 6;
      final start = (paletteIndex >= maxShow) ? (paletteIndex - maxShow + 1) : 0;
      final visibleMatches = paletteMatches.skip(start).take(maxShow).toList();

      stdout.writeln();
      stdout.writeln('  ${theme.muted.text('╭─')} ${theme.accent.text('Commands')} ${theme.muted.text('──────────────────────────────────────────────╮')}');
      extraLines += 2;

      for (int i = 0; i < visibleMatches.length; i++) {
        final actualIndex = start + i;
        final cmd = visibleMatches[i];
        final isSelected = actualIndex == paletteIndex;
        final pointer = isSelected ? theme.accent.text('▸') : ' ';
        final cmdName = cmd.command.padRight(10);
        final desc = cmd.description;
        final truncatedDesc = desc.length > 44 ? '${desc.substring(0, 41)}...' : desc;

        if (isSelected) {
          stdout.writeln('  ${theme.muted.text('│')} $pointer ${Ansi.boldText(theme.accent.text(cmdName))} ${theme.surface.bg}${theme.accent.text(" $truncatedDesc ")}\x1B[0m');
        } else {
          stdout.writeln('  ${theme.muted.text('│')} $pointer ${theme.secondary.text(cmdName)} ${theme.muted.text(truncatedDesc)}');
        }
        extraLines++;
      }

      stdout.writeln('  ${theme.muted.text('╰────────────────────────────────────────────────────────────╯')}');
      stdout.write('  ${theme.muted.text('↑/↓ navigate  Tab/Enter select  Esc dismiss')}');
      extraLines += 2;

      _paletteLines = extraLines;

      // Move cursor back up to prompt row
      stdout.write('\x1B[${extraLines}A');
    } else {
      _paletteLines = 0;
    }

    // 6. Move cursor vertically up to target row if needed
    if (endRow > targetRow) {
      stdout.write('\x1B[${endRow - targetRow}A');
    }

    // 7. Move cursor horizontally to target column
    stdout.write('\r');
    if (targetCol > 0) {
      stdout.write('\x1B[${targetCol}C');
    }

    // 8. Update tracked cursor row
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
