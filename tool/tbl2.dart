import 'package:nib/ui/markdown_renderer.dart';
void main() {
  // Table WITHOUT inline markup -> do borders align?
  print('--- plain ---');
  print(MarkdownRenderer.render('''
| Layer | File | LOC |
|---|---|---:|
| Harness | agent.dart | 184 |
| Providers | anthropic_provider.dart | 226 |
'''));
  // Table WITH inline code -> borders?
  print('--- with code spans ---');
  print(MarkdownRenderer.render('''
| Layer | File |
|---|---|
| Harness | `agent.dart` |
| Providers | `anthropic_provider.dart` |
'''));
  // Prose line isolation
  print('--- prose ---');
  print(MarkdownRenderer.render('A line with `code` and a [link](http://x.y).'));
  print('--- prose link only ---');
  print(MarkdownRenderer.render('a [link](http://x.y) here'));
  print('--- prose code only ---');
  print(MarkdownRenderer.render('a `code` here'));
}
