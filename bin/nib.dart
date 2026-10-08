import 'dart:io';
import 'package:args/args.dart';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/approval_manager.dart';
import 'package:nib/agent/config.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/skills.dart';
import 'package:nib/ai/anthropic_provider.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/ai/openai_provider.dart';
import 'package:nib/ai/provider.dart';
import 'package:nib/tools/bash_tool.dart';
import 'package:nib/tools/edit_file_tool.dart';
import 'package:nib/tools/list_dir_tool.dart';
import 'package:nib/tools/read_file_tool.dart';
import 'package:nib/tools/search_files_tool.dart';
import 'package:nib/tools/write_file_tool.dart';
import 'package:nib/ui/ansi.dart';
import 'package:nib/ui/cli_ui.dart';
import 'package:nib/ui/session_picker.dart';
import 'package:nib/ui/terminal_manager.dart';
import 'package:nib/ui/theme.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      help:
          'Custom config file path (default: ~/.nib/config.json with ~/.tart / ~/.tau fallback).',
    )
    ..addOption(
      'provider',
      abbr: 'p',
      help:
          'LLM provider (e.g. exllama, unsloth, openai, anthropic, ollama, mock).',
    )
    ..addOption(
      'model',
      abbr: 'm',
      help:
          'Model name (e.g. Qwen3.8-Flash-Next-exl3-3.50bpw_hq_h6_ng6, gpt-4o).',
    )
    ..addOption(
      'theme',
      abbr: 't',
      help: 'TrueColor theme (catppuccin, tokyonight, nord, gruvbox).',
      defaultsTo: 'catppuccin',
    )
    ..addFlag(
      'confirm',
      help:
          'Require confirmation before writing files or running destructive commands.',
      negatable: false,
    )
    ..addOption(
      'api-key',
      abbr: 'k',
      help: 'API Key (defaults to provider config or environment variable).',
    )
    ..addOption(
      'base-url',
      help:
          'Custom API base URL (e.g. http://localhost:5000/v1 for tabbyAPI/exllama).',
    )
    ..addFlag(
      'resume',
      abbr: 'r',
      help: 'Resume the most recent conversation session.',
      negatable: false,
    )
    ..addOption('session', help: 'Resume a specific session ID.')
    ..addFlag(
      'mock',
      help: 'Run in offline demo mode without calling external APIs.',
      negatable: false,
    )
    ..addFlag('help', abbr: 'h', help: 'Show command help.', negatable: false);

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error parsing arguments: $e');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    print('✒   NIB - Terminal CLI Coding Agent (in the style of Pi & Tau)');
    print('\nUsage: ./nib [options] [prompt]\n');
    print(parser.usage);
    exit(0);
  }

  // Set theme & confirmation mode
  final themeName = results['theme'] as String;
  NibTheme.setTheme(themeName);
  ApprovalManager.instance.requireConfirmation = results['confirm'] as bool;

  // Load Nib configuration (with automatic fallback to ~/.tart and ~/.tau)
  final explicitConfigPath = results['config'] as String?;
  final config = await NibConfig.load(customPath: explicitConfigPath);

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
    // Configured provider profile (e.g. exllama / unsloth from ~/.nib, ~/.tart, or ~/.tau)
    final provConf = config.providers[providerId]!;
    final model = explicitModel ?? provConf.model;
    final baseUrl = explicitBaseUrl ?? provConf.baseUrl;
    final apiKey =
        explicitKey ??
        (provConf.apiKey.isNotEmpty
            ? provConf.apiKey
            : env['EXLLAMA_API_KEY'] ?? '');

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

  // Resume or start session
  AgentSession session;
  final shouldResume = results['resume'] as bool;

  if (shouldResume) {
    String? targetId;
    if (results.rest.isEmpty && stdin.hasTerminal) {
      targetId = await SessionPicker.pickSession();
    } else {
      targetId = await AgentSession.getMostRecentSessionId();
    }

    if (targetId != null) {
      final loaded = await AgentSession.loadFromDisk(targetId);
      if (loaded != null) {
        session = loaded;
        stdout.writeln(
          NibTheme.current.success.text(
            '  ✔ Resumed session "$targetId" (${loaded.messages.length} messages)',
          ),
        );
      } else {
        session = AgentSession();
      }
    } else {
      stdout.writeln(NibTheme.current.muted.text('  Starting fresh session.'));
      session = AgentSession();
    }
  } else if (results['session'] != null) {
    final sId = results['session'] as String;
    final loaded = await AgentSession.loadFromDisk(sId);
    if (loaded != null) {
      session = loaded;
      stdout.writeln(
        NibTheme.current.success.text(
          '  ✔ Resumed session "$sId" (${loaded.messages.length} messages)',
        ),
      );
    } else {
      stderr.writeln(
        NibTheme.current.warning.text(
          '  Session "$sId" not found. Starting fresh session.',
        ),
      );
      session = AgentSession();
    }
  } else {
    session = AgentSession();
  }

  final workspace = Directory.current.path;

  // Discover and load modular skills (.nib/skills, ~/.nib/skills, ~/.tau/skills)
  await SkillsManager.instance.loadSkills(workspacePath: workspace);
  session.rebuildSystemPrompt(appendPrompt: config.systemPromptAppend);

  final tools = [
    BashTool(workingDirectory: workspace),
    ReadFileTool(workingDirectory: workspace),
    WriteFileTool(workingDirectory: workspace),
    EditFileTool(workingDirectory: workspace),
    ListDirTool(workingDirectory: workspace),
    SearchFilesTool(workingDirectory: workspace),
  ];

  final activeProviderConf = config.providers[providerId];
  final activeContextWindow =
      activeProviderConf?.contextWindow ?? config.contextWindow;
  final activeMaxTokens = activeProviderConf?.maxTokens ?? config.maxTokens;

  final agent = Agent(
    provider: provider,
    session: session,
    tools: tools,
    contextWindow: activeContextWindow,
    maxTokens: activeMaxTokens,
  );

  final ui = CliUi(agent, config);

  TerminalManager.instance.initialize();
  try {
    // If user provided a prompt as trailing arguments (e.g. nib "list files")
    final remaining = results.rest;
    if (remaining.isNotEmpty) {
      final prompt = remaining.join(' ');
      stdout.writeln(
        Ansi.banner(
          model: provider.model,
          provider: provider.name,
          workspace: workspace,
        ),
      );
      stdout.writeln(
        '${NibTheme.current.accent.text('nib')} ${NibTheme.current.secondary.text('❯')} $prompt',
      );
      await ui.runWithPrompt(prompt);
      TerminalManager.instance.dispose();
      exit(0);
    }

    // Interactive CLI REPL
    await ui.run();
  } finally {
    TerminalManager.instance.dispose();
  }
}
