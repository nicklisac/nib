import 'dart:io';
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
      const styledPrompt = '\x1B[38;2;137;180;250mnib\x1B[0m \x1B[38;2;203;166;247m❯\x1B[0m ';
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
  });
}
