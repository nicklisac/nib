import 'package:dart_console/dart_console.dart';
import 'terminal_manager.dart';

/// Normalized actions that can be triggered via keyboard bindings.
enum KeyAction {
  cancel,
  sessionPicker,
  thinkingCycle,
  toggleThinking,
  toggleToolResults,
  modelCycle,
  commandPalette,
  redraw,
}

/// A parsed key chord, e.g. `ctrl+r`, `shift+tab`, `alt+enter`, `escape`.
class KeyChord {
  final bool ctrl;
  final bool alt;
  final bool shift;
  final String keyName;

  const KeyChord({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    required this.keyName,
  });

  /// Parses a string representation like "ctrl+r", "shift+tab", "ctrl+t", "escape".
  /// Throws [FormatException] if the format is invalid or unknown key name is given.
  factory KeyChord.parse(String input) {
    final raw = input.trim().toLowerCase();
    if (raw.isEmpty) {
      throw FormatException('Empty key chord');
    }

    final parts = raw.split('+');
    var ctrl = false;
    var alt = false;
    var shift = false;
    String? mainKey;

    for (final part in parts) {
      final p = part.trim();
      if (p.isEmpty) {
        throw FormatException('Empty key part in chord "$input"');
      }
      if (p == 'ctrl' || p == 'control') {
        ctrl = true;
      } else if (p == 'alt' || p == 'opt' || p == 'option') {
        alt = true;
      } else if (p == 'shift') {
        shift = true;
      } else {
        if (mainKey != null) {
          throw FormatException(
            'Multiple non-modifier keys in chord "$input": "$mainKey" and "$p"',
          );
        }
        mainKey = p;
      }
    }

    if (mainKey == null) {
      throw FormatException('No key specified in chord "$input"');
    }

    return KeyChord(ctrl: ctrl, alt: alt, shift: shift, keyName: mainKey);
  }

  /// Checks if an incoming event matches this chord.
  bool matches(Object event) {
    if (event is AltKeyEvent) {
      // e.g. label is 'shift+tab', 'alt+left', 'alt+enter'
      final chordLabel = toString();
      if (event.label == chordLabel) return true;
      // Also match by key name if alt is true
      if (alt && event.label == 'alt+$keyName') return true;
      return false;
    }

    if (event is Key) {
      if (event.isControl) {
        final name = _controlCharName(event.controlChar);
        if (name == null) return false;

        // If key is ctrl+<char> like ctrl+r, controlChar is ctrlR
        if (name.startsWith('ctrl+')) {
          final cName = name.substring(5);
          return ctrl && !alt && !shift && keyName == cName;
        }

        // For other control characters (escape, enter, tab, backspace, etc.)
        return !ctrl && !alt && !shift && keyName == name;
      } else {
        // Printable key
        return !ctrl && !alt && !shift && keyName == event.char.toLowerCase();
      }
    }

    return false;
  }

  static String? _controlCharName(ControlCharacter c) => switch (c) {
    ControlCharacter.escape => 'escape',
    ControlCharacter.tab => 'tab',
    ControlCharacter.enter => 'enter',
    ControlCharacter.backspace => 'backspace',
    ControlCharacter.arrowUp => 'up',
    ControlCharacter.arrowDown => 'down',
    ControlCharacter.arrowLeft => 'left',
    ControlCharacter.arrowRight => 'right',
    ControlCharacter.ctrlA => 'ctrl+a',
    ControlCharacter.ctrlB => 'ctrl+b',
    ControlCharacter.ctrlC => 'ctrl+c',
    ControlCharacter.ctrlD => 'ctrl+d',
    ControlCharacter.ctrlE => 'ctrl+e',
    ControlCharacter.ctrlF => 'ctrl+f',
    ControlCharacter.ctrlG => 'ctrl+g',
    ControlCharacter.ctrlH => 'ctrl+h',
    ControlCharacter.ctrlJ => 'ctrl+j',
    ControlCharacter.ctrlK => 'ctrl+k',
    ControlCharacter.ctrlL => 'ctrl+l',
    ControlCharacter.ctrlN => 'ctrl+n',
    ControlCharacter.ctrlO => 'ctrl+o',
    ControlCharacter.ctrlP => 'ctrl+p',
    ControlCharacter.ctrlQ => 'ctrl+q',
    ControlCharacter.ctrlR => 'ctrl+r',
    ControlCharacter.ctrlS => 'ctrl+s',
    ControlCharacter.ctrlT => 'ctrl+t',
    ControlCharacter.ctrlU => 'ctrl+u',
    ControlCharacter.ctrlV => 'ctrl+v',
    ControlCharacter.ctrlW => 'ctrl+w',
    ControlCharacter.ctrlX => 'ctrl+x',
    ControlCharacter.ctrlY => 'ctrl+y',
    ControlCharacter.ctrlZ => 'ctrl+z',
    _ => null,
  };

  @override
  String toString() {
    final parts = <String>[];
    if (ctrl) parts.add('ctrl');
    if (alt) parts.add('alt');
    if (shift) parts.add('shift');
    parts.add(keyName);
    return parts.join('+');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyChord &&
          runtimeType == other.runtimeType &&
          ctrl == other.ctrl &&
          alt == other.alt &&
          shift == other.shift &&
          keyName == other.keyName;

  @override
  int get hashCode =>
      ctrl.hashCode ^ alt.hashCode ^ shift.hashCode ^ keyName.hashCode;
}

/// Registry of configured key bindings.
class KeyBindings {
  final Map<KeyAction, KeyChord> bindings;

  const KeyBindings(this.bindings);

  /// Default bindings matching Tau and agreed conventions:
  /// - session_picker: ctrl+r
  /// - thinking_cycle: shift+tab
  /// - toggle_thinking: ctrl+t
  /// - toggle_tool_results: ctrl+o
  /// - model_cycle: ctrl+p
  /// - cancel: escape
  /// - command_palette: ctrl+k
  static Map<KeyAction, KeyChord> get defaultBindings => {
    KeyAction.cancel: KeyChord.parse('escape'),
    KeyAction.sessionPicker: KeyChord.parse('ctrl+r'),
    KeyAction.thinkingCycle: KeyChord.parse('shift+tab'),
    KeyAction.toggleThinking: KeyChord.parse('ctrl+t'),
    KeyAction.toggleToolResults: KeyChord.parse('ctrl+o'),
    KeyAction.modelCycle: KeyChord.parse('ctrl+p'),
    KeyAction.commandPalette: KeyChord.parse('ctrl+k'),
    KeyAction.redraw: KeyChord.parse('ctrl+l'),
  };

  factory KeyBindings.defaults() => KeyBindings(Map.of(defaultBindings));

  /// Parses keybindings from config map.
  /// Throws [FormatException] if a key cannot be parsed, adhering to Feel Doctrine Rule 6
  /// (fail loudly naming the bad key rather than silently no-oping).
  factory KeyBindings.fromJson(Map<String, dynamic> json) {
    final map = Map.of(defaultBindings);

    for (final entry in json.entries) {
      final actionName = entry.key;
      final chordStr = entry.value;
      if (chordStr is! String) continue;

      final action = _actionFromName(actionName);
      if (action != null) {
        try {
          map[action] = KeyChord.parse(chordStr);
        } catch (e) {
          throw FormatException(
            'Invalid keybinding for "$actionName": "$chordStr" ($e)',
          );
        }
      }
    }

    return KeyBindings(map);
  }

  static KeyAction? _actionFromName(String name) => switch (name) {
    'cancel' => KeyAction.cancel,
    'session_picker' || 'sessionPicker' => KeyAction.sessionPicker,
    'thinking_cycle' || 'thinkingCycle' => KeyAction.thinkingCycle,
    'toggle_thinking' || 'toggleThinking' => KeyAction.toggleThinking,
    'toggle_tool_results' || 'toggleToolResults' => KeyAction.toggleToolResults,
    'model_cycle' || 'modelCycle' => KeyAction.modelCycle,
    'command_palette' || 'commandPalette' => KeyAction.commandPalette,
    'redraw' => KeyAction.redraw,
    _ => null,
  };

  /// Returns which [KeyAction] matches the event, if any.
  KeyAction? match(Object event) {
    for (final entry in bindings.entries) {
      if (entry.value.matches(event)) {
        return entry.key;
      }
    }
    return null;
  }
}
