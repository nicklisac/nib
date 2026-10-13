import 'dart:convert';
import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'package:http/http.dart' as http;
import '../agent/config.dart';
import 'terminal_manager.dart';
import 'theme.dart';
import 'transcript_writer.dart';

class DiscoveredModel {
  final String id;
  final int? contextWindow;
  final int? maxTokens;

  const DiscoveredModel({required this.id, this.contextWindow, this.maxTokens});
}

class ProtocolOption {
  final String id; // 'openai' or 'anthropic'
  final String label;
  final String defaultBaseUrl;
  final String defaultName;

  const ProtocolOption({
    required this.id,
    required this.label,
    required this.defaultBaseUrl,
    required this.defaultName,
  });
}

const List<ProtocolOption> protocols = [
  ProtocolOption(
    id: 'openai',
    label: 'OpenAI API Compatible (OpenAI, OpenRouter, Ollama, vLLM, etc.)',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultName: 'openai',
  ),
  ProtocolOption(
    id: 'anthropic',
    label: 'Anthropic (Claude Messages API)',
    defaultBaseUrl: 'https://api.anthropic.com',
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
          case ControlCharacter.escape:
            _clearMenu(protocols.length, out);
            out.writeLine(theme.muted.text('  Setup cancelled.'));
            return null;
          default:
            break;
        }
      } else {
        final char = key.char;
        if (char == 'q' ||
            char == 'Q' ||
            char == '\x1B' ||
            key.char == '\x1B') {
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
    final providerName = await _readLineInput(
      prompt: '  Provider name [${chosen.defaultName}]: ',
      defaultValue: chosen.defaultName,
    );

    // 2. Base URL / Endpoint
    final baseUrl = await _readLineInput(
      prompt: '  Base URL [${chosen.defaultBaseUrl}]: ',
      defaultValue: chosen.defaultBaseUrl,
    );

    // 3. API Key (hidden, enter before model so we can query API for models)
    final apiKey = await _readSecretInput(
      prompt: '  API Key (leave blank for local models): ',
      theme: theme,
      out: out,
    );

    // 4. Model selection (query API if possible, else prompt)
    final modelInfo = await _selectOrInputModel(
      protocol: chosen.id,
      baseUrl: baseUrl,
      apiKey: apiKey,
      theme: theme,
      out: out,
    );
    final model = modelInfo.id;

    // 5. Optional Advanced Settings (Enter to accept/skip)
    out.writeLine('');
    out.writeLine(
      theme.muted.text(
        '  Optional Settings (Press Enter to keep default / skip):',
      ),
    );

    final defaultCtxStr = modelInfo.contextWindow != null
        ? '${modelInfo.contextWindow}'
        : '';
    final ctxPrompt = defaultCtxStr.isNotEmpty
        ? '  Context window [$defaultCtxStr]: '
        : '  Context window (e.g. 131072, Enter to skip): ';
    final ctxInput = await _readLineInput(
      prompt: ctxPrompt,
      defaultValue: defaultCtxStr,
    );
    final contextWindow = int.tryParse(ctxInput);

    final defaultMaxStr = modelInfo.maxTokens != null
        ? '${modelInfo.maxTokens}'
        : '';
    final maxTokensPrompt = defaultMaxStr.isNotEmpty
        ? '  Max output tokens [$defaultMaxStr]: '
        : '  Max output tokens (e.g. 8192, Enter to skip): ';
    final maxTokensInput = await _readLineInput(
      prompt: maxTokensPrompt,
      defaultValue: defaultMaxStr,
    );
    final maxTokens = int.tryParse(maxTokensInput);

    final imgInput = await _readLineInput(
      prompt: '  Supports images / vision? (y/N, Enter to skip): ',
      defaultValue: '',
    );
    final bool? supportsImages = imgInput.toLowerCase().startsWith('y')
        ? true
        : (imgInput.toLowerCase().startsWith('n') ? false : null);

    final config = existingConfig ?? await NibConfig.load();
    config.defaultProvider = providerName;
    config.defaultModel = model;

    // 6. Optional Web Search Provider Setup (Enter to skip)
    out.writeLine('');
    final currentSearch = config.searchProvider;
    final searchHint = currentSearch != null ? ' [$currentSearch]' : '';
    out.writeLine(
      theme.muted.text(
        '  Web Search Provider (Optional: exa, tavily, brave, or Enter to skip):',
      ),
    );
    out.writeLine(
      theme.muted.text(
        '  (Hint: If skipped, Nib can help you set up or configure search anytime)',
      ),
    );
    final searchInput = await _readLineInput(
      prompt: '  Search provider$searchHint: ',
      defaultValue: currentSearch ?? '',
    );
    if (searchInput.isNotEmpty) {
      config.searchProvider = searchInput.toLowerCase();
    }

    final provConfig = ProviderConfig(
      name: providerName,
      model: model,
      baseUrl: baseUrl,
      apiKey: apiKey,
      protocol: chosen.id,
      contextWindow: contextWindow,
      maxTokens: maxTokens,
      supportsImages: supportsImages,
    );
    config.providers[providerName] = provConfig;

    await config.save();

    out.writeLine('');
    out.writeLine(
      theme.success.text(
        '  ✔ Saved provider "$providerName" to ~/.nib/config.json!',
      ),
    );
    final details = [
      'Active: ${theme.accent.text(providerName)}',
      'Model: ${theme.accent.text(model)}',
      if (contextWindow != null)
        'Ctx: ${theme.secondary.text('$contextWindow')}',
      if (maxTokens != null) 'MaxTokens: ${theme.secondary.text('$maxTokens')}',
      if (supportsImages != null)
        'Images: ${theme.secondary.text(supportsImages ? "yes" : "no")}',
      if (config.searchProvider != null)
        'Search: ${theme.secondary.text(config.searchProvider!)}',
    ].join(' | ');

    out.writeLine('  $details');
    out.writeLine('  Endpoint: ${theme.muted.text(baseUrl)}');
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

  static Future<String> _readLineInput({
    required String prompt,
    required String defaultValue,
  }) async {
    stdout.write(prompt);
    final buffer = StringBuffer();

    while (true) {
      final event = await TerminalManager.instance.nextInput();
      if (event is PasteBlob) {
        // Handle bracketed paste directly
        final pasted = event.text
            .replaceAll('\r\n', '')
            .replaceAll('\n', '')
            .replaceAll('\r', '');
        buffer.write(pasted);
        stdout.write(pasted);
      } else if (event is Key) {
        final key = event;
        if (key.isControl) {
          if (key.controlChar == ControlCharacter.enter) {
            stdout.writeln();
            final val = buffer.toString().trim();
            return val.isNotEmpty ? val : defaultValue;
          } else if (key.controlChar == ControlCharacter.backspace) {
            if (buffer.isNotEmpty) {
              final s = buffer.toString();
              buffer.clear();
              buffer.write(s.substring(0, s.length - 1));
              stdout.write('\b \b');
            }
          } else if (key.controlChar == ControlCharacter.ctrlC ||
              key.controlChar == ControlCharacter.escape) {
            stdout.writeln();
            return defaultValue;
          }
        } else {
          final c = key.char;
          if (c.isNotEmpty && c.codeUnitAt(0) >= 32) {
            buffer.write(c);
            stdout.write(c);
          }
        }
      }
    }
  }

  static Future<String> _readSecretInput({
    required String prompt,
    required NibTheme theme,
    required TranscriptWriter out,
  }) async {
    stdout.write(prompt);
    final buffer = StringBuffer();

    while (true) {
      final event = await TerminalManager.instance.nextInput();
      if (event is PasteBlob) {
        final pasted = event.text
            .replaceAll('\r\n', '')
            .replaceAll('\n', '')
            .replaceAll('\r', '');
        buffer.write(pasted);
        stdout.write('*' * pasted.length);
      } else if (event is Key) {
        final key = event;
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
          } else if (key.controlChar == ControlCharacter.ctrlC ||
              key.controlChar == ControlCharacter.escape) {
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

  static Future<DiscoveredModel> _selectOrInputModel({
    required String protocol,
    required String baseUrl,
    required String apiKey,
    required NibTheme theme,
    required TranscriptWriter out,
  }) async {
    out.writeLine(
      theme.muted.text('  Discovering available models from endpoint...'),
    );
    final fetched = await _fetchModels(
      protocol: protocol,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );

    if (fetched.isNotEmpty) {
      out.writeLine(theme.success.text('  Found ${fetched.length} models:'));
      out.writeLine('');

      var selectedIndex = 0;
      _renderModelMenu(fetched, selectedIndex, theme, out);

      while (true) {
        final event = await TerminalManager.instance.nextInput();
        if (event is Key) {
          final key = event;
          if (key.isControl) {
            switch (key.controlChar) {
              case ControlCharacter.arrowUp:
                selectedIndex =
                    (selectedIndex - 1 + fetched.length) % fetched.length;
                _clearModelMenu(fetched.length, out);
                _renderModelMenu(fetched, selectedIndex, theme, out);
                break;
              case ControlCharacter.arrowDown:
                selectedIndex = (selectedIndex + 1) % fetched.length;
                _clearModelMenu(fetched.length, out);
                _renderModelMenu(fetched, selectedIndex, theme, out);
                break;
              case ControlCharacter.enter:
                _clearModelMenu(fetched.length, out);
                final chosen = fetched[selectedIndex];
                out.writeLine('  Model: ${theme.accent.text(chosen.id)}');
                return chosen;
              case ControlCharacter.ctrlC:
              case ControlCharacter.escape:
                _clearModelMenu(fetched.length, out);
                break;
              default:
                break;
            }
          } else {
            final char = key.char;
            final numVal = int.tryParse(char);
            if (numVal != null && numVal >= 1 && numVal <= fetched.length) {
              _clearModelMenu(fetched.length, out);
              final chosen = fetched[numVal - 1];
              out.writeLine('  Model: ${theme.accent.text(chosen.id)}');
              return chosen;
            }
          }
        }
      }
    } else {
      out.writeLine(
        theme.muted.text('(could not auto-fetch models from /models)'),
      );
      out.writeLine('');
      final name = await _readLineInput(
        prompt: '  Model name: ',
        defaultValue: '',
      );
      return DiscoveredModel(id: name);
    }
  }

  static Future<List<DiscoveredModel>> _fetchModels({
    required String protocol,
    required String baseUrl,
    required String apiKey,
  }) async {
    try {
      final cleanBase = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;

      final Uri uri;
      final Map<String, String> headers = {'Accept': 'application/json'};

      if (protocol == 'openai') {
        // OpenAI / vLLM / tabbyAPI / Ollama / OpenRouter
        final modelsUrl = cleanBase.endsWith('/v1')
            ? '$cleanBase/models'
            : '$cleanBase/v1/models';
        uri = Uri.parse(modelsUrl);
        if (apiKey.isNotEmpty) {
          headers['Authorization'] = 'Bearer $apiKey';
        }
      } else {
        // Anthropic Messages API
        uri = Uri.parse('$cleanBase/v1/models');
        if (apiKey.isNotEmpty) {
          headers['x-api-key'] = apiKey;
        }
        headers['anthropic-version'] = '2023-06-01';
      }

      final res = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic> && decoded['data'] is List) {
          final list = decoded['data'] as List;
          final models = <DiscoveredModel>[];
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              final id = item['id'] as String?;
              if (id != null && id.isNotEmpty) {
                int? ctx;
                int? maxOut;
                // Parse context window if available from provider (tabbyAPI, vLLM, ollama, etc.)
                if (item['context_length'] is num) {
                  ctx = (item['context_length'] as num).toInt();
                } else if (item['max_model_len'] is num) {
                  ctx = (item['max_model_len'] as num).toInt();
                } else if (item['meta'] is Map &&
                    item['meta']['n_ctx_train'] is num) {
                  ctx = (item['meta']['n_ctx_train'] as num).toInt();
                }

                if (item['max_tokens'] is num) {
                  maxOut = (item['max_tokens'] as num).toInt();
                } else if (item['max_output_tokens'] is num) {
                  maxOut = (item['max_output_tokens'] as num).toInt();
                }

                models.add(
                  DiscoveredModel(
                    id: id,
                    contextWindow: ctx,
                    maxTokens: maxOut,
                  ),
                );
              }
            }
          }

          if (models.isNotEmpty) {
            return models;
          }
        }
      }
    } catch (_) {}
    return [];
  }

  static void _renderModelMenu(
    List<DiscoveredModel> models,
    int selected,
    NibTheme theme,
    TranscriptWriter out,
  ) {
    out.writeLine(
      '  ${theme.muted.text('╭──')} ${theme.accent.text('Select Model from Endpoint')} ${theme.muted.text('─' * 20)}',
    );
    for (int i = 0; i < models.length; i++) {
      final m = models[i];
      final isSelected = i == selected;
      final pointer = isSelected ? theme.accent.text('▸') : ' ';
      final indexStr = theme.secondary.text('[${i + 1}]');

      final ctxTag = m.contextWindow != null
          ? ' ${theme.muted.text('(${m.contextWindow} ctx)')}'
          : '';

      if (isSelected) {
        out.writeLine(
          '    $pointer $indexStr ${theme.surface.bg}${theme.accent.text(" ${m.id} ")}\x1B[0m$ctxTag',
        );
      } else {
        out.writeLine(
          '    $pointer $indexStr ${theme.primary.text(m.id)}$ctxTag',
        );
      }
    }
    out.writeLine('  ${theme.muted.text('╰──${'─' * 45}')}');
    out.writeLine(
      '  ${theme.muted.text('Use ↑/↓ arrows to navigate, Enter to select, 1-${models.length} to choose')}',
    );
  }

  static void _clearModelMenu(int count, TranscriptWriter out) {
    out.rewind(count + 3);
  }
}
