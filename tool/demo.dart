import 'package:nib/ui/markdown_renderer.dart';
void main() {
  print(MarkdownRenderer.render('''
## Nib — Layer Breakdown

| Layer | File | LOC | Verdict |
|:------|:-----------------|----:|:-------:|
| Harness | agent.dart | 184 | solid |
| Context | compaction.dart | 242 | solid |
| Session | session.dart | 225 | good |
| Providers | anthropic_provider.dart | 226 | good |
| Rendering | markdown_renderer.dart | 341 | new |
| Tools | bash_tool.dart | 100 | good |
'''));
}
