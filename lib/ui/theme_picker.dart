import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'terminal_manager.dart';
import 'theme.dart';
import 'transcript_writer.dart';

/// Interactive arrow-key navigation menu for browsing and selecting TrueColor themes.
class ThemePicker {
  static Future<String?> pickTheme({
    NibTheme? currentTheme,
    TranscriptWriter? writer,
    void Function(NibTheme theme)? onPreview,
    Future<Key> Function()? nextKey,
  }) async {
    final out = resolveTranscriptWriter(writer);
    final initialTheme = currentTheme ?? NibTheme.current;

    final uniqueThemes = <String, NibTheme>{};
    for (final theme in NibTheme.allThemes.values) {
      uniqueThemes.putIfAbsent(theme.id, () => theme);
    }
    final items = uniqueThemes.values.toList();

    if (!stdin.hasTerminal && nextKey == null) {
      return initialTheme.id;
    }

    var selectedIndex = items.indexWhere((t) => t.id == initialTheme.id);
    if (selectedIndex < 0) selectedIndex = 0;

    var activePreview = items[selectedIndex];
    NibTheme.current = activePreview;
    onPreview?.call(activePreview);

    // Initial render
    _renderMenu(items, selectedIndex, initialTheme, activePreview, out);

    var numericBuffer = '';

    while (true) {
      final key = nextKey != null
          ? await nextKey()
          : await TerminalManager.instance.nextKey();

      if (key.isControl) {
        numericBuffer = '';
        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
            selectedIndex = (selectedIndex - 1 + items.length) % items.length;
            activePreview = items[selectedIndex];
            NibTheme.current = activePreview;
            onPreview?.call(activePreview);
            _clearMenu(items.length, out);
            _renderMenu(items, selectedIndex, initialTheme, activePreview, out);
            break;

          case ControlCharacter.arrowDown:
            selectedIndex = (selectedIndex + 1) % items.length;
            activePreview = items[selectedIndex];
            NibTheme.current = activePreview;
            onPreview?.call(activePreview);
            _clearMenu(items.length, out);
            _renderMenu(items, selectedIndex, initialTheme, activePreview, out);
            break;

          case ControlCharacter.enter:
            _clearMenu(items.length, out);
            final chosen = items[selectedIndex];
            NibTheme.current = chosen;
            return chosen.id;

          case ControlCharacter.ctrlC:
            _clearMenu(items.length, out);
            NibTheme.current = initialTheme;
            onPreview?.call(initialTheme);
            return null;

          default:
            break;
        }
      } else {
        final char = key.char;
        if (char == 'q' || char == 'Q' || char == '\x1B') {
          _clearMenu(items.length, out);
          NibTheme.current = initialTheme;
          onPreview?.call(initialTheme);
          return null;
        }

        final digit = int.tryParse(char);
        if (digit != null) {
          numericBuffer += char;
          final numVal = int.tryParse(numericBuffer);
          if (numVal != null && numVal >= 1 && numVal <= items.length) {
            // If the buffer could be extended (e.g. '1' when there are 14 items),
            // select the target item and preview it live.
            final targetIdx = numVal - 1;
            selectedIndex = targetIdx;
            activePreview = items[selectedIndex];
            NibTheme.current = activePreview;
            onPreview?.call(activePreview);
            _clearMenu(items.length, out);
            _renderMenu(items, selectedIndex, initialTheme, activePreview, out);
          } else {
            numericBuffer = char;
            final singleVal = int.tryParse(char);
            if (singleVal != null &&
                singleVal >= 1 &&
                singleVal <= items.length) {
              selectedIndex = singleVal - 1;
              activePreview = items[selectedIndex];
              NibTheme.current = activePreview;
              onPreview?.call(activePreview);
              _clearMenu(items.length, out);
              _renderMenu(
                items,
                selectedIndex,
                initialTheme,
                activePreview,
                out,
              );
            }
          }
        } else {
          numericBuffer = '';
        }
      }
    }
  }

  static void _renderMenu(
    List<NibTheme> items,
    int selected,
    NibTheme activeTheme,
    NibTheme previewTheme,
    TranscriptWriter out,
  ) {
    out.writeLine('');
    out.writeLine(
      '  ${previewTheme.muted.text('╭──')} ${previewTheme.accent.text('Select Theme')} ${previewTheme.muted.text('─' * 28)}',
    );

    for (int i = 0; i < items.length; i++) {
      final t = items[i];
      final isSelected = i == selected;
      final isActive = t.id == activeTheme.id;

      final pointer = isSelected ? previewTheme.accent.text('▸') : ' ';
      final numStr = previewTheme.secondary.text(
        '[${(i + 1).toString().padLeft(2)}]',
      );
      final nameStr = t.displayName.padRight(18);

      // Preview swatches: Accent, Secondary, Code, Success, Error
      final swatches =
          '${t.accent.text('●')} ${t.secondary.text('●')} ${t.code.text('●')} ${t.success.text('●')} ${t.error.text('●')}';

      final activeTag = isActive
          ? ' ${previewTheme.success.text('[active]')}'
          : '';

      if (isSelected) {
        out.writeLine(
          '    $pointer $numStr ${previewTheme.surface.bg}${previewTheme.accent.text(" $nameStr ")}\x1B[0m $swatches$activeTag',
        );
      } else {
        out.writeLine(
          '    $pointer $numStr ${previewTheme.primary.text(" $nameStr ")} $swatches$activeTag',
        );
      }
    }

    out.writeLine('  ${previewTheme.muted.text('╰──${'─' * 43}')}');
    out.writeLine(
      '  ${previewTheme.muted.text('Use ↑/↓ arrows to preview, Enter to select, 1-${items.length} to pick, Esc/q to cancel')}',
    );
  }

  static void _clearMenu(int itemCount, TranscriptWriter out) {
    // Menu lines: 1 top empty + 1 header + items.length + 1 footer + 1 hint = items.length + 4
    final totalLines = itemCount + 4;
    out.rewind(totalLines);
  }
}
