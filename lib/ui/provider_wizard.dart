import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../agent/config.dart';
import 'terminal_manager.dart';
import 'theme.dart';
import 'transcript_writer.dart';

class ProviderOption {
  final String id;
  final String label;
  final String defaultModel;
  final String defaultBaseUrl;
  final String keyHelp;
  final bool requiresKey;

  const ProviderOption({
    required this.id,
    required this.label,
    required this.defaultModel,
    required this.defaultBaseUrl,
    required this.keyHelp,
    this.requiresKey = true,
  });
}

const List<ProviderOption> knownProviders = [
  ProviderOption(
    id: 'anthropic',
    label: 'Anthropic Claude (Recommended)',
    defaultModel: 'claude-3-7-sonnet-20250219',
    defaultBaseUrl: 'https://api.anthropic.com',
    keyHelp: 'sk-ant-...',
  ),
  ProviderOption(
    id: 'openai',
    label: 'OpenAI (GPT-4o)',
    defaultModel: 'gpt-4o',
    defaultBaseUrl: 'https://api.openai.com/v1',
    keyHelp: 'sk-...',
  ),
  ProviderOption(
    id: 'openrouter',
    label: 'OpenRouter (Multi-provider aggregator)',
    defaultModel: 'anthropic/claude-3.7-sonnet',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
    keyHelp: 'sk-or-...',
  ),
  ProviderOption(
    id: 'gemini',
    label: 'Google Gemini',
    defaultModel: 'gemini-2.5-flash',
    defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    keyHelp: 'AIza...',
  ),
  ProviderOption(
    id: 'ollama',
    label: 'Ollama (Local, offline)',
    defaultModel: 'llama3.1',
    defaultBaseUrl: 'http://localhost:11434/v1',
    keyHelp: 'none needed (localhost)',
    requiresKey: false,
  ),
  ProviderOption(
    id: 'mock',
    label: 'Demo Mode (Mock agent, offline simulation)',
    defaultModel: 'mock-agent-v1',
    defaultBaseUrl: '',
    keyHelp: 'none needed',
    requiresKey: false,
  ),
];

/// Interactive provider setup wizard (similar to Pi and Tau).
class ProviderSetupWizard {
  /// Runs the interactive terminal setup wizard and saves chosen config.
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
      '  ${theme.muted.text('│')}   Choose your AI model provider to get started.',
    );
    out.writeLine(
      '  ${theme.accent.text('╰───────────────────────────────────────────────────────────────────')}',
    );
    out.writeLine('');

    var selectedIndex = 0;
    _renderProviderMenu(selectedIndex, theme, out);

    ProviderOption? chosenProvider;

    while (true) {
      final key = await TerminalManager.instance.nextKey();
      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.arrowUp:
            selectedIndex =
                (selectedIndex - 1 + knownProviders.length) %
                knownProviders.length;
            _clearMenu(knownProviders.length, out);
            _renderProviderMenu(selectedIndex, theme, out);
            break;
          case ControlCharacter.arrowDown:
            selectedIndex = (selectedIndex + 1) % knownProviders.length;
            _clearMenu(knownProviders.length, out);
            _renderProviderMenu(selectedIndex, theme, out);
            break;
          case ControlCharacter.enter:
            _clearMenu(knownProviders.length, out);
            chosenProvider = knownProviders[selectedIndex];
            break;
          case ControlCharacter.ctrlC:
            _clearMenu(knownProviders.length, out);
            out.writeLine(theme.muted.text('  Setup cancelled.'));
            return null;
          default:
            break;
        }
      } else {
        final char = key.char;
        if (char == 'q' || char == 'Q' || char == '\x1B') {
          _clearMenu(knownProviders.length, out);
          out.writeLine(theme.muted.text('  Setup cancelled.'));
          return null;
        }
        final numVal = int.tryParse(char);
        if (numVal != null && numVal >= 1 && numVal <= knownProviders.length) {
          _clearMenu(knownProviders.length, out);
          chosenProvider = knownProviders[numVal - 1];
        }
      }

      if (chosenProvider != null) break;
    }

    out.writeLine(
      '  Selected provider: ${theme.accent.text(chosenProvider.label)}',
    );
    out.writeLine('');

    if (chosenProvider.id == 'mock') {
      out.writeLine(theme.success.text('  ✔ Configured offline demo mode.'));
      out.writeLine('');
      final config = existingConfig ?? await NibConfig.load();
      config.defaultProvider = 'mock';
      await config.save();
      return config;
    }

    // Prompt for API key if required
    var apiKey = '';
    if (chosenProvider.requiresKey) {
      apiKey = await _readSecretInput(
        prompt: '  Enter API Key (${chosenProvider.keyHelp}): ',
        theme: theme,
        out: out,
      );
      if (apiKey.trim().isEmpty) {
        // Check if environment has it
        final envVar = switch (chosenProvider.id) {
          'anthropic' => 'ANTHROPIC_API_KEY',
          'openai' => 'OPENAI_API_KEY',
          'openrouter' => 'OPENROUTER_API_KEY',
          'gemini' => 'GEMINI_API_KEY',
          _ => null,
        };
        final fromEnv = envVar != null ? Platform.environment[envVar] : null;
        if (fromEnv != null && fromEnv.isNotEmpty) {
          apiKey = fromEnv;
          out.writeLine(
            theme.success.text('  ✔ Using existing $envVar from environment.'),
          );
        } else {
          out.writeLine(
            theme.warning.text(
              '  No API key provided. You can set it later or in ~/.nib/config.json.',
            ),
          );
        }
      }
    } else {
      apiKey = chosenProvider.id == 'ollama' ? 'ollama' : '';
    }

    // Prompt for model with default
    stdout.write('  Model [${chosenProvider.defaultModel}]: ');
    final modelInput = stdin.readLineSync()?.trim() ?? '';
    final model = modelInput.isNotEmpty
        ? modelInput
        : chosenProvider.defaultModel;

    // Prompt for custom base URL if Ollama or OpenAI
    var baseUrl = chosenProvider.defaultBaseUrl;
    if (chosenProvider.id == 'ollama') {
      stdout.write('  Endpoint [${chosenProvider.defaultBaseUrl}]: ');
      final urlInput = stdin.readLineSync()?.trim() ?? '';
      if (urlInput.isNotEmpty) baseUrl = urlInput;
    }

    final config = existingConfig ?? await NibConfig.load();
    config.defaultProvider = chosenProvider.id;
    config.defaultModel = model;

    final provConfig = ProviderConfig(
      name: chosenProvider.id,
      model: model,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
    config.providers[chosenProvider.id] = provConfig;

    await config.save();

    out.writeLine('');
    out.writeLine(
      theme.success.text('  ✔ Saved configuration to ~/.nib/config.json!'),
    );
    out.writeLine(
      '  Provider: ${theme.accent.text(chosenProvider.id)} | Model: ${theme.accent.text(model)}',
    );
    out.writeLine('');

    return config;
  }

  static void _renderProviderMenu(
    int selected,
    NibTheme theme,
    TranscriptWriter out,
  ) {
    out.writeLine(
      '  ${theme.muted.text('╭──')} ${theme.accent.text('Select Provider')} ${theme.muted.text('─' * 28)}',
    );
    for (int i = 0; i < knownProviders.length; i++) {
      final p = knownProviders[i];
      final isSelected = i == selected;
      final pointer = isSelected ? theme.accent.text('▸') : ' ';
      final indexStr = theme.secondary.text('[${i + 1}]');

      if (isSelected) {
        out.writeLine(
          '    $pointer $indexStr ${theme.surface.bg}${theme.accent.text(" ${p.label} ")}\x1B[0m ${theme.muted.text("(${p.defaultModel})")}',
        );
      } else {
        out.writeLine(
          '    $pointer $indexStr ${theme.primary.text(p.label)} ${theme.muted.text("(${p.defaultModel})")}',
        );
      }
    }
    out.writeLine('  ${theme.muted.text('╰──${'─' * 45}')}');
    out.writeLine(
      '  ${theme.muted.text('Use ↑/↓ arrows to navigate, Enter to choose, 1-${knownProviders.length} to select, Esc to cancel')}',
    );
  }

  static void _clearMenu(int count, TranscriptWriter out) {
    // 1 top + count rows + 1 bottom + 1 hint = count + 3 lines
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
