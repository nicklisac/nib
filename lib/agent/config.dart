import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class ProviderConfig {
  final String name;
  final String model;
  final String baseUrl;
  final String apiKey;
  final int? contextWindow;
  final int? maxTokens;

  /// Per-provider overrides for the agent tool-loop ceilings. The active
  /// provider's value wins over the top-level one, since the right ceiling
  /// depends on which model is answering.
  final int? maxTurns;
  final int? maxStuckIterations;
  final int? hardIterationCap;
  final String? protocol; // 'openai' or 'anthropic'
  final String? thinkingLevel;
  final bool? supportsImages;

  ProviderConfig({
    required this.name,
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    this.protocol,
    this.contextWindow,
    this.maxTokens,
    this.maxTurns,
    this.maxStuckIterations,
    this.hardIterationCap,
    this.thinkingLevel,
    this.supportsImages,
  });

  factory ProviderConfig.fromJson(String id, Map<String, dynamic> json) {
    final baseUrl = (json['base_url'] as String? ?? 'https://api.openai.com/v1')
        .replaceAll(RegExp(r'/+$'), '');
    final name = json['name'] as String? ?? id;
    final explicitProto = json['protocol'] as String?;
    final proto =
        explicitProto ??
        (name.toLowerCase().contains('anthropic') ||
                baseUrl.contains('anthropic.com')
            ? 'anthropic'
            : 'openai');

    return ProviderConfig(
      name: name,
      model: json['model'] as String? ?? 'default',
      baseUrl: baseUrl,
      apiKey: json['api_key'] as String? ?? '',
      protocol: proto,
      contextWindow: (json['context_window'] as num?)?.toInt(),
      maxTokens: (json['max_tokens'] as num?)?.toInt(),
      maxTurns: (json['max_turns'] as num?)?.toInt(),
      maxStuckIterations: (json['max_stuck_iterations'] as num?)?.toInt(),
      hardIterationCap: (json['hard_iteration_cap'] as num?)?.toInt(),
      thinkingLevel: json['thinking_level'] as String?,
      supportsImages: json['supports_images'] as bool?,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'model': model,
    'base_url': baseUrl,
    'api_key': apiKey,
    if (protocol != null) 'protocol': protocol,
    if (contextWindow != null) 'context_window': contextWindow,
    if (maxTokens != null) 'max_tokens': maxTokens,
    if (maxTurns != null) 'max_turns': maxTurns,
    if (maxStuckIterations != null) 'max_stuck_iterations': maxStuckIterations,
    if (hardIterationCap != null) 'hard_iteration_cap': hardIterationCap,
    if (thinkingLevel != null) 'thinking_level': thinkingLevel,
    if (supportsImages != null) 'supports_images': supportsImages,
  };
}

/// Manages Nib configuration loaded from ~/.nib/config.json (or ~/.tart / ~/.tau config fallback).
class NibConfig {
  String defaultProvider;
  String? defaultModel;
  final Map<String, ProviderConfig> providers;
  String? systemPromptAppend;
  int? contextWindow;
  int? maxTokens;

  /// Agent tool-loop ceilings, read from config so they track the model in use
  /// rather than a value baked into the binary. `0` disables a ceiling.
  ///
  /// [maxTurns] is a per-prompt ceiling and defaults to `0` (unbounded): a fixed
  /// low cap aborts valid work, which is why the historical 20-iteration limit
  /// was removed. [maxStuckIterations] is the real guard, stopping the loop once
  /// the same tool call returning the same result repeats too often.
  /// [hardIterationCap] is a backstop for a misbehaving provider.
  final int maxTurns;
  final int maxStuckIterations;
  final int hardIterationCap;
  final Map<String, dynamic> keybindings;
  String? searchProvider;
  final String? thinkingLevel;

  NibConfig({
    this.defaultProvider = 'auto',
    this.defaultModel,
    Map<String, ProviderConfig>? providers,
    this.systemPromptAppend,
    this.contextWindow,
    this.maxTokens,
    this.maxTurns = 0,
    this.maxStuckIterations = 5,
    this.hardIterationCap = 200,
    Map<String, dynamic>? keybindings,
    this.searchProvider,
    this.thinkingLevel,
  }) : providers = providers ?? {},
       keybindings = keybindings ?? {};

  /// Look up a provider profile by ID (case-insensitive)
  ProviderConfig? findProvider(String? id) {
    if (id == null || id.isEmpty) return null;
    if (providers.containsKey(id)) return providers[id];
    final lower = id.toLowerCase();
    for (final entry in providers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  ///
  /// Returned text is appended after the global APPEND_SYSTEM.md so per-project
  /// conventions, doc pointers, and the issue-tracker location reach the model.
  /// Capped to protect the context window from an oversized file.
  static Future<String?> loadProjectInstructions(
    String workspacePath, {
    int maxChars = 12000,
  }) async {
    for (final fileName in const ['AGENTS.md', 'CLAUDE.md']) {
      final file = File(p.join(workspacePath, fileName));
      if (!await file.exists()) continue;
      try {
        var text = (await file.readAsString()).trim();
        if (text.isEmpty) continue;
        if (text.length > maxChars) {
          final omitted = text.length - maxChars;
          text =
              '${text.substring(0, maxChars)}\n\n[$fileName truncated: $omitted '
              'characters omitted. Read the file directly for the rest.]';
        }
        return '## Project instructions (from $fileName)\n\n$text';
      } catch (_) {
        // An unreadable instructions file must never block startup.
      }
    }
    return null;
  }

  /// Loads configuration from custom path, workspace `.nib/config.json`, or `~/.nib/config.json`.
  /// If no file exists, auto-detects standard environment variables.
  static Future<NibConfig> load({String? customPath}) async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final env = Platform.environment;

    // Candidate configuration paths in priority order
    final candidates = customPath != null
        ? <String>[customPath]
        : <String>[
            p.join(Directory.current.path, '.nib', 'config.json'),
            if (home.isNotEmpty) p.join(home, '.nib', 'config.json'),
          ];

    for (final configPath in candidates) {
      if (await File(configPath).exists()) {
        try {
          final content = await File(configPath).readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final providersMap = <String, ProviderConfig>{};

          if (json.containsKey('providers') && json['providers'] is Map) {
            final provs = json['providers'] as Map<String, dynamic>;
            for (final entry in provs.entries) {
              if (entry.value is Map<String, dynamic>) {
                providersMap[entry.key] = ProviderConfig.fromJson(
                  entry.key,
                  entry.value as Map<String, dynamic>,
                );
              }
            }
          }

          // Check for append system prompt
          String? appendPrompt;
          final appendFile = File(
            p.join(p.dirname(configPath), 'APPEND_SYSTEM.md'),
          );
          if (await appendFile.exists()) {
            appendPrompt = await appendFile.readAsString();
          }

          final defProvider =
              json['default_provider'] as String? ??
              (providersMap.isNotEmpty ? providersMap.keys.first : 'auto');

          return NibConfig(
            defaultProvider: defProvider,
            defaultModel: json['default_model'] as String?,
            providers: providersMap,
            systemPromptAppend: appendPrompt,
            contextWindow: (json['context_window'] as num?)?.toInt(),
            maxTokens: (json['max_tokens'] as num?)?.toInt(),
            maxTurns: (json['max_turns'] as num?)?.toInt() ?? 0,
            maxStuckIterations:
                (json['max_stuck_iterations'] as num?)?.toInt() ?? 5,
            hardIterationCap:
                (json['hard_iteration_cap'] as num?)?.toInt() ?? 200,
            keybindings: json['keybindings'] is Map
                ? Map<String, dynamic>.from(json['keybindings'] as Map)
                : null,
            searchProvider: json['search_provider'] as String?,
            thinkingLevel: json['thinking_level'] as String?,
          );
        } catch (_) {
          // Try next candidate
        }
      }
    }

    // No config file found: auto-detect standard provider environment variables
    final autoProviders = <String, ProviderConfig>{};
    String? detectedDefault;

    if (env['ANTHROPIC_API_KEY']?.isNotEmpty == true) {
      autoProviders['anthropic'] = ProviderConfig(
        name: 'anthropic',
        model: 'claude-3-7-sonnet-20250219',
        baseUrl: 'https://api.anthropic.com',
        apiKey: env['ANTHROPIC_API_KEY']!,
      );
      detectedDefault ??= 'anthropic';
    }

    if (env['OPENAI_API_KEY']?.isNotEmpty == true) {
      autoProviders['openai'] = ProviderConfig(
        name: 'openai',
        model: 'gpt-4o',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: env['OPENAI_API_KEY']!,
      );
      detectedDefault ??= 'openai';
    }

    if (env['OPENROUTER_API_KEY']?.isNotEmpty == true) {
      autoProviders['openrouter'] = ProviderConfig(
        name: 'openrouter',
        model: 'anthropic/claude-3.7-sonnet',
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: env['OPENROUTER_API_KEY']!,
      );
      detectedDefault ??= 'openrouter';
    }

    if (env['GEMINI_API_KEY']?.isNotEmpty == true) {
      autoProviders['gemini'] = ProviderConfig(
        name: 'gemini',
        model: 'gemini-2.5-flash',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        apiKey: env['GEMINI_API_KEY']!,
      );
      detectedDefault ??= 'gemini';
    }

    if (env.containsKey('OLLAMA_BASE_URL') || env.containsKey('OLLAMA_MODEL')) {
      autoProviders['ollama'] = ProviderConfig(
        name: 'ollama',
        model: env['OLLAMA_MODEL'] ?? 'llama3.1',
        baseUrl: env['OLLAMA_BASE_URL'] ?? 'http://localhost:11434/v1',
        apiKey: 'ollama',
      );
      detectedDefault ??= 'ollama';
    }

    return NibConfig(
      defaultProvider: detectedDefault ?? 'none',
      providers: autoProviders,
    );
  }

  /// Saves the current config to ~/.nib/config.json
  Future<void> save({String? customPath}) async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final targetPath = customPath ?? p.join(home, '.nib', 'config.json');
    final file = File(targetPath);
    await file.parent.create(recursive: true);

    final map = {
      'default_provider': defaultProvider,
      if (defaultModel != null) 'default_model': defaultModel,
      if (contextWindow != null) 'context_window': contextWindow,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (maxTurns != 0) 'max_turns': maxTurns,
      if (maxStuckIterations != 5) 'max_stuck_iterations': maxStuckIterations,
      if (hardIterationCap != 200) 'hard_iteration_cap': hardIterationCap,
      if (keybindings.isNotEmpty) 'keybindings': keybindings,
      if (searchProvider != null) 'search_provider': searchProvider,
      if (thinkingLevel != null) 'thinking_level': thinkingLevel,
      'providers': providers.map((k, v) => MapEntry(k, v.toJson())),
    };

    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(map));
  }
}
