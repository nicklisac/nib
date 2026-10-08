import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../agent/session.dart';
import 'theme.dart';

/// Interactive arrow-key navigation session picker for resuming saved conversations.
class SessionPicker {
  static final Console _console = Console();

  /// Prompts the user to pick a saved conversation session using an interactive menu.
  static Future<String?> pickSession({
    AgentSession? currentSession,
    int limit = 10,
  }) async {
    final sessions = await AgentSession.listSavedSessions();
    if (sessions.isEmpty) {
      final theme = NibTheme.current;
      stdout.writeln(theme.warning.text('  No saved sessions found across ~/.nib/sessions or ~/.tau/sessions.'));
      return null;
    }

    if (!stdin.hasTerminal) {
      // Non-interactive fallback: return the most recent session
      return sessions.first['id'] as String?;
    }

    final items = sessions.take(limit).toList();
    var selectedIndex = 0;
    final theme = NibTheme.current;

    // Initial render
    _renderMenu(items, selectedIndex, currentSession?.id, theme);

    while (true) {
      final key = _console.readKey();

      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
            selectedIndex = (selectedIndex - 1 + items.length) % items.length;
            _clearMenu(items.length);
            _renderMenu(items, selectedIndex, currentSession?.id, theme);
            break;

          case ControlCharacter.arrowDown:
            selectedIndex = (selectedIndex + 1) % items.length;
            _clearMenu(items.length);
            _renderMenu(items, selectedIndex, currentSession?.id, theme);
            break;

          case ControlCharacter.enter:
            _clearMenu(items.length);
            final chosen = items[selectedIndex]['id'] as String;
            return chosen;

          case ControlCharacter.ctrlC:
            _clearMenu(items.length);
            stdout.writeln(theme.muted.text('  Cancelled session selection.'));
            return null;

          default:
            break;
        }
      } else {
        final char = key.char;
        if (char == 'q' || char == 'Q' || key.char == '\x1B') {
          _clearMenu(items.length);
          stdout.writeln(theme.muted.text('  Cancelled session selection.'));
          return null;
        }

        // Direct number selection (1-9)
        final numVal = int.tryParse(char);
        if (numVal != null && numVal >= 1 && numVal <= items.length) {
          _clearMenu(items.length);
          final chosen = items[numVal - 1]['id'] as String;
          return chosen;
        }
      }
    }
  }

  static void _renderMenu(
    List<Map<String, dynamic>> items,
    int selected,
    String? currentId,
    NibTheme theme,
  ) {
    stdout.writeln();
    stdout.writeln('  ${theme.muted.text('╭─')} ${theme.accent.text('Select Session to Resume')} ${theme.muted.text('─────────────────────────────────────────╮')}');

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final id = item['id'] as String;
      final turns = item['user_turns'] as int;
      final preview = item['last_prompt'] as String;
      final modified = item['modified'] as DateTime?;
      final dateStr = modified != null ? _formatDate(modified) : '';
      final isCurrent = id == currentId;
      final isSelected = i == selected;

      final pointer = isSelected ? theme.accent.text('▸') : ' ';
      final indexStr = theme.secondary.text('[${i + 1}]');
      final turnsStr = theme.muted.text('($turns turns)');
      final previewStr = preview.isNotEmpty ? preview : '(empty)';
      final currentTag = isCurrent ? ' ${theme.success.text('[active]')}' : '';

      final truncatedPreview = previewStr.length > 34 ? '${previewStr.substring(0, 31)}...' : previewStr;

      if (isSelected) {
        stdout.writeln('  ${theme.muted.text('│')} $pointer $indexStr ${theme.accent.text(dateStr)} $turnsStr ${theme.surface.bg}${theme.accent.text(" $truncatedPreview ")}\x1B[0m$currentTag');
      } else {
        stdout.writeln('  ${theme.muted.text('│')} $pointer $indexStr ${theme.muted.text(dateStr)} $turnsStr ${theme.primary.text(truncatedPreview)}$currentTag');
      }
    }

    stdout.writeln('  ${theme.muted.text('╰─────────────────────────────────────────────────────────────────╯')}');
    stdout.writeln('  ${theme.muted.text('Use ↑/↓ arrows to navigate, Enter to load, 1-${items.length} to select, Esc/q to cancel')}');
  }

  static void _clearMenu(int itemCount) {
    // Menu takes: 1 top blank + 1 top border + itemCount rows + 1 bottom border + 1 hint line = itemCount + 4 lines
    final totalLines = itemCount + 4;
    stdout.write('\x1B[${totalLines}A');
    stdout.write('\r\x1B[J');
  }

  static String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inDays == 0 && dt.day == now.day) {
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return 'Today $hour:$min';
    } else if (diff.inDays <= 1) {
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return 'Yesterday $hour:$min';
    } else {
      final month = dt.month.toString().padLeft(2, '0');
      final day = dt.day.toString().padLeft(2, '0');
      final hour = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return '$month-$day $hour:$min';
    }
  }
}
