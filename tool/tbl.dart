import 'package:nib/ui/markdown_renderer.dart';

void main() {
  const md = '''
# Nib Bones

| Layer | File | LOC | Verdict |
|---|---|---:|:---:|
| Harness | `agent.dart` | 184 | solid |
| Providers | `anthropic_provider.dart` | 226 | good |
| UI | `markdown_renderer.dart` | 341 | new |

A line with **bold**, `code`, and a [link](http://x.y).

| Odd |
|---|
| one column **only** |
''';
  print(MarkdownRenderer.render(md));
}
