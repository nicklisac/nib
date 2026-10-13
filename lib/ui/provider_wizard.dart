import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../agent/config.dart';
import 'terminal_manager.dart';
import 'theme.dart';
import 'transcript_writer.dart';

class ProtocolOption {
  final String id; // 'openai' or 'anthropic'
  final String label;
  final String defaultBaseUrl;
  final String defaultModel;
  final String defaultName;

  const ProtocolOption({
    required this.id,
    required this.label,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.defaultName,
  });
}

const List<ProtocolOption> protocols = [
  ProtocolOption(
    id: 'openai',
    label: 'OpenAI API Compatible (OpenAI, OpenRouter, Ollama, vLLM, etc.)',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o',
    defaultName: 'openai',
  ),
  ProtocolOption(
    id: 'anthropic',
    label: 'Anthropic (Claude Messages API)',
    defaultBaseUrl: 'https://api.anthropic.com',
    defaultModel: 'claude-3-7-sonnet-20250219',
    defaultName: 'anthropic',
  ),
];

/// Interactive provider setup wizard: clean 2-protocol choice, name, and credentials.
class ProviderSetupWizard {
  static Future<NibConfig?> run({
    NibConfig? existingConfig,
    TranscriptWriter? writer,
  }) async {
    final out = resolveTranscriptWriter(writer);
    final theme = NibTheme.current;

    if (!stdin.hasTerminal) {
      out.writeLine(
        theme.warning.text(
          '  Non-interactive terminal: cannot run interactive setup wizard.',
        ),
      );
      return null;
    }

    out.writeLine('');
    out.writeLine(
      '  ${theme.accent.text('╭── ✒   Nib Provider Setup ──────────────────────────────────────────')}',
    );
    out.writeLine(
      '  ${theme.muted.text('│')}   Configure your AI model endpoint and credentials.',
    );
    out.writeLine(
      '  ${theme.accent.text('╰───────────────────────────────────────────────────────────────────')}',
    );
    out.writeLine('');

    var selectedIndex = 0;
    _renderProtocolMenu(selectedIndex, theme, out);

    ProtocolOption? chosen;

    while (true) {
      final key = await TerminalManager.instance.nextKey();
      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
            selectedIndex =
                (selectedIndex - 1 + protocols.length) % protocols.length;
            _clearMenu(protocols.length, out);
            _renderProtocolMenu(selectedIndex, theme, out);
            break;
          case ControlCharacter.arrowDown:
            selectedIndex = (selectedIndex + 1) % protocols.length;
            _clearMenu(protocols.length, out);
            _renderProtocolMenu(selectedIndex, theme, out);
            break;
          case ControlCharacter.enter:
            _clearMenu(protocols.length, out);
            chosen = protocols[selectedIndex];
            break;
          case ControlCharacter.ctrlC:
            _clearMenu(protocols.length, out);
            out.writeLine(theme.muted.text('  Setup cancelled.'));
            return null;
          default:
            break;
        }
      } else {
        final char = key.char;
        if (char == 'q' || char == 'Q' || key.char == '\x1B') {
          _clearMenu(protocols.length, out);
          out.writeLine(theme.muted.text('  Setup cancelled.'));
          return null;
        }
        final numVal = int.tryParse(char);
        if (numVal != null && numVal >= 1 && numVal <= protocols.length) {
          _clearMenu(protocols.length, out);
          chosen = protocols[numVal - 1];
        }
      }

      if (chosen != null) break;
    }

    out.writeLine('  Protocol: ${theme.accent.text(chosen.label)}');
    out.writeLine('');

    // 1. Provider profile name
    stdout.write('  Provider name [${chosen.defaultName}]: ');
    final nameInput = stdin.readLineSync()?.trim() ?? '';
    final providerName = nameInput.isNotEmpty ? nameInput : chosen.defaultName;

    // 2. Base URL / Endpoint
    stdout.write('  Base URL [${chosen.defaultBaseUrl}]: ');
    final urlInput = stdin.readLineSync()?.trim() ?? '';
    final baseUrl = urlInput.isNotEmpty ? urlInput : chosen.defaultBaseUrl;

    // 3. Model name
    stdout.write('  Model [${chosen.defaultModel}]: ');
    final modelInput = stdin.readLineSync()?.trim() ?? '';
    final model = modelInput.isNotEmpty ? modelInput : chosen.defaultModel;

    // 4. API Key (hidden)
    final apiKey = await _readSecretInput(
      prompt: '  API Key (leave blank for local models): ',
      theme: theme,
      out: out,
    );

    final config = existingConfig ?? await NibConfig.load();
    config.defaultProvider = providerName;
    config.defaultModel = model;

    final provConfig = ProviderConfig(
      name: providerName,
      model: model,
      baseUrl: baseUrl,
      apiKey: apiKey,
      protocol: chosen.id,
    );
    config.providers[providerName] = provConfig;

    await config.save();

    out.writeLine('');
    out.writeLine(
      theme.success.text(
        '  ✔ Saved provider "$providerName" to ~/.nib/config.json!',
      ),
    );
    out.writeLine(
      '  Active: ${theme.accent.text(providerName)} | Model: ${theme.accent.text(model)} | Endpoint: ${theme.muted.text(baseUrl)}',
    );
    out.writeLine('');

    return config;
  }

  static void _renderProtocolMenu(
    int selected,
    NibTheme theme,
    TranscriptWriter out,
  ) {
    out.writeLine(
      '  ${theme.muted.text('╭──')} ${theme.accent.text('Select Endpoint Protocol')} ${theme.muted.text('─' * 20)}',
    );
    for (int i = 0; i < protocols.length; i++) {
      final p = protocols[i];
      final isSelected = i == selected;
      final pointer = isSelected ? theme.accent.text('▸') : ' ';
      final indexStr = theme.secondary.text('[${i + 1}]');

      if (isSelected) {
        out.writeLine(
          '    $pointer $indexStr ${theme.surface.bg}${theme.accent.text(" ${p.label} ")}\x1B[0m',
        );
      } else {
        out.writeLine('    $pointer $indexStr ${theme.primary.text(p.label)}');
      }
    }
    out.writeLine('  ${theme.muted.text('╰──${'─' * 45}')}');
    out.writeLine(
      '  ${theme.muted.text('Use ↑/↓ arrows to navigate, Enter to select, 1-${protocols.length} to choose')}',
    );
  }

  static void _clearMenu(int count, TranscriptWriter out) {
    out.rewind(count + 3);
  }

  static Future<String> _readSecretInput({
    required String prompt,
    required NibTheme theme,
    required TranscriptWriter out,
  }) async {
    stdout.write(prompt);
    final buffer = StringBuffer();

    while (true) {
      final key = await TerminalManager.instance.nextKey();
      if (key.isControl) {
        if (key.controlChar == ControlCharacter.enter) {
          stdout.writeln();
          return buffer.toString().trim();
        } else if (key.controlChar == ControlCharacter.backspace) {
          if (buffer.isNotEmpty) {
            final s = buffer.toString();
            buffer.clear();
            buffer.write(s.substring(0, s.length - 1));
            stdout.write('\b \b');
          }
        } else if (key.controlChar == ControlCharacter.ctrlC) {
          stdout.writeln();
          return '';
        }
      } else {
        final c = key.char;
        if (c.isNotEmpty && c.codeUnitAt(0) >= 32) {
          buffer.write(c);
          stdout.write('*');
        }
      }
    }
  }
}
