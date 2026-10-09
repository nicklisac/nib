import 'ansi.dart';

/// Utility to generate and highlight unified diffs for terminal display.
class DiffFormatter {
  /// Generates ANSI color-highlighted unified diff lines between [oldText] and [newText].
  static List<String> formatDiff(
    String oldText,
    String newText, {
    int contextLines = 3,
  }) {
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
        buf.writeln(
          '    ${Ansi.dimText('... (${diff.length - maxDisplay} more diff lines)')}',
        );
      }
    }
    return buf.toString().trimRight();
  }

  static List<_DiffItem> _computeDiff(List<String> a, List<String> b) {
    if (a.isEmpty && b.isEmpty) return [];
    if (a.isEmpty) {
      return b.map((l) => _DiffItem(_DiffType.addition, l)).toList();
    }
    if (b.isEmpty) {
      return a.map((l) => _DiffItem(_DiffType.deletion, l)).toList();
    }

    // Standard Myers LCS / edit script algorithm
    final n = a.length;
    final m = b.length;
    final max = n + m;
    final v = <int, int>{1: 0};
    final trace = <Map<int, int>>[];

    for (int d = 0; d <= max; d++) {
      trace.add(Map<int, int>.from(v));
      bool found = false;
      for (int k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0))) {
          x = v[k + 1] ?? 0;
        } else {
          x = (v[k - 1] ?? 0) + 1;
        }
        int y = x - k;

        while (x < n && y < m && a[x] == b[y]) {
          x++;
          y++;
        }
        v[k] = x;

        if (x >= n && y >= m) {
          found = true;
          break;
        }
      }
      if (found) break;
    }

    // Backtrack to build the diff
    final items = <_DiffItem>[];
    int x = n;
    int y = m;

    for (int d = trace.length - 1; d > 0; d--) {
      final prevV = trace[d];
      final k = x - y;
      int prevK;
      if (k == -d || (k != d && (prevV[k - 1] ?? 0) < (prevV[k + 1] ?? 0))) {
        prevK = k + 1;
      } else {
        prevK = k - 1;
      }
      final prevX = prevV[prevK] ?? 0;
      final prevY = prevX - prevK;

      while (x > prevX && y > prevY) {
        x--;
        y--;
        items.add(_DiffItem(_DiffType.context, a[x]));
      }

      if (d > 0) {
        if (x == prevX) {
          y--;
          items.add(_DiffItem(_DiffType.addition, b[y]));
        } else if (y == prevY) {
          x--;
          items.add(_DiffItem(_DiffType.deletion, a[x]));
        }
      }
    }

    while (x > 0 && y > 0) {
      x--;
      y--;
      items.add(_DiffItem(_DiffType.context, a[x]));
    }

    return items.reversed.toList();
  }
}

enum _DiffType { context, addition, deletion }

class _DiffItem {
  final _DiffType type;
  final String text;
  _DiffItem(this.type, this.text);
}
