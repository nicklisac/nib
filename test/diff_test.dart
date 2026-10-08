import 'package:diffutil_dart/diffutil.dart' as diffutil;
import 'package:test/test.dart';

void main() {
  test('diffutil_dart calculates Myers diff on lines', () {
    final oldLines = ['line1', 'line2', 'line3', 'line4', 'line5'];
    final newLines = ['line1', 'line2_mod', 'line4', 'line6'];

    final diff = generateUnifiedDiff(oldLines, newLines);
    print('Diff output:');
    for (final d in diff) {
      print('  $d');
    }

    expect(diff, [
      '  line1',
      '- line2',
      '- line3',
      '+ line2_mod',
      '  line4',
      '- line5',
      '+ line6',
    ]);
  });
}

List<String> generateUnifiedDiff(List<String> oldLines, List<String> newLines) {
  if (oldLines.isEmpty && newLines.isEmpty) return [];
  if (oldLines.isEmpty) return newLines.map((l) => '+ $l').toList();
  if (newLines.isEmpty) return oldLines.map((l) => '- $l').toList();

  final result = diffutil.calculateListDiff(
    oldLines,
    newLines,
    detectMoves: false,
  );
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

  final output = <String>[];
  int oldIdx = 0;
  int newIdx = 0;

  while (oldIdx < oldLines.length || newIdx < newLines.length) {
    // 1. If old line is a deletion, output deletion
    if (oldIdx < oldLines.length &&
        (removedOldIndices.contains(oldIdx) || newIdx >= newLines.length)) {
      output.add('- ${oldLines[oldIdx]}');
      oldIdx++;
      continue;
    }

    // 2. If new line is an insertion, output addition
    if (newIdx < newLines.length &&
        (insertedNewIndices.containsKey(newIdx) || oldIdx >= oldLines.length)) {
      output.add('+ ${newLines[newIdx]}');
      newIdx++;
      continue;
    }

    // 3. Both are matching context lines
    if (oldIdx < oldLines.length && newIdx < newLines.length) {
      output.add('  ${oldLines[oldIdx]}');
      oldIdx++;
      newIdx++;
    }
  }

  return output;
}
