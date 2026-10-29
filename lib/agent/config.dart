import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

final _dollarForm = RegExp(r'^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$');
final _bareEnvName = RegExp(r'^([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)$');
final _warnedSecrets = <String>{};

/// Turns a config value into the actual secret. A key field may hold either the
/// key itself or the *name* of an environment variable that holds it
/// (`OPENAI_API_KEY`, `$OPENAI_API_KEY` or `${OPENAI_API_KEY}`).
///
/// A bare name is recognised only when it looks like one (capitals, digits and at
/// least one underscore), which no real key does. If the variable is named but
/// unset, this says so on stderr (once) and returns an empty key, rather than
/// sending the variable's name to the server as if it were the key.
String resolveSecret(
  String raw, {
  String label = 'api_key',
  Map<String, String>? env,
  void Function(String message)? warn,
}) {
  final value = raw.trim();
  final match = _dollarForm.firstMatch(value) ?? _bareEnvName.firstMatch(value);
  if (match == null) return raw;
  final name = match.group(1)!;
  final found = (env ?? Platform.environment)[name];
  if (found != null && found.isNotEmpty) return found;
  final message =
      '$label points at the environment variable $name, but it is not set.';
  if (_warnedSecrets.add(message)) {
    (warn ?? (m) => stderr.writeln('  ⚠ $m'))(message);
  }
  return '';
}

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

  /// [apiKey] as written in config: a literal key or an environment variable name.
  /// This is the value to use when talking to the provider.
  String get resolvedApiKey =>
      resolveSecret(apiKey, label: 'api_key for "$name"');

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

/// Metadata describing an opt-in experimental harness feature.
class ExperimentSpec {
  final String id;
  final String description;

  const ExperimentSpec({required this.id, required this.description});
}

/// Manages Nib configuration loaded from ~/.nib/config.json (or ~/.tart / ~/.tau config fallback).
class NibConfig {
  /// Built-in catalog of experimental features available to toggle via `/experiments`.
  static const List<ExperimentSpec> knownExperiments = [
    ExperimentSpec(
      id: 'rewind_reads',
      description:
          'Replace dead-end read-only tool turns with a short note (context neuralizer)',
    ),
    ExperimentSpec(
      id: 'post_bundle_check',
      description:
          'Run the project check command after each edit bundle (#54); needs check.command in workspace .nib/config.json',
    ),
  ];

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

  /// Per-experiment opt-in flags (e.g. `{"rewind_reads": true}`). Disabled by
  /// default so unpromoted experiments add zero startup overhead and zero
  /// prompt tokens (#36, #41, #53).
  final Map<String, bool> experiments;
  String? searchProvider;
  String? searchApiKey;

  /// [searchApiKey] as written in config (a literal key or an environment
  /// variable name), resolved for use.
  String? get resolvedSearchApiKey {
    final raw = searchApiKey;
    if (raw == null || raw.isEmpty) return raw;
    return resolveSecret(raw, label: 'search_api_key');
  }

  final String? thinkingLevel;

  /// Path of the config file this instance was loaded from (if any), so
  /// in-session mutations (like `/experiments`) save back to the same file.
  String? loadedFromPath;

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
    Map<String, bool>? experiments,
    this.searchProvider,
    this.searchApiKey,
    this.thinkingLevel,
    this.loadedFromPath,
  }) : providers = providers ?? {},
       keybindings = keybindings ?? {},
       experiments = experiments ?? {};

  /// True when the named experiment flag is explicitly enabled in config.
  bool isExperimentEnabled(String name) => experiments[name] == true;

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

  /// Per-project check block, read from a dedicated `.nib/check.json` in the
  /// workspace (#54).
  ///
  /// A sidecar file rather than a `check` key in `.nib/config.json`, because
  /// [load] *replaces* rather than merges (first existing file wins): the
  /// suggestion flow writing a workspace config in a project that has none
  /// would silently mask the human's entire global config. The sidecar has
  /// no such interaction. Returns null when absent or blank; blank disables
  /// the feature and nothing is ever auto-detected.
  static Future<Map<String, dynamic>?> readWorkspaceCheckBlock(
    String workspacePath,
  ) async {
    final file = File(p.join(workspacePath, '.nib', 'check.json'));
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      // Accept both shapes so hand-written and nib-written files behave the
      // same: the bare block {"command": ...} and the wrapper
      // {"check": {"command": ...}} some people will reach for by habit.
      final block = json['check'] is Map ? json['check'] : json;
      if (block is Map) return Map<String, dynamic>.from(block);
    } catch (_) {
      // A malformed workspace config must never block startup; the feature
      // simply stays inert.
    }
    return null;
  }

  /// Persist the workspace check block (#54 suggestion flow). Accepts either
  /// the bare block or a `{"check": {...}}` wrapper for symmetry with the
  /// read side; always writes the bare block.
  static Future<void> writeWorkspaceCheckBlock(
    String workspacePath,
    Map<String, dynamic> checkBlock,
  ) async {
    final block = checkBlock['check'] is Map
        ? Map<String, dynamic>.from(checkBlock['check'] as Map)
        : checkBlock;
    final dir = Directory(p.join(workspacePath, '.nib'));
    final file = File(p.join(dir.path, 'check.json'));
    if (await file.exists()) {
      // Never silently clobber a hand-written file we cannot parse.
      try {
        jsonDecode(await file.readAsString());
      } catch (_) {
        throw StateError(
          '${file.path} exists but is not valid JSON. Fix it by hand before '
          'nib writes to it.',
        );
      }
    } else {
      await dir.create(recursive: true);
    }
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(block));
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

          final experimentsMap = <String, bool>{};
          if (json['experiments'] is Map) {
            for (final entry in (json['experiments'] as Map).entries) {
              if (entry.value is bool) {
                experimentsMap[entry.key.toString()] = entry.value as bool;
              }
            }
          }

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
            experiments: experimentsMap,
            searchProvider: json['search_provider'] as String?,
            searchApiKey: json['search_api_key'] as String?,
            thinkingLevel: json['thinking_level'] as String?,
            loadedFromPath: configPath,
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

  /// Saves the current config to [customPath], [loadedFromPath], or ~/.nib/config.json.
  Future<void> save({String? customPath}) async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final targetPath =
        customPath ?? loadedFromPath ?? p.join(home, '.nib', 'config.json');
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
      if (experiments.isNotEmpty) 'experiments': experiments,
      if (searchProvider != null) 'search_provider': searchProvider,
      if (searchApiKey != null && searchApiKey!.isNotEmpty)
        'search_api_key': searchApiKey,
      if (thinkingLevel != null) 'thinking_level': thinkingLevel,
      'providers': providers.map((k, v) => MapEntry(k, v.toJson())),
    };

    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(map));
  }
}
