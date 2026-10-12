import 'dart:io';
import 'package:nib/ai/image_attachment.dart';
import 'package:nib/ui/prompt_reader.dart';
import 'package:test/test.dart';

void main() {
  group('PromptReader History Test', () {
    test('addToHistory adds entries and ignores immediate duplicate', () {
      final reader = PromptReader();
      reader.addToHistory('hello');
      reader.addToHistory('hello');
      reader.addToHistory('world');

      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        final historyFile = File('$home/.nib/history');
        expect(historyFile.existsSync(), isTrue);
        final lines = historyFile.readAsLinesSync();
        expect(lines, contains('hello'));
        expect(lines, contains('world'));
      }
    });

    test('visibleWidth accurately strips 24-bit TrueColor and ANSI codes', () {
      const styledPrompt =
          '\x1B[38;2;137;180;250mnib\x1B[0m \x1B[38;2;203;166;247m❯\x1B[0m ';
      final width = PromptReader.visibleWidth(styledPrompt);
      expect(width, equals(6)); // 'nib ❯ '
    });

    test('calculates row wrapping correctly for long multi-line inputs', () {
      const cols = 80;
      const promptLen = 6;
      // 150-char input like in screenshot
      final input = 'a' * 150;
      final totalLen = promptLen + input.length; // 156
      final endRow = totalLen ~/ cols; // 156 ~/ 80 = 1
      final endCol = totalLen % cols; // 156 % 80 = 76

      expect(endRow, equals(1));
      expect(endCol, equals(76));
    });

    test('word boundary helpers calculate boundaries correctly', () {
      const text = 'hello world foo_bar';
      // End of string: text.length = 19
      expect(
        PromptReader.prevWordBoundary(text, 19),
        equals(12),
      ); // 'foo_bar' start
      expect(
        PromptReader.prevWordBoundary(text, 12),
        equals(6),
      ); // 'world' start
      expect(
        PromptReader.prevWordBoundary(text, 6),
        equals(0),
      ); // 'hello' start
      expect(PromptReader.prevWordBoundary(text, 0), equals(0));

      expect(PromptReader.nextWordBoundary(text, 0), equals(5)); // 'hello' end
      expect(PromptReader.nextWordBoundary(text, 5), equals(11)); // 'world' end
      expect(
        PromptReader.nextWordBoundary(text, 11),
        equals(19),
      ); // 'foo_bar' end
      expect(PromptReader.nextWordBoundary(text, 19), equals(19));
    });

    test('tracks and stores attachedImages for the turn', () {
      final reader = PromptReader();
      expect(reader.attachedImages, isEmpty);

      const att = ImageAttachment(
        mimeType: 'image/png',
        base64Data: 'dummy',
        width: 100,
        height: 100,
        originalPath: 'clipboard',
      );
      reader.attachedImages.add(att);
      expect(reader.attachedImages.length, equals(1));
      expect(reader.attachedImages.first.originalPath, equals('clipboard'));

      reader.attachedImages.clear();
      expect(reader.attachedImages, isEmpty);
    });
  });
}
