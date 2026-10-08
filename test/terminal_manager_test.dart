import 'package:dart_console/dart_console.dart';
import 'package:nib/ui/terminal_manager.dart';
import 'package:test/test.dart';

void main() {
  group('KeyDecoder Test', () {
    test('decodes arrow keys', () {
      final up = KeyDecoder.decode([27, 91, 65]);
      expect(up.length, equals(1));
      expect(up.first.controlChar, equals(ControlCharacter.arrowUp));

      final down = KeyDecoder.decode([27, 91, 66]);
      expect(down.first.controlChar, equals(ControlCharacter.arrowDown));

      final right = KeyDecoder.decode([27, 91, 67]);
      expect(right.first.controlChar, equals(ControlCharacter.arrowRight));

      final left = KeyDecoder.decode([27, 91, 68]);
      expect(left.first.controlChar, equals(ControlCharacter.arrowLeft));
    });

    test('decodes extended navigation keys (Delete, Home, End, PageUp, PageDown)', () {
      final del = KeyDecoder.decode([27, 91, 51, 126]);
      expect(del.first.controlChar, equals(ControlCharacter.delete));

      final home = KeyDecoder.decode([27, 91, 49, 126]);
      expect(home.first.controlChar, equals(ControlCharacter.home));

      final end = KeyDecoder.decode([27, 91, 52, 126]);
      expect(end.first.controlChar, equals(ControlCharacter.end));

      final pageUp = KeyDecoder.decode([27, 91, 53, 126]);
      expect(pageUp.first.controlChar, equals(ControlCharacter.pageUp));

      final pageDown = KeyDecoder.decode([27, 91, 54, 126]);
      expect(pageDown.first.controlChar, equals(ControlCharacter.pageDown));
    });

    test('decodes control characters (Enter, Tab, Backspace, Esc, Ctrl+C)', () {
      final enter = KeyDecoder.decode([10]);
      expect(enter.first.controlChar, equals(ControlCharacter.enter));

      final tab = KeyDecoder.decode([9]);
      expect(tab.first.controlChar, equals(ControlCharacter.tab));

      final bs = KeyDecoder.decode([127]);
      expect(bs.first.controlChar, equals(ControlCharacter.backspace));

      final esc = KeyDecoder.decode([27]);
      expect(esc.first.controlChar, equals(ControlCharacter.escape));

      final ctrlC = KeyDecoder.decode([3]);
      expect(ctrlC.first.controlChar, equals(ControlCharacter.ctrlC));
    });

    test('decodes printable ASCII and UTF-8 characters', () {
      final ascii = KeyDecoder.decode([104, 101, 108, 108, 111]); // hello
      expect(ascii.length, equals(5));
      expect(ascii.map((k) => k.char).join(), equals('hello'));

      // UTF-8 rocket emoji 🚀 [240, 159, 154, 128]
      final emoji = KeyDecoder.decode([240, 159, 154, 128]);
      expect(emoji.length, equals(1));
      expect(emoji.first.char, equals('🚀'));
    });

    test('decodes mixed stream of keys including escape and arrow in single burst', () {
      // "hi" followed by Up Arrow
      final burst = KeyDecoder.decode([104, 105, 27, 91, 65]);
      expect(burst.length, equals(3));
      expect(burst[0].char, equals('h'));
      expect(burst[1].char, equals('i'));
      expect(burst[2].controlChar, equals(ControlCharacter.arrowUp));
    });
  });
}
