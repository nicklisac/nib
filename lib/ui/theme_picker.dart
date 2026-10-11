import 'dart:io';
import 'dart:math';
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

    const windowSize = 8;
    var windowStart = 0;
    void adjustWindow() {
      if (selectedIndex < windowStart) {
        windowStart = selectedIndex;
      } else if (selectedIndex >= windowStart + windowSize) {
        windowStart = selectedIndex - windowSize + 1;
      }
    }

    adjustWindow();

    var activePreview = items[selectedIndex];
    NibTheme.current = activePreview;
    onPreview?.call(activePreview);

    // Initial render
    _renderMenu(
      items,
      selectedIndex,
      initialTheme,
      activePreview,
      windowStart,
      windowSize,
      out,
    );

    while (true) {
      final key = nextKey != null
          ? await nextKey()
          : await TerminalManager.instance.nextKey();

      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
            selectedIndex = (selectedIndex - 1 + items.length) % items.length;
            adjustWindow();
            activePreview = items[selectedIndex];
            NibTheme.current = activePreview;
            onPreview?.call(activePreview);
            _clearMenu(windowSize, out);
            _renderMenu(
              items,
              selectedIndex,
              initialTheme,
              activePreview,
              windowStart,
              windowSize,
              out,
            );
            break;

          case ControlCharacter.arrowDown:
            selectedIndex = (selectedIndex + 1) % items.length;
            adjustWindow();
            activePreview = items[selectedIndex];
            NibTheme.current = activePreview;
            onPreview?.call(activePreview);
            _clearMenu(windowSize, out);
            _renderMenu(
              items,
              selectedIndex,
              initialTheme,
              activePreview,
              windowStart,
              windowSize,
              out,
            );
            break;

          case ControlCharacter.enter:
            _clearMenu(windowSize, out);
            final chosen = items[selectedIndex];
            NibTheme.current = chosen;
            return chosen.id;

          case ControlCharacter.ctrlC:
            _clearMenu(windowSize, out);
            NibTheme.current = initialTheme;
            onPreview?.call(initialTheme);
            return null;

          default:
            break;
        }
      } else {
        final char = key.char;
        if (char == 'q' || char == 'Q' || char == '\x1B') {
          _clearMenu(windowSize, out);
          NibTheme.current = initialTheme;
          onPreview?.call(initialTheme);
          return null;
        }

        final numVal = int.tryParse(char);
        if (numVal != null && numVal >= 1 && numVal <= windowSize) {
          final targetIdx = windowStart + numVal - 1;
          if (targetIdx < items.length) {
            _clearMenu(windowSize, out);
            final chosen = items[targetIdx];
            NibTheme.current = chosen;
            return chosen.id;
          }
        }
      }
    }
  }

  static void _renderMenu(
    List<NibTheme> items,
    int selected,
    NibTheme activeTheme,
    NibTheme previewTheme,
    int windowStart,
    int windowSize,
    TranscriptWriter out,
  ) {
    out.writeLine('');
    out.writeLine(
      '  ${previewTheme.muted.text('╭──')} ${previewTheme.accent.text('🎨 Select Theme')} ${previewTheme.muted.text('─' * 22)}',
    );

    final visibleCount = min(windowSize, items.length - windowStart);
    for (int vi = 0; vi < windowSize; vi++) {
      final i = windowStart + vi;
      if (i < items.length) {
        final t = items[i];
        final isSelected = i == selected;
        final isActive = t.id == activeTheme.id;

        final pointer = isSelected ? previewTheme.accent.text('▸') : ' ';
        final numStr = previewTheme.secondary.text('[${(vi + 1)}]');
        final nameStr = t.displayName.padRight(16);

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
      } else {
        out.writeLine('');
      }
    }

    out.writeLine('  ${previewTheme.muted.text('╰──${'─' * 41}')}');
    out.writeLine(
      '  ${previewTheme.muted.text('Use ↑/↓ arrows to preview, Enter to select, 1-$visibleCount to pick, Esc/q to cancel')}',
    );
  }

  static void _clearMenu(int windowSize, TranscriptWriter out) {
    final totalLines = windowSize + 4;
    out.rewind(totalLines);
  }
}
