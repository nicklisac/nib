import 'package:nib/ui/diff_formatter.dart';
import 'package:test/test.dart';

void main() {
  test('DiffFormatter produces clean diff for comments added around function', () {
    final oldLines = [
      '// half-thickness at radial fraction t (0=root .. 1=outer edge), station s',
      'function finHalfY(p, s, t) {',
      '  const h0 = Math.max(p.finThick, 0.8) / 2;',
      '  const taper = 0.35 + 0.65 * Math.pow(Math.max(0, 1 - s), 0.5);',
      '  const r = 1 + 2 * p.roundness;',
      '  const edge = 0.12 + 0.88 * Math.pow(Math.max(0, 1 - Math.pow(t, r)), 0.5);',
      '  return h0 * taper * edge;',
      '}',
    ].join('\n');

    final newLines = [
      '// half-thickness at radial fraction t (0=root .. 1=outer edge), station s',
      '//',
      'function finHalfY(p, s, t) {',
      '  const h0 = Math.max(p.finThick, 0.8) / 2;',
      '  // cross-section including t = 0',
      '  const taper = 0.35 + 0.65 * Math.pow(Math.max(0, 1 - s), 0.5);',
      '  // fin attached at 0.87mm',
      '  const r = 1 + 2 * p.roundness;',
      '  const edge = 0.12 + 0.88 * Math.pow(Math.max(0, 1 - Math.pow(t, r)), 0.5);',
      '  // root easing',
      '  return h0 * taper * edge;',
      '}',
    ].join('\n');

    final diff = DiffFormatter.formatDiff(oldLines, newLines);
    final plain = diff
        .map((l) => l.replaceAll(RegExp(r'\x1B\[[0-9;]*[mK]'), ''))
        .toList();

    // Verify ordering: '//' comes before 'function finHalfY'
    final commentIdx = plain.indexWhere((l) => l.contains('+ //'));
    final funcIdx = plain.indexWhere((l) => l.contains('function finHalfY'));
    expect(commentIdx, isNonNegative);
    expect(funcIdx, isNonNegative);
    expect(commentIdx, lessThan(funcIdx));
  });
}
