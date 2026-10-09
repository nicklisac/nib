import 'dart:io';
import 'package:args/args.dart';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/approval_manager.dart';
import 'package:nib/agent/config.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/skills.dart';
import 'package:nib/agent/thinking_level.dart';
import 'package:nib/ai/anthropic_provider.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/ai/openai_provider.dart';
import 'package:nib/ai/provider.dart';
import 'package:nib/tools/bash_tool.dart';
import 'package:nib/tools/edit_file_tool.dart';
import 'package:nib/tools/list_dir_tool.dart';
import 'package:nib/tools/read_file_tool.dart';
import 'package:nib/tools/search_files_tool.dart';
import 'package:nib/tools/skill_tool.dart';
import 'package:nib/tools/web_fetch_tool.dart';
import 'package:nib/tools/web_search_tool.dart';
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
      help: 'Custom config file path (default: ~/.nib/config.json).',
    )
    ..addOption(
      'provider',
      abbr: 'p',
      help: 'LLM provider (e.g. anthropic, openai, openrouter, ollama, mock).',
    )
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Model name (e.g. claude-3-7-sonnet-20250219, gpt-4o, llama3.1).',
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
      help: 'Custom API base URL (e.g. http://localhost:11434/v1 for Ollama).',
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

  // Layer this repository's own instructions (AGENTS.md) on top of the global
  // append prompt, so per-project conventions and the issue-tracker pointer
  // reach the model without touching the user's global config.
  final projectInstructions = await NibConfig.loadProjectInstructions(
    Directory.current.path,
  );
  if (projectInstructions != null && projectInstructions.isNotEmpty) {
    final global = config.systemPromptAppend;
    config.systemPromptAppend = (global == null || global.isEmpty)
        ? projectInstructions
        : '$global\n\n$projectInstructions';
  }

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
    // Configured provider profile from ~/.nib/config.json
    final provConf = config.providers[providerId]!;
    final model = explicitModel ?? provConf.model;
    final baseUrl = explicitBaseUrl ?? provConf.baseUrl;
    final apiKey = explicitKey ?? provConf.apiKey;

    provider = OpenAiProvider(
      name: provConf.name,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
    );
  } else if (providerId == 'anthropic') {
    final key = explicitKey ?? env['ANTHROPIC_API_KEY'] ?? '';
    provider = AnthropicProvider(
      model: explicitModel ?? 'claude-3-7-sonnet-20250219',
      apiKey: key,
      baseUrl: explicitBaseUrl,
    );
  } else if (providerId == 'ollama') {
    provider = OpenAiProvider(
      name: 'Ollama (Local)',
      model: explicitModel ?? 'llama3.1',
      apiKey: 'ollama',
      baseUrl: explicitBaseUrl ?? 'http://localhost:11434/v1',
    );
  } else if (providerId == 'openrouter') {
    final key = explicitKey ?? env['OPENROUTER_API_KEY'] ?? '';
    provider = OpenAiProvider(
      name: 'OpenRouter',
      model: explicitModel ?? 'anthropic/claude-3.7-sonnet',
      apiKey: key,
      baseUrl: explicitBaseUrl ?? 'https://openrouter.ai/api/v1',
    );
  } else if (providerId == 'openai') {
    final key = explicitKey ?? env['OPENAI_API_KEY'] ?? '';
    provider = OpenAiProvider(
      name: 'OpenAI',
      model: explicitModel ?? config.defaultModel ?? 'gpt-4o',
      apiKey: key,
      baseUrl: explicitBaseUrl,
    );
  } else {
    // Generic OpenAI-compatible fallback
    final key = explicitKey ?? env['OPENAI_API_KEY'] ?? '';
    provider = OpenAiProvider(
      name: 'OpenAI',
      model: explicitModel ?? config.defaultModel ?? 'gpt-4o',
      apiKey: key,
      baseUrl: explicitBaseUrl,
    );
  }

  // Check whether a usable provider or credentials exist
  final hasKey = switch (provider) {
    AnthropicProvider a => a.apiKey.isNotEmpty,
    OpenAiProvider o =>
      o.apiKey.isNotEmpty ||
          (o.baseUrl.contains('localhost') || o.baseUrl.contains('127.0.0.1')),
    MockProvider _ => true,
    _ => false,
  };

  if (!isMock && !hasKey) {
    final theme = NibTheme.current;
    stderr.writeln();
    stderr.writeln(
      '  ${theme.accent.text('╭── ✒   Welcome to NIB ──────────────────────────────────────────────')}',
    );
    stderr.writeln(
      '  ${theme.muted.text('│')}   A minimalist terminal coding agent written entirely in Dart.',
    );
    stderr.writeln(
      '  ${theme.accent.text('╰───────────────────────────────────────────────────────────────────')}',
    );
    stderr.writeln();
    stderr.writeln(
      '  ${theme.warning.text('No AI provider or API key configured.')}',
    );
    stderr.writeln();
    stderr.writeln('  To use Nib, set an API key in your environment:');
    stderr.writeln(
      '    ${theme.secondary.text('export ANTHROPIC_API_KEY="sk-ant-..."')}   # Anthropic Claude',
    );
    stderr.writeln(
      '    ${theme.secondary.text('export OPENAI_API_KEY="sk-..."')}          # OpenAI',
    );
    stderr.writeln(
      '    ${theme.secondary.text('export OPENROUTER_API_KEY="sk-or-..."')}   # OpenRouter',
    );
    stderr.writeln();
    stderr.writeln(
      '  Or configure ~/.nib/config.json with a local server (e.g. Ollama):',
    );
    stderr.writeln(
      '    ${theme.muted.text('./nib --provider ollama --model llama3.1')}',
    );
    stderr.writeln();
    stderr.writeln('  To run in offline demo mode without an API key:');
    stderr.writeln('    ${theme.success.text('./nib --mock')}');
    stderr.writeln();
    exit(1);
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

  // Discover and load modular skills (.nib/skills and ~/.nib/skills only).
  // Bodies are not injected: the system prompt carries an index and the model
  // pulls a skill's full instructions through the `skill` tool.
  await SkillsManager.instance.loadSkills(workspacePath: workspace);
  session.rebuildSystemPrompt(appendPrompt: config.systemPromptAppend);

  final tools = [
    BashTool(workingDirectory: workspace),
    ReadFileTool(workingDirectory: workspace),
    WriteFileTool(workingDirectory: workspace),
    EditFileTool(workingDirectory: workspace),
    ListDirTool(workingDirectory: workspace),
    SearchFilesTool(workingDirectory: workspace),
    WebSearchTool(configuredProvider: config.searchProvider),
    WebFetchTool(),
    SkillTool(),
  ];

  // The active provider wins over the top-level values: loop ceilings and the
  // context window belong to the model, not to the binary.
  final activeProviderConf = config.providers[providerId];
  final activeContextWindow =
      activeProviderConf?.contextWindow ?? config.contextWindow;
  final activeMaxTokens = activeProviderConf?.maxTokens ?? config.maxTokens;
  final activeMaxTurns = activeProviderConf?.maxTurns ?? config.maxTurns;
  final activeMaxStuck =
      activeProviderConf?.maxStuckIterations ?? config.maxStuckIterations;
  final activeHardCap =
      activeProviderConf?.hardIterationCap ?? config.hardIterationCap;
  final activeThinkingLevelStr =
      activeProviderConf?.thinkingLevel ?? config.thinkingLevel;
  final activeThinkingLevel = activeThinkingLevelStr != null
      ? ThinkingLevel.fromString(activeThinkingLevelStr)
      : ThinkingLevel.medium;

  final agent = Agent(
    provider: provider,
    session: session,
    tools: tools,
    contextWindow: activeContextWindow,
    maxTokens: activeMaxTokens,
    maxTurns: activeMaxTurns,
    maxStuckIterations: activeMaxStuck,
    hardIterationCap: activeHardCap,
    thinkingLevel: activeThinkingLevel,
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
      ui.renderUserTurn(prompt);
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
