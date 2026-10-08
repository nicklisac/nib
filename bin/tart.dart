import 'dart:io';
import 'package:args/args.dart';
import 'package:dart_tui/agent/agent.dart';
import 'package:dart_tui/agent/approval_manager.dart';
import 'package:dart_tui/agent/config.dart';
import 'package:dart_tui/agent/session.dart';
import 'package:dart_tui/ai/anthropic_provider.dart';
import 'package:dart_tui/ai/mock_provider.dart';
import 'package:dart_tui/ai/openai_provider.dart';
import 'package:dart_tui/ai/provider.dart';
import 'package:dart_tui/tools/bash_tool.dart';
import 'package:dart_tui/tools/edit_file_tool.dart';
import 'package:dart_tui/tools/list_dir_tool.dart';
import 'package:dart_tui/tools/read_file_tool.dart';
import 'package:dart_tui/tools/search_files_tool.dart';
import 'package:dart_tui/tools/write_file_tool.dart';
import 'package:dart_tui/ui/ansi.dart';
import 'package:dart_tui/ui/cli_ui.dart';
import 'package:dart_tui/ui/theme.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Custom config file path (default: ~/.tart/config.json with ~/.tau fallback).',
    )
    ..addOption(
      'provider',
      abbr: 'p',
      help: 'LLM provider (e.g. exllama, unsloth, openai, anthropic, ollama, mock).',
    )
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Model name (e.g. Qwen3.8-Flash-Next-exl3-3.50bpw_hq_h6_ng6, gpt-4o).',
    )
    ..addOption(
      'theme',
      abbr: 't',
      help: 'TrueColor theme (catppuccin, tokyonight, nord, gruvbox).',
      defaultsTo: 'catppuccin',
    )
    ..addFlag(
      'confirm',
      help: 'Require confirmation before writing files or running destructive commands.',
      negatable: false,
    )
    ..addOption(
      'api-key',
      abbr: 'k',
      help: 'API Key (defaults to provider config or environment variable).',
    )
    ..addOption(
      'base-url',
      help: 'Custom API base URL (e.g. http://localhost:5000/v1 for tabbyAPI/exllama).',
    )
    ..addFlag(
      'resume',
      abbr: 'r',
      help: 'Resume the most recent conversation session.',
      negatable: false,
    )
    ..addOption(
      'session',
      help: 'Resume a specific session ID.',
    )
    ..addFlag(
      'mock',
      help: 'Run in offline demo mode without calling external APIs.',
      negatable: false,
    )
    ..addFlag(
      'help',
      abbr: 'h',
      help: 'Show command help.',
      negatable: false,
    );

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error parsing arguments: $e');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    print('🥧 TART - Terminal CLI Coding Agent (in the style of Pi & Tau)');
    print('\nUsage: ./tart [options] [prompt]\n');
    print(parser.usage);
    exit(0);
  }

  // Set theme & confirmation mode
  final themeName = results['theme'] as String;
  TartTheme.setTheme(themeName);
  ApprovalManager.instance.requireConfirmation = results['confirm'] as bool;

  // Load Tart configuration (with automatic ~/.tau matching fallback)
  final explicitConfigPath = results['config'] as String?;
  final config = await TartConfig.load(customPath: explicitConfigPath);

  final isMock = results['mock'] as bool;
  final explicitProvider = results['provider'] as String?;
  final explicitModel = results['model'] as String?;
  final explicitKey = results['api-key'] as String?;
  final explicitBaseUrl = results['base-url'] as String?;

  final env = Platform.environment;

  // Determine active provider ID
  final providerId = isMock
      ? 'mock'
      : (explicitProvider ?? config.defaultProvider).toLowerCase();

  LLMProvider provider;

  if (providerId == 'mock') {
    provider = MockProvider();
  } else if (config.providers.containsKey(providerId)) {
    // Configured provider profile (e.g. exllama / unsloth from ~/.tart or ~/.tau)
    final provConf = config.providers[providerId]!;
    final model = explicitModel ?? provConf.model;
    final baseUrl = explicitBaseUrl ?? provConf.baseUrl;
    final apiKey = explicitKey ??
        (provConf.apiKey.isNotEmpty ? provConf.apiKey : env['EXLLAMA_API_KEY'] ?? '');

    provider = OpenAiProvider(
      name: provConf.name,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
    );
  } else if (providerId == 'anthropic') {
    final key = explicitKey ?? env['ANTHROPIC_API_KEY'] ?? '';
    provider = AnthropicProvider(
      model: explicitModel ?? 'claude-3-5-sonnet-20241022',
      apiKey: key,
      baseUrl: explicitBaseUrl,
    );
  } else if (providerId == 'ollama') {
    provider = OpenAiProvider(
      name: 'Ollama (Local)',
      model: explicitModel ?? 'llama3',
      apiKey: 'ollama',
      baseUrl: explicitBaseUrl ?? 'http://localhost:11434/v1',
    );
  } else if (providerId == 'openrouter') {
    final key = explicitKey ?? env['OPENROUTER_API_KEY'] ?? '';
    provider = OpenAiProvider(
      name: 'OpenRouter',
      model: explicitModel ?? 'anthropic/claude-3.5-sonnet',
      apiKey: key,
      baseUrl: explicitBaseUrl ?? 'https://openrouter.ai/api/v1',
    );
  } else {
    // OpenAI or Generic OpenAI-compatible
    final key = explicitKey ?? env['OPENAI_API_KEY'] ?? '';
    provider = OpenAiProvider(
      name: 'OpenAI',
      model: explicitModel ?? config.defaultModel ?? 'gpt-4o',
      apiKey: key,
      baseUrl: explicitBaseUrl,
    );
  }

  // Session initialization (handle --resume or --session)
  AgentSession session;
  if (results['resume'] as bool) {
    final recentId = await AgentSession.getMostRecentSessionId();
    final loaded = recentId != null ? await AgentSession.loadFromDisk(recentId) : null;
    if (loaded != null) {
      session = loaded;
      stdout.writeln(TartTheme.current.success.text('  ✔ Resumed previous session "$recentId" (${loaded.messages.length} messages)'));
    } else {
      session = AgentSession();
    }
  } else if (results['session'] != null) {
    final sId = results['session'] as String;
    final loaded = await AgentSession.loadFromDisk(sId);
    if (loaded != null) {
      session = loaded;
      stdout.writeln(TartTheme.current.success.text('  ✔ Resumed session "$sId" (${loaded.messages.length} messages)'));
    } else {
      stderr.writeln(TartTheme.current.warning.text('  Session "$sId" not found. Starting fresh session.'));
      session = AgentSession();
    }
  } else {
    session = AgentSession();
  }

  // If user has custom APPEND_SYSTEM instructions (e.g. Tech Lead role from ~/.tau or ~/.tart)
  if (config.systemPromptAppend != null && config.systemPromptAppend!.isNotEmpty) {
    session.systemPrompt = '${session.systemPrompt}\n\n${config.systemPromptAppend}';
  }

  final workspace = Directory.current.path;

  final tools = [
    BashTool(workingDirectory: workspace),
    ReadFileTool(workingDirectory: workspace),
    WriteFileTool(workingDirectory: workspace),
    EditFileTool(workingDirectory: workspace),
    ListDirTool(workingDirectory: workspace),
    SearchFilesTool(workingDirectory: workspace),
  ];

  final agent = Agent(
    provider: provider,
    session: session,
    tools: tools,
  );

  final ui = CliUi(agent, config);

  // If user provided a prompt as trailing arguments (e.g. tart "list files")
  final remaining = results.rest;
  if (remaining.isNotEmpty) {
    final prompt = remaining.join(' ');
    stdout.writeln(Ansi.banner(model: provider.model, provider: provider.name, workspace: workspace));
    stdout.writeln('${TartTheme.current.accent.text('tart')} ${TartTheme.current.secondary.text('❯')} $prompt');
    await ui.runWithPrompt(prompt);
    exit(0);
  }

  // Interactive CLI REPL
  await ui.run();
}
