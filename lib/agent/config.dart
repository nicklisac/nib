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

  ProviderConfig({
    required this.name,
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    this.contextWindow,
    this.maxTokens,
  });

  factory ProviderConfig.fromJson(String id, Map<String, dynamic> json) {
    return ProviderConfig(
      name: json['name'] as String? ?? id,
      model: json['model'] as String? ?? 'default',
      baseUrl: (json['base_url'] as String? ?? 'https://api.openai.com/v1').replaceAll(RegExp(r'/+$'), ''),
      apiKey: json['api_key'] as String? ?? '',
      contextWindow: (json['context_window'] as num?)?.toInt(),
      maxTokens: (json['max_tokens'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'model': model,
        'base_url': baseUrl,
        'api_key': apiKey,
        if (contextWindow != null) 'context_window': contextWindow,
        if (maxTokens != null) 'max_tokens': maxTokens,
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

  NibConfig({
    this.defaultProvider = 'exllama',
    this.defaultModel,
    Map<String, ProviderConfig>? providers,
    this.systemPromptAppend,
    this.contextWindow,
    this.maxTokens,
  }) : providers = providers ?? {};

  /// Loads configuration from ~/.nib/config.json or falls back to ~/.tart or ~/.tau.
  static Future<NibConfig> load({String? customPath}) async {
    final home = Platform.environment['HOME'] ?? '';

    // Candidate configuration paths in priority order
    final candidates = <String>[
      if (customPath != null) customPath,
      if (home.isNotEmpty) p.join(home, '.nib', 'config.json'),
      if (home.isNotEmpty) p.join(home, '.tart', 'config.json'),
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
          final appendFile = File(p.join(p.dirname(configPath), 'APPEND_SYSTEM.md'));
          if (await appendFile.exists()) {
            appendPrompt = await appendFile.readAsString();
          }

          return NibConfig(
            defaultProvider: json['default_provider'] as String? ?? 'exllama',
            defaultModel: json['default_model'] as String?,
            providers: providersMap,
            systemPromptAppend: appendPrompt,
          );
        } catch (_) {
          // Try next candidate
        }
      }
    }

    // Fallback from ~/.tau
    return await _loadFromTauFallback(home);
  }

  static Future<TartConfig> _loadFromTauFallback(String home) async {
    final providers = <String, ProviderConfig>{};
    String defaultProvider = 'exllama';
    String? defaultModel = 'Qwen3.8-Flash-Next-exl3-3.50bpw_hq_h6_ng6';
    String? appendPrompt;

    final tauDir = p.join(home, '.tau');
    if (await Directory(tauDir).exists()) {
      // Read credentials
      final credsFile = File(p.join(tauDir, 'credentials.json'));
      final creds = <String, String>{};
      if (await credsFile.exists()) {
        try {
          final rawCreds = jsonDecode(await credsFile.readAsString()) as Map<String, dynamic>;
          for (final e in rawCreds.entries) {
            if (e.value is String) creds[e.key] = e.value as String;
          }
        } catch (_) {}
      }

      // Read config.toml manually for providers
      final configFile = File(p.join(tauDir, 'config.toml'));
      if (await configFile.exists()) {
        try {
          final lines = await configFile.readAsLines();
          String? currentSection;
          final sectionMaps = <String, Map<String, String>>{};

          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.startsWith('#') || trimmed.isEmpty) continue;

            if (trimmed.startsWith('[providers.') && trimmed.endsWith(']')) {
              currentSection = trimmed.substring(11, trimmed.length - 1);
              sectionMaps[currentSection] = {};
            } else if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
              currentSection = null;
            } else if (trimmed.contains('=')) {
              final idx = trimmed.indexOf('=');
              final key = trimmed.substring(0, idx).trim();
              var val = trimmed.substring(idx + 1).trim();
              if (val.startsWith('"') && val.endsWith('"')) {
                val = val.substring(1, val.length - 1);
              }
              if (currentSection != null) {
                sectionMaps[currentSection]?[key] = val;
              } else if (key == 'default_provider') {
                defaultProvider = val;
              } else if (key == 'default_model') {
                defaultModel = val;
              }
            }
          }

          for (final entry in sectionMaps.entries) {
            final pName = entry.key;
            final pMap = entry.value;
            final m = pMap['model'] ?? defaultModel ?? 'default';
            final url = pMap['base_url'] ?? 'http://localhost:5000/v1';
            final apiKey = creds[pName] ?? '';
            providers[pName] = ProviderConfig(
              name: pName,
              model: m,
              baseUrl: url,
              apiKey: apiKey,
            );
          }
        } catch (_) {}
      }

      // Check APPEND_SYSTEM.md
      final appendFile = File(p.join(tauDir, 'APPEND_SYSTEM.md'));
      if (await appendFile.exists()) {
        appendPrompt = await appendFile.readAsString();
      }
    }

    // Default exllama profile if none parsed
    if (!providers.containsKey('exllama')) {
      providers['exllama'] = ProviderConfig(
        name: 'exllama',
        model: 'Qwen3.8-Flash-Next-exl3-3.50bpw_hq_h6_ng6',
        baseUrl: 'http://localhost:5000/v1',
        apiKey: 'exl3-key',
      );
    }

    return NibConfig(
      defaultProvider: defaultProvider,
      defaultModel: defaultModel,
      providers: providers,
      systemPromptAppend: appendPrompt,
    );
  }

  /// Saves the current config to ~/.nib/config.json
  Future<void> save({String? customPath}) async {
    final home = Platform.environment['HOME'] ?? '';
    final targetPath = customPath ?? p.join(home, '.nib', 'config.json');
    final file = File(targetPath);
    await file.parent.create(recursive: true);

    final map = {
      'default_provider': defaultProvider,
      if (defaultModel != null) 'default_model': defaultModel,
      'providers': providers.map((k, v) => MapEntry(k, v.toJson())),
    };

    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(map));
  }
}

typedef TartConfig = NibConfig;
