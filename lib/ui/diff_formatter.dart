import 'package:diffutil_dart/diffutil.dart' as diffutil;
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
    if (a.isEmpty && b.isEmpty) return [];
    if (a.isEmpty) return b.map((l) => _DiffItem(_DiffType.addition, l)).toList();
    if (b.isEmpty) return a.map((l) => _DiffItem(_DiffType.deletion, l)).toList();

    final result = diffutil.calculateListDiff(a, b, detectMoves: false);
    final updates = result.getUpdatesWithData().toList();

    final removedOldIndices = <int>{};
    for (final u in updates) {
      if (u is diffutil.DataRemove<String>) {
        removedOldIndices.add(u.position);
      }
    }

    final insertedNewIndices = <int, String>{};
    for (final u in updates) {
      if (u is diffutil.DataInsert<String>) {
        insertedNewIndices[u.position] = u.data;
      }
    }

    final items = <_DiffItem>[];
    int oldIdx = 0;
    int newIdx = 0;

    while (oldIdx < a.length || newIdx < b.length) {
      // 1. Deletion from old lines
      if (oldIdx < a.length && (removedOldIndices.contains(oldIdx) || newIdx >= b.length)) {
        items.add(_DiffItem(_DiffType.deletion, a[oldIdx]));
        oldIdx++;
        continue;
      }

      // 2. Addition from new lines
      if (newIdx < b.length && (insertedNewIndices.containsKey(newIdx) || oldIdx >= a.length)) {
        items.add(_DiffItem(_DiffType.addition, b[newIdx]));
        newIdx++;
        continue;
      }

      // 3. Matching context lines
      if (oldIdx < a.length && newIdx < b.length) {
        items.add(_DiffItem(_DiffType.context, a[oldIdx]));
        oldIdx++;
        newIdx++;
      }
    }

    return items;
  }
}

enum _DiffType { context, addition, deletion }

class _DiffItem {
  final _DiffType type;
  final String text;
  _DiffItem(this.type, this.text);
}
