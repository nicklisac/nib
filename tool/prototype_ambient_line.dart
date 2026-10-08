// PROTOTYPE — throwaway. Answers nicklisac/nib#22: what does the ambient line look like?
// Run: dart run tool/prototype_ambient_line.dart
// Not production. No tests, no polish, delete when the decision is made.
//
// Renders 4 candidate designs x 6 states x 3 widths, using Nib's real theme colours.

import 'dart:io';
import '../lib/ui/theme.dart';

final theme = NibTheme.current;

/// muted · primary · accent · secondary · warning · success · error · info
String m(String s) => theme.muted.text(s);
String a(String s) => theme.accent.text(s);
String w(String s) => theme.warning.text(s);
String s2(String s) => theme.secondary.text(s);
String i2(String s) => theme.info.text(s);
String e(String s) => theme.error.text(s);

/// Context gauge, per #21: estimate carries `~`, measured does not.
String gauge(int used, int window, {required bool measured}) =>
    measured ? '$used/$window' : '~$used/$window';

String pct(int used, int window) =>
    '${(used / window * 100).toStringAsFixed(0)}%';

// ── Variant A: dot-separated, everything on one row ─────────────────────────
String variantA(String state, int cols, int used, int window, bool measured) {
  final g = '${i2(gauge(used, window, measured: measured))} ${m(pct(used, window))}';
  final parts = <String>[];
  switch (state) {
    case 'idle':
      parts.addAll([m('idle'), g, m('12.4k tok')]);
    case 'streaming':
      parts.addAll([a('▍ thinking'), m('4.2s'), m('41 tok/s'), g]);
    case 'tool':
      parts.addAll([w('⚙ bash'), m('run tests'), m('6.1s'), g]);
    case 'queued':
      parts.addAll([m('idle'), g, a('⏎ 1 queued → sends after turn')]);
    case 'interrupted':
      parts.addAll([e('✖ interrupted'), m('draft kept'), g]);
    case 'toolstream':
      parts.addAll([w('⚙ bash'), m('cargo build'), m('22s'),
          m('Compiling nib v0.0.1'), g]);
  }
  return '  ${parts.join(m(' · '))}';
}

// ── Variant B: bracket glyphs, right-aligned gauge ──────────────────────────
String variantB(String state, int cols, int used, int window, bool measured) {
  final left = switch (state) {
    'idle' => m('⏸'),
    'streaming' => a('●'),
    'tool' => w('⚙'),
    'queued' => m('⏸'),
    'interrupted' => e('✖'),
    'toolstream' => w('⚙'),
    _ => m('?'),
  };
  final label = switch (state) {
    'idle' => '',
    'streaming' => ' ${m('thinking 4.2s · 41 tok/s')}',
    'tool' => ' ${m('bash · run tests · 6.1s')}',
    'queued' => ' ${a('⏎ 1 queued')}',
    'interrupted' => ' ${m('interrupted · draft kept')}',
    'toolstream' => ' ${m('bash · cargo build · 22s')}',
    _ => '',
  };
  final g = '${i2(gauge(used, window, measured: measured))} ${m(pct(used, window))}';
  final l = '  $left$label';
  final r = g;
  final pad = (cols - _w(l) - _w(r)).clamp(1, 200);
  return '$l${' ' * pad}$r';
}

// ── Variant C: nothing while the model speaks (minimal) ─────────────────────
String variantC(String state, int cols, int used, int window, bool measured) {
  // #20 says the line is only redrawn outside streaming windows.
  // C takes that literally: silent while streaming, present otherwise.
  switch (state) {
    case 'streaming':
    case 'toolstream':
      return ''; // line is simply not drawn
    case 'idle':
      return '  ${m('─')} ${i2(gauge(used, window, measured: measured))} ${m(pct(used, window))} ${m('· 12.4k tok spent')}${state == 'idle' ? '' : ''}';
    case 'queued':
      return '  ${m('─')} ${a('⏎ 1 queued — sends when this turn ends')}';
    case 'interrupted':
      return '  ${m('─')} ${e('interrupted')} ${m('· draft kept')} ${m('· ')}${i2(gauge(used, window, measured: measured))}';
    case 'tool':
      return '  ${m('─')} ${w('⚙ bash run tests')} ${m('· you can type now')}';
  }
  return '';
}

// ── Variant D: two rows when there is something to say ──────────────────────
String variantD(String state, int cols, int used, int window, bool measured) {
  final g = '${i2(gauge(used, window, measured: measured))} ${m(pct(used, window))}';
  final row1 = switch (state) {
    'idle' => '  ${m('idle')} ${m('·')} $g',
    'streaming' => '  ${a('▍')} ${m('thinking')} ${m('· 4.2s · 41 tok/s')}',
    'tool' => '  ${w('⚙')} ${m('bash')} ${m('run tests')} ${m('· 6.1s')}',
    'queued' => '  ${m('idle')} ${m('·')} $g',
    'interrupted' => '  ${e('✖')} ${m('interrupted · draft kept')}',
    'toolstream' => '  ${w('⚙')} ${m('bash')} ${m('cargo build · 22s')}',
    _ => '',
  };
  final row2 = switch (state) {
    'queued' => '  ${a('⏎ queued: "also add a test for the empty case"')}',
    'tool' => '  ${m('↳ typing here queues it for after the turn')}',
    'toolstream' => '  ${m('↳ Compiling nib v0.0.1 (--features gpu)')}',
    _ => '',
  };
  return row2.isEmpty ? row1 : '$row1\n$row2';
}

// ── Variant E: compact gauge + explicit drop order ──────────────────────────
// The finding from A-D at 40 cols: the raw gauge "61400/262144" is 15 chars and
// every variant overruns. E shows percent-only, with raw numbers as a separate
// priority tier that drops first.
String compactGauge(int used, int window, {required bool measured}) {
  if (window <= 0) return i2(measured ? '~${_k(used)} tok' : '~${_k(used)} tok');
  final p = (used / window * 100).toStringAsFixed(0);
  final near = used / window > 0.9;
  return near ? w('$p%') : i2('$p%');
}

String _k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// Fields in priority order; drop from the tail until it fits.
String variantE(String state, int cols, int used, int window, bool measured) {
  final g = compactGauge(used, window, measured: measured);
  // (priority, text) — highest first. Drop the last that fits nothing.
  final tiers = <String>[
    switch (state) {
      'idle' => m('⏸'),
      'streaming' => a('▍ ${m('thinking')}'),
      'tool' || 'toolstream' => w('⚙ ${m(state == 'tool' ? 'bash run tests' : 'bash cargo build')}'),
      'queued' => a('⏸ ${m('idle')}'),
      'interrupted' => e('✖ ${m('interrupted')}'),
      _ => m('?'),
    },
    if (state == 'streaming') m('41 tok/s'),
    if (state == 'tool' || state == 'toolstream') m('22s'),
    if (state == 'interrupted') m('draft kept'),
    if (state == 'queued') a('⏎ 1 queued'),
    g,
    if (state == 'idle') m('12.4k tok'),
    if (state == 'toolstream') m('Compiling nib v0.0.1'),
  ];
  var out = tiers;
  while (out.length > 1 && _w('  ${out.join(m(' · '))}') > cols) {
    out = out.sublist(0, out.length - 1);
  }
  return '  ${out.join(m(' · '))}';
}

int _w(String s) => s.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '').length;

void main() {
  const states = ['idle', 'streaming', 'tool', 'queued', 'interrupted', 'toolstream'];
  const variants = {
    'A · dot-separated, one row, gauge inline': variantA,
    'B · glyph-left, gauge right-aligned': variantB,
    'C · silent while streaming (strict #20 reading)': variantC,
    'D · two rows when there is something to say': variantD,
    'E · compact gauge + drop-from-tail': variantE,
  };
  const used = 61_400;
  const window = 262_144;

  for (final cols in [100, 80, 40]) {
    stdout.writeln('\n${a('═' * cols)}');
    stdout.writeln(a('  $cols columns'));
    stdout.writeln(a('═' * cols));
    for (final v in variants.entries) {
      stdout.writeln('\n  ${theme.primary.text(v.key)}');
      for (final st in states) {
        final out = v.value(st, cols, used, window, true);
        if (out.isEmpty) {
          stdout.writeln('    ${m('${st.padRight(13)} ⌀ line not drawn')}');
          continue;
        }
        for (final line in out.split('\n')) {
          final over = _w(line) > cols;
          final name = line == out.split('\n').first ? st.padRight(13) : ''.padRight(13);
          stdout.writeln('    $name$line${over ? e('  ⟵ OVERRUNS ${_w(line)}') : ''}');
        }
      }
    }
  }

  stdout.writeln('\n${w('estimate-vs-measured disclosure (#21):')}');
  stdout.writeln('  measured:  ${i2('61400/262144')} 37%');
  stdout.writeln('  estimated: ${i2('~61400/262144')} 37%');
  stdout.writeln('  unconfigured window: ${i2('~61400 tok')} ${m('(no %, no window shown)')}');
  stdout.writeln('\n${w('near threshold, estimate:')} ${i2('~248100/262144')} ${w('95%')} ${m('· compacts at 245760')}\n');
}