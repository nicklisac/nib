import 'ansi.dart';

/// Utility to generate and highlight unified diffs for terminal display.
class DiffFormatter {
  /// Generates ANSI color-highlighted unified diff lines between [oldText] and [newText].
  static List<String> formatDiff(String oldText, String newText, {int contextLines = 3}) {
    final oldLines = oldText.isEmpty ? <String>[] : oldText.split('\n');
    final newLines = newText.isEmpty ? <String>[] : newText.split('\n');

    final diff = _computeDiff(oldLines, newLines);
    final output = <String>[];

    for (final item in diff) {
      switch (item.type) {
        case _DiffType.addition:
          output.add('${Ansi.greenText('+')} ${Ansi.greenText(item.text)}');
        case _DiffType.deletion:
          output.add('${Ansi.redText('-')} ${Ansi.redText(item.text)}');
        case _DiffType.context:
          output.add('  ${Ansi.dimText(item.text)}');
      }
    }

    return output;
  }

  /// Compact representation with line counts and highlighted changes
  static String formatSummary(String path, String oldText, String newText) {
    final diff = formatDiff(oldText, newText);
    final buf = StringBuffer();
    buf.writeln('  ${Ansi.boldText(Ansi.cyanText(path))}');
    if (diff.isEmpty) {
      buf.writeln('    ${Ansi.dimText('(no content changes)')}');
    } else {
      const maxDisplay = 15;
      final display = diff.take(maxDisplay).toList();
      for (final line in display) {
        buf.writeln('    $line');
      }
      if (diff.length > maxDisplay) {
        buf.writeln('    ${Ansi.dimText('... (${diff.length - maxDisplay} more diff lines)')}');
      }
    }
    return buf.toString().trimRight();
  }

  static List<_DiffItem> _computeDiff(List<String> a, List<String> b) {
    final result = <_DiffItem>[];
    int i = 0, j = 0;

    // Fast path: find common prefix
    while (i < a.length && j < b.length && a[i] == b[j]) {
      // keep only last context line if approaching change
      i++;
      j++;
    }

    // Add immediate pre-context line if available
    if (i > 0 && (i < a.length || j < b.length)) {
      result.add(_DiffItem(_DiffType.context, a[i - 1]));
    }

    // Process differences
    while (i < a.length || j < b.length) {
      if (i < a.length && j < b.length && a[i] == b[j]) {
        result.add(_DiffItem(_DiffType.context, a[i]));
        i++;
        j++;
      } else {
        // Simple search for sync point
        int matchA = -1;
        int matchB = -1;
        for (int lookA = i; lookA < a.length && lookA < i + 5; lookA++) {
          for (int lookB = j; lookB < b.length && lookB < j + 5; lookB++) {
            if (a[lookA] == b[lookB]) {
              matchA = lookA;
              matchB = lookB;
              break;
            }
          }
          if (matchA != -1) break;
        }

        if (matchA != -1 && matchB != -1) {
          while (i < matchA) {
            result.add(_DiffItem(_DiffType.deletion, a[i++]));
          }
          while (j < matchB) {
            result.add(_DiffItem(_DiffType.addition, b[j++]));
          }
        } else {
          if (i < a.length) {
            result.add(_DiffItem(_DiffType.deletion, a[i++]));
          }
          if (j < b.length) {
            result.add(_DiffItem(_DiffType.addition, b[j++]));
          }
        }
      }
    }

    return result;
  }
}

enum _DiffType { context, addition, deletion }

class _DiffItem {
  final _DiffType type;
  final String text;
  _DiffItem(this.type, this.text);
}
