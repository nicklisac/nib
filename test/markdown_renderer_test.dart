import 'package:nib/ui/markdown_renderer.dart';
import 'package:nib/ui/theme.dart';
import 'package:test/test.dart';

void main() {
  group('MarkdownRenderer Test', () {
    test('renders headers, lists, code fences, and inline styles', () {
      NibTheme.setTheme('tokyonight');

      final markdown = '''
# Main Header
## Secondary Header
### Subheader

- Item 1 with `code`
- Item 2 with **bold** and *italic*
[link text](https://example.com)

```dart
final x = 42;
// comment
print("hello world");
```
''';

      final rendered = MarkdownRenderer.render(markdown);
      expect(rendered, contains('Main Header'));
      expect(rendered, contains('Secondary Header'));
      expect(rendered, contains('Subheader'));
      expect(rendered, contains('Item 1'));
      expect(rendered, contains('╭─'));
      expect(rendered, contains('dart'));
      expect(rendered, contains('╰─'));
      expect(rendered, contains('hello world'));
    });

    test('renders Markdown tables with borders and alignment', () {
      final markdown = '''
| Tool | Status | Speed |
| :--- | :---: | ---: |
| `bash` | **ok** | 12ms |
| `read_file` | **ok** | 4ms |
''';

      final rendered = MarkdownRenderer.render(markdown);
      expect(rendered, contains('Tool'));
      expect(rendered, contains('Status'));
      expect(rendered, contains('Speed'));
      expect(rendered, contains('bash'));
      expect(rendered, contains('12ms'));
      expect(rendered, contains('read_file'));
      // Check for table border glyphs
      expect(rendered, anyOf(contains('╭'), contains('┌'), contains('│')));
    });
  });
}
