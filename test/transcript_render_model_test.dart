import 'package:test/test.dart';
import 'package:nib/ui/theme.dart';
import 'package:nib/ui/transcript_render_model.dart';

void main() {
  group('TranscriptRenderModel Tests', () {
    test('renders user prompt block with card frame', () {
      final block = UserPromptBlock('Hello world');
      final lines = block.render(theme: NibTheme.current, terminalWidth: 80);

      expect(lines.any((l) => l.contains('You')), isTrue);
      expect(lines.any((l) => l.contains('Hello world')), isTrue);
    });

    test('renders thought block expanded vs collapsed', () {
      final block = ThoughtBlock('Analyzing code and designing plan');
      final expanded = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        thinkingExpanded: true,
      );
      expect(
        expanded.any((l) => l.contains('Analyzing code and designing plan')),
        isTrue,
      );

      final collapsed = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        thinkingExpanded: false,
      );
      expect(collapsed.any((l) => l.contains('thinking collapsed')), isTrue);
      expect(collapsed.any((l) => l.contains('Analyzing code')), isFalse);
    });

    test('renders tool call block compact vs full output', () {
      final longStdout = List.generate(
        20,
        (i) => 'Line $i of output',
      ).join('\n');
      final block = ToolCallBlock(
        toolName: 'bash',
        arguments: {'command': 'dart test'},
        result: longStdout,
        durationMs: 42,
      );

      final compact = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        toolsExpanded: false,
      );
      expect(compact.any((l) => l.contains('bash')), isTrue);
      expect(compact.any((l) => l.contains('done (42ms)')), isTrue);
      expect(compact.any((l) => l.contains('more lines')), isTrue);

      final expanded = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        toolsExpanded: true,
      );
      expect(expanded.any((l) => l.contains('Line 19 of output')), isTrue);
      expect(expanded.any((l) => l.contains('more lines')), isFalse);
    });

    test('TranscriptRenderModel manages and renders sequence of blocks', () {
      final model = TranscriptRenderModel();
      model.add(UserPromptBlock('Prompt 1'));
      model.add(ThoughtBlock('Thought 1'));
      model.add(AssistantTextBlock('Response 1'));

      final allLines = model.renderAll(
        theme: NibTheme.current,
        terminalWidth: 80,
      );

      expect(allLines.any((l) => l.contains('Prompt 1')), isTrue);
      expect(allLines.any((l) => l.contains('Thought 1')), isTrue);
      expect(allLines.any((l) => l.contains('Response 1')), isTrue);
    });
  });
}
