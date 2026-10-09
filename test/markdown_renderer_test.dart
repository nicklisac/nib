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

      // Geometry check: All table lines should have the identical visible width
      final tableLines = rendered
          .split('\n')
          .map((l) => l.trim())
          .where(
            (l) =>
                l.startsWith('╭') ||
                l.startsWith('│') ||
                l.startsWith('├') ||
                l.startsWith('╰'),
          )
          .toList();
      expect(tableLines, isNotEmpty);
      final widths = tableLines.map((l) {
        final clean = l.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');
        return clean.runes.length;
      }).toSet();
      print('Table line widths: $widths');
      expect(
        widths.length,
        equals(1),
        reason: 'All table rows must have matching widths: $widths',
      );
    });

    test('renders user screenshot table with alignment markers', () {
      const markdown = '''
## Nib - Layer Breakdown

| Layer | File | LOC | Verdict |
|:------|:-------------------|----:|:-------:|
| Harness | agent.dart | 184 | solid |
| Context | compaction.dart | 242 | solid |
| Session | session.dart | 225 | good |
| Providers | anthropic_provider.dart | 226 | good |
| Rendering | markdown_renderer.dart | 341 | new |
| Tools | bash_tool.dart | 100 | good |
''';

      final rendered = MarkdownRenderer.render(markdown);
      print('\n--- RENDERED TABLE ---\n$rendered\n----------------------\n');
      expect(rendered, contains('Nib - Layer Breakdown'));
      expect(rendered, contains('Harness'));
      expect(rendered, contains('agent.dart'));
      // Must NOT contain raw unrendered table delimiter
      expect(rendered, isNot(contains('|:------|')));
      // Must contain table borders
      expect(rendered, anyOf(contains('╭'), contains('┌'), contains('│')));

      // Geometry check: All table lines must have identical display widths
      final tableLines = rendered
          .split('\n')
          .map((l) => l.trim())
          .where(
            (l) =>
                l.startsWith('╭') ||
                l.startsWith('│') ||
                l.startsWith('├') ||
                l.startsWith('╰'),
          )
          .toList();
      expect(tableLines, isNotEmpty);
      final widths = tableLines.map((l) {
        final clean = l.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');
        return clean.runes.length;
      }).toSet();
      expect(
        widths.length,
        equals(1),
        reason: 'All table rows must have matching widths: $widths',
      );
    });

    test(
      'StreamingMarkdownPrinter renders streamed tokens with code fences and tables',
      () {
        final buffer = StringBuffer();
        final printer = StreamingMarkdownPrinter(
          theme: NibTheme.tokyoNight,
          out: (s) => buffer.write(s),
        );

        // Simulate streaming deltas chunk-by-chunk
        final chunks = [
          'Here is ',
          'a breakdown:\n\n',
          '## Files\n',
          '| File | Type | Status |\n',
          '|:---|:---:|---:|\n',
          '| `main.dart` | entry | active |\n',
          '| `test.dart` | `unit` | passed |\n\n',
          'And some code:\n',
          '```dart\n',
          'void main() {\n',
          '  print("streaming");\n',
          '}\n',
          '```\n',
          'Done!',
        ];

        for (final chunk in chunks) {
          printer.addDelta(chunk);
        }
        printer.flush();

        final output = buffer.toString();
        expect(output, contains('Files'));
        expect(output, contains('main.dart'));
        expect(output, contains('streaming'));
        expect(output, contains('Done!'));
        expect(output, isNot(contains('|:---|')));
        expect(output, anyOf(contains('╭'), contains('│')));

        // Geometry check on streamed table
        final tableLines = output
            .split('\n')
            .map((l) => l.trim())
            .where(
              (l) =>
                  l.startsWith('╭') ||
                  l.startsWith('│') ||
                  l.startsWith('├') ||
                  l.startsWith('╰'),
            )
            .toList();
        expect(tableLines, isNotEmpty);
        final widths = tableLines.map((l) {
          final clean = l.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');
          return clean.runes.length;
        }).toSet();
        expect(
          widths.length,
          equals(1),
          reason: 'All table lines in stream must match in width: $widths',
        );
      },
    );

    test('renders full markdown gauntlet cleanly', () {
      final markdown = '''
# The Full `Markdown` Gauntlet 🥊

## 1. Emphasis Ladder
Plain → **bold** → *italic* → ***both at once*** → ~~struck~~ → ***~~dramatic~~*** → `inline code`

## 2. Blocks
> **Quote:** "It works on my machine."
> — *Every developer, ever*

```python
def gate(pr: dict) -> bool:
    """The Tech Lead approves. Nothing else merges."""
    return pr["reviewed_by"] == "nib" and pr["tests"] == "green"
```

```bash
\$ git commit -m "ship it"   # only I do this
```

## 3. Lists, Nested & Task-y
1. Plan
   1. Delegate
      - [x] Spawn AGY ⚡
      - [ ] Poll `agy-wrapper status`
      - [ ] *Never* block
2. Review
3. Commit

## 4. Table With Everything

| Agent | Speed | Tier | Verdict |
|:------|:-----:|-----:|--------:|
| **AGY** | 🚀🚀🚀 | 1 | `default` |
| *Subagent* | 🚀🚀 | 2 | fallback |
| Jules | 🐢 | 3 | ~~great~~ rare |

## 5. Odds & Ends
- Link: [the repo](https://example.com "hover me") · Ref-style: [docs][d]
- Footnote: Flash is the ceiling[^1]
- HTML sneaks in: H<sub>2</sub>O, x<sup>2</sup>, <kbd>Ctrl</kbd>+<kbd>C</kbd>
- Escape what you mean: \\*not italic\\*, \\# not a heading
- Keys: `HIGH` | `MEDIUM` | `LOW` — escalate effort, not spend

---

**Rule of thumb:** *be bold,* ***be brief***, `verify before you merge`.

[d]: https://example.com/docs

[^1]: Unless the developer says otherwise.
''';

      final rendered = MarkdownRenderer.render(markdown);
      print('\n=== GAUNTLET RENDER ===\n$rendered\n=======================\n');

      // 1. Must never leak raw ANSI escape fragments into strings/numbers
      expect(rendered, isNot(contains('38;2;166;227;161m')));
      expect(rendered, isNot(contains('@@ESC')));

      // 2. Syntax highlighting must preserve quotes and comments
      expect(
        rendered,
        contains('"""The Tech Lead approves. Nothing else merges."""'),
      );
      expect(rendered, contains('# only I do this'));

      // 3. Task lists must render with checkboxes and nested hierarchy
      expect(rendered, contains('✔'));
      expect(rendered, contains('Spawn AGY'));
      expect(rendered, contains('☐'));
      expect(rendered, contains('Poll'));
      expect(rendered, contains('Delegate'));

      // 4. Blockquotes must format inline markdown inside the quote
      expect(rendered, contains('Quote:'));
      expect(rendered, contains('"It works on my machine."'));

      // 5. Escaped asterisks must render as literal asterisks (not italicized)
      expect(rendered, contains('*not italic*'));

      // 6. Strikethrough code must be present and raw tildes stripped
      expect(rendered, contains('\x1B[9m'));
      expect(rendered, isNot(contains('~~struck~~')));
      expect(rendered, isNot(contains('~~great~~')));
      expect(rendered, isNot(contains('~~dramatic~~')));
    });

    test('renderTable flexes wide table cells to fit within maxTableWidth', () {
      final lines = [
        '| Camp | Sliceable floor | Practical floor |',
        '| --- | --- | --- |',
        '| FDM w/ Arachne (Prusa, Bambu, Cura-based) | ~0.4 mm — one extrusion, needs "Detect thin walls", very fragile | 0.8 mm (two extrusion widths) with no special settings; Qidi\'s own guidance says exactly this |',
        '| Resin (Formlabs) | 0.2 mm recommended minimum per Form 3 design specs | ~0.4–0.6 mm once you account for peel warp and IPA swelling |',
        '| Consumer mSLA (Elegoo/Anycubic) | similar optics to Formlabs | ~0.6 mm commonly quoted |',
      ];

      // Test at 80 columns
      final rendered80 = MarkdownRenderer.renderTable(lines, null, 80);
      final lines80 = rendered80.split('\n').where((l) => l.trim().isNotEmpty);
      for (final line in lines80) {
        final clean = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
        expect(
          clean.length,
          lessThanOrEqualTo(80),
          reason: 'Line "$clean" exceeds 80 columns (${clean.length})',
        );
      }

      // Verify content is preserved and wrapped
      expect(rendered80, contains('Camp'));
      expect(rendered80, contains('Sliceable floor'));
      expect(rendered80, contains('Practical floor'));
      expect(rendered80, contains('FDM w/ Arachne'));
      expect(rendered80, contains('Resin'));
    });
  });
}
