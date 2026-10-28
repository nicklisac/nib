import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../agent/config.dart';
import 'terminal_manager.dart';
import 'theme.dart';
import 'transcript_writer.dart';

/// Interactive arrow-key navigation menu for browsing and toggling experimental features.
class ExperimentPicker {
  /// Opens the interactive experiments menu.
  ///
  /// [isEnabled] returns the live state of an experiment by ID, and [onToggle]
  /// flips it in-session. Returns the list of experiment IDs that were toggled
  /// during the menu interaction, or `null` if cancelled without changes.
  static Future<List<String>?> pickExperiments({
    required bool Function(String id) isEnabled,
    required Future<void> Function(String id) onToggle,
    TranscriptWriter? writer,
    Future<Key> Function()? nextKey,
  }) async {
    final out = resolveTranscriptWriter(writer);
    final items = NibConfig.knownExperiments;
    if (items.isEmpty) return const [];

    if (!stdin.hasTerminal && nextKey == null) {
      return null;
    }

    var selectedIndex = 0;
    final toggledIds = <String>[];

    _renderMenu(items, selectedIndex, isEnabled, out);

    while (true) {
      final key = nextKey != null
          ? await nextKey()
          : await TerminalManager.instance.nextKey();

      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
            selectedIndex = (selectedIndex - 1 + items.length) % items.length;
            _clearMenu(items.length, out);
            _renderMenu(items, selectedIndex, isEnabled, out);
            break;

          case ControlCharacter.arrowDown:
            selectedIndex = (selectedIndex + 1) % items.length;
            _clearMenu(items.length, out);
            _renderMenu(items, selectedIndex, isEnabled, out);
            break;

          case ControlCharacter.enter:
            // If the user hasn't toggled anything with Space yet, Enter toggles
            // the highlighted item and exits immediately (1-keystroke flow).
            if (toggledIds.isEmpty) {
              final targetId = items[selectedIndex].id;
              await onToggle(targetId);
              toggledIds.add(targetId);
            }
            _clearMenu(items.length, out);
            return toggledIds;

          case ControlCharacter.escape:
          case ControlCharacter.ctrlC:
            _clearMenu(items.length, out);
            return toggledIds.isEmpty ? null : toggledIds;

          default:
            break;
        }
      } else {
        final char = key.char;
        if (char == 'q' || char == 'Q' || char == '\x1B') {
          _clearMenu(items.length, out);
          return toggledIds.isEmpty ? null : toggledIds;
        }

        if (char == ' ') {
          final targetId = items[selectedIndex].id;
          await onToggle(targetId);
          toggledIds.add(targetId);
          _clearMenu(items.length, out);
          _renderMenu(items, selectedIndex, isEnabled, out);
          continue;
        }

        final digit = int.tryParse(char);
        if (digit != null && digit >= 1 && digit <= items.length) {
          selectedIndex = digit - 1;
          final targetId = items[selectedIndex].id;
          await onToggle(targetId);
          toggledIds.add(targetId);
          _clearMenu(items.length, out);
          _renderMenu(items, selectedIndex, isEnabled, out);
        }
      }
    }
  }

  static void _renderMenu(
    List<ExperimentSpec> items,
    int selected,
    bool Function(String id) isEnabled,
    TranscriptWriter out,
  ) {
    final theme = NibTheme.current;
    out.writeLine('');
    out.writeLine(
      '  ${theme.muted.text('╭──')} ${theme.accent.text('Experimental Features')} ${theme.muted.text('─' * 22)}',
    );

    for (int i = 0; i < items.length; i++) {
      final exp = items[i];
      final isSelected = i == selected;
      final active = isEnabled(exp.id);

      final pointer = isSelected ? theme.accent.text('▸') : ' ';
      final numStr = theme.secondary.text('[${(i + 1).toString().padLeft(2)}]');
      final badge = active
          ? theme.success.text('[enabled] ')
          : theme.muted.text('[disabled]');
      final nameStr = exp.id.padRight(16);

      if (isSelected) {
        out.writeLine(
          '    $pointer $numStr $badge ${theme.surface.bg}${theme.accent.text(" $nameStr ")}\x1B[0m ${theme.muted.text(exp.description)}',
        );
      } else {
        out.writeLine(
          '    $pointer $numStr $badge ${theme.primary.text(" $nameStr ")} ${theme.muted.text(exp.description)}',
        );
      }
    }

    out.writeLine('  ${theme.muted.text('╰──${'─' * 43}')}');
    out.writeLine(
      '  ${theme.muted.text('Use ↑/↓ to navigate, Space/1-${items.length} to toggle, Enter to confirm, Esc/q to close')}',
    );
  }

  static void _clearMenu(int itemCount, TranscriptWriter out) {
    // Menu lines: 1 top empty + 1 header + items.length + 1 footer + 1 hint = items.length + 4
    final totalLines = itemCount + 4;
    out.rewind(totalLines);
  }
}
