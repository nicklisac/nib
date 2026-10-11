import 'package:dart_console/dart_console.dart';
import 'package:nib/ui/key_binding.dart';
import 'package:nib/ui/terminal_manager.dart';
import 'package:test/test.dart';

void main() {
  group('KeyChord Parsing and Matching', () {
    test('parses basic chords correctly', () {
      final chord = KeyChord.parse('ctrl+r');
      expect(chord.ctrl, isTrue);
      expect(chord.alt, isFalse);
      expect(chord.shift, isFalse);
      expect(chord.keyName, equals('r'));
      expect(chord.toString(), equals('ctrl+r'));

      final shiftTab = KeyChord.parse('shift+tab');
      expect(shiftTab.shift, isTrue);
      expect(shiftTab.keyName, equals('tab'));

      final altEnter = KeyChord.parse('alt+enter');
      expect(altEnter.alt, isTrue);
      expect(altEnter.keyName, equals('enter'));

      final esc = KeyChord.parse('escape');
      expect(esc.ctrl, isFalse);
      expect(esc.alt, isFalse);
      expect(esc.shift, isFalse);
      expect(esc.keyName, equals('escape'));
    });

    test('throws FormatException on invalid chords', () {
      expect(() => KeyChord.parse(''), throwsA(isA<FormatException>()));
      expect(() => KeyChord.parse('ctrl+'), throwsA(isA<FormatException>()));
      expect(() => KeyChord.parse('ctrl+a+b'), throwsA(isA<FormatException>()));
    });

    test('matches Key and AltKeyEvent correctly', () {
      final chordCtrlR = KeyChord.parse('ctrl+r');
      expect(chordCtrlR.matches(Key.control(ControlCharacter.ctrlR)), isTrue);
      expect(chordCtrlR.matches(Key.control(ControlCharacter.ctrlC)), isFalse);

      final chordShiftTab = KeyChord.parse('shift+tab');
      expect(
        chordShiftTab.matches(
          AltKeyEvent(Key.control(ControlCharacter.tab), 'shift+tab'),
        ),
        isTrue,
      );

      final chordAltEnter = KeyChord.parse('alt+enter');
      expect(
        chordAltEnter.matches(
          AltKeyEvent(Key.control(ControlCharacter.enter), 'alt+enter'),
        ),
        isTrue,
      );

      final chordEsc = KeyChord.parse('escape');
      expect(chordEsc.matches(Key.control(ControlCharacter.escape)), isTrue);
    });
  });

  group('KeyBindings Registry and Config Parsing', () {
    test('loads default bindings', () {
      final bindings = KeyBindings.defaults();
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlR)),
        equals(KeyAction.sessionPicker),
      );
      expect(
        bindings.match(
          AltKeyEvent(Key.control(ControlCharacter.tab), 'shift+tab'),
        ),
        equals(KeyAction.thinkingCycle),
      );
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlT)),
        equals(KeyAction.toggleThinking),
      );
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlO)),
        equals(KeyAction.toggleToolResults),
      );
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlP)),
        equals(KeyAction.modelCycle),
      );
      expect(
        bindings.match(Key.control(ControlCharacter.escape)),
        equals(KeyAction.cancel),
      );
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlK)),
        equals(KeyAction.commandPalette),
      );
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlL)),
        equals(KeyAction.redraw),
      );
    });

    test('overrides bindings from JSON map', () {
      final customJson = {
        'session_picker': 'ctrl+s',
        'thinking_cycle': 'ctrl+t',
      };
      final bindings = KeyBindings.fromJson(customJson);
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlS)),
        equals(KeyAction.sessionPicker),
      );
      expect(
        bindings.match(Key.control(ControlCharacter.ctrlT)),
        equals(KeyAction.thinkingCycle),
      );
    });

    test('fails loudly naming the bad key on invalid chord', () {
      final badJson = {'session_picker': 'invalid++key'};
      expect(
        () => KeyBindings.fromJson(badJson),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('session_picker'),
          ),
        ),
      );
    });
  });
}
