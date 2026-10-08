import 'package:nib/ui/markdown_renderer.dart';
final re = RegExp(r'\x1B\[[0-9;]*m');
int vis(String s) => s.replaceAll(re, '').length;
void main() {
  print('=== A. border drift (plain vs styled) ===');
  for (final t in ['plain','styled']) {
    final md = t == 'plain'
      ? '| File |\n|---|\n| agent.dart |\n| b.dart |'
      : '| File |\n|---|\n| `agent.dart` |\n| `b.dart` |';
    final out = MarkdownRenderer.render(md);
    print('-- $t');
    for (final l in out.split('\n').where((l)=>l.trim().isNotEmpty)) {
      print('  vis=${vis(l)}  ${l.replaceAll(re,'')}');
    }
  }
  print('=== B. single-dash delimiter (valid GFM) ===');
  print(MarkdownRenderer.render('| A | B |\n| - | - |\n| 1 | 2 |').replaceAll(re,''));
  print('=== C. escaped pipe ===');
  print(MarkdownRenderer.render('| A | B |\n|---|---|\n| x \\| y | 2 |').replaceAll(re,''));
  print('=== D. digits inside code-block color codes ===');
  print(MarkdownRenderer.render('```dart\nfinal x = 1;\n```'));
}
