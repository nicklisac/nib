import 'dart:io';
import '../agent/agent.dart';
import '../agent/approval_manager.dart';
import '../agent/compaction.dart';
import '../agent/config.dart';
import '../agent/session.dart';
import '../agent/skills.dart';
import '../agent/undo_manager.dart';
import '../ai/mock_provider.dart';
import '../ai/openai_provider.dart';
import 'ansi.dart';
import 'markdown_renderer.dart';
import 'session_picker.dart';
import 'terminal_manager.dart';
import 'theme.dart';

/// Handles slash commands within the interactive CLI loop.
class SlashCommandHandler {
  final Agent agent;
  final NibConfig? config;

  /// Set by `/skills run <name>`: the full skill body, prefixed to whatever the
  /// human asked for. The REPL runs it as the next turn so a human can invoke a
  /// skill marked `disable-model-invocation`, which the model cannot load itself.
  String? pendingInvocation;

  SlashCommandHandler(this.agent, [this.config]);

  /// Returns true if input was a slash command and handled.
  Future<bool> handle(String input) async {
    final trimmed = input.trim();
    if (!trimmed.startsWith('/')) {
      return false;
    }

    final parts = trimmed.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final args = parts.sublist(1);

    switch (cmd) {
      case '/help':
        _showHelp();
        return true;

      case '/clear':
        agent.session.clearHistory();
        await agent.session.saveToDisk();
        stdout.writeln(Ansi.greenText('  ✔ Conversation history cleared.'));
        return true;

      case '/undo':
        await _handleUndo();
        return true;

      case '/compact':
        await _handleCompact(args);
        return true;

      case '/sessions':
        await _showSessions();
        return true;

      case '/resume':
        await _handleResume(args);
        return true;

      case '/skills':
      case '/skill':
        await _handleSkills(args);
        return true;

      case '/history':
        _showHistory();
        return true;

      case '/tools':
        _showTools();
        return true;

      case '/config':
        _showConfig();
        return true;

      case '/provider':
        _handleProvider(args);
        return true;

      case '/model':
        _handleModel(args);
        return true;

      case '/theme':
        _handleTheme(args);
        return true;

      case '/confirm':
        _handleConfirm();
        return true;

      case '/system':
        _handleSystem(args);
        return true;

      case '/mock':
        agent.provider = MockProvider();
        stdout.writeln(
          Ansi.yellowText(
            '  ✔ Switched to offline MockProvider (no API key required).',
          ),
        );
        return true;

      case '/exit':
      case '/quit':
      case '/q':
        stdout.writeln(Ansi.dimText('Goodbye!'));
        TerminalManager.instance.shutdown(0);

      default:
        stdout.writeln(
          Ansi.yellowText(
            '  Unknown command "$cmd". Type /help for available commands.',
          ),
        );
        return true;
    }
  }

  void _showHelp() {
    stdout.writeln();
    stdout.writeln(Ansi.boldText('Available Slash Commands:'));
    stdout.writeln(
      '  ${Ansi.cyanText('/help')}             Show this help message',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/undo')}             Revert the last file change made by Nib',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/compact [focus]')}  Compact older conversation entries into structured checkpoint',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/theme [name]')}     Switch TrueColor theme (catppuccin, tokyonight, nord, gruvbox)',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/confirm')}          Toggle interactive change confirmation mode',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/sessions')}         List saved sessions',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/resume [id]')}      Resume a session (interactive picker if no id given)',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/skills [cmd]')}     Inspect and toggle modular agent skills (list, show, toggle, reload)',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/config')}           Display active configuration & endpoints',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/provider [name]')}  Switch between configured providers',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/model [name]')}     Display or switch the current model',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/tools')}            List all registered agent tools',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/history')}          Display conversation stats & token usage',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/system [prompt]')}  Display or update the system prompt',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/clear')}            Clear conversation history',
    );
    stdout.writeln(
      '  ${Ansi.cyanText('/mock')}             Switch to offline MockProvider',
    );
    stdout.writeln('  ${Ansi.cyanText('/exit')}             Exit the CLI');
    stdout.writeln();
    stdout.writeln(Ansi.boldText('Keys'));
    final keys = [
      ('Esc / Ctrl+C', 'stop the turn; your draft is kept'),
      ('alt+enter', 'queue what you typed while a turn runs'),
      ('enter', 'on an empty line, send the queued message'),
      ('ctrl+j', 'newline instead of sending'),
      ('paste', 'inserts literally; it never sends'),
    ];
    for (final key in keys) {
      stdout.writeln(
        '  ${Ansi.cyanText(key.$1.padRight(14))} ${Ansi.grayText(key.$2)}',
      );
    }
    stdout.writeln();
  }

  Future<void> _handleUndo() async {
    if (!UndoManager.instance.canUndo) {
      stdout.writeln(Ansi.yellowText('  No file edits in history to undo.'));
      return;
    }
    final result = await UndoManager.instance.undo();
    if (result != null) {
      stdout.writeln();
      stdout.writeln('  ${Ansi.greenText('✔ Undo successful:')}');
      stdout.writeln('  $result');
      stdout.writeln();
    }
  }

  Future<void> _showSessions() async {
    final list = await AgentSession.listSavedSessions();
    stdout.writeln();
    stdout.writeln(Ansi.boldText('Saved Sessions (~/.nib/sessions/):'));
    if (list.isEmpty) {
      stdout.writeln('  ${Ansi.dimText('No saved sessions found yet.')}');
    } else {
      for (final s in list) {
        final id = s['id'] as String;
        final turns = s['user_turns'] as int;
        final preview = s['last_prompt'] as String;
        final isCurrent = id == agent.session.id;
        final marker = isCurrent ? Ansi.greenText(' (current)') : '';
        stdout.writeln(
          '  • ${Ansi.cyanText(id)}$marker ${Ansi.dimText('[$turns turns]')} ${Ansi.grayText(preview)}',
        );
      }
    }
    stdout.writeln();
  }

  Future<void> _handleResume(List<String> args) async {
    String? id;
    if (args.isEmpty) {
      id = await SessionPicker.pickSession(currentSession: agent.session);
      if (id == null) return;
    } else {
      id = args[0];
    }

    final loaded = await AgentSession.loadFromDisk(id);
    if (loaded == null) {
      stdout.writeln(Ansi.redText('  Failed to load session "$id".'));
      return;
    }

    agent.session = loaded;
    stdout.writeln(
      NibTheme.current.success.text(
        '  ✔ Resumed session "$id" (${loaded.messages.length} messages loaded).',
      ),
    );
  }

  Future<void> _handleSkills(List<String> args) async {
    final theme = NibTheme.current;
    final sub = args.isNotEmpty ? args[0].toLowerCase() : 'list';
    final target = args.length > 1 ? args.sublist(1).join(' ').trim() : '';

    // Only enable/disable paths write the overrides file.
    var mutated = false;
    switch (sub) {
      case 'list':
        final all = SkillsManager.instance.skills;
        stdout.writeln();
        stdout.writeln(
          Ansi.boldText(
            'Registered Agent Skills (${all.where((s) => s.isEnabled).length}/${all.length} active):',
          ),
        );
        if (all.isEmpty) {
          stdout.writeln(
            '  ${theme.muted.text('No skills discovered in .nib/skills or ~/.nib/skills.')}',
          );
        } else {
          for (final s in all) {
            final statusBadge = s.isEnabled
                ? theme.success.text('[active]  ')
                : theme.muted.text('[disabled]');
            final scopeBadge = s.isWorkspace
                ? theme.warning.text('[workspace]')
                : theme.secondary.text('[global]   ');
            stdout.writeln(
              '  $statusBadge $scopeBadge ${theme.accent.text(s.name.padRight(16))} ${theme.muted.text(s.description)}',
            );
          }
        }
        stdout.writeln(
          '\n  ${theme.muted.text('Commands: /skills show <name> | /skills run <name> [instructions] | /skills enable|disable <name> | /skills reload')}',
        );
        stdout.writeln();
        break;

      case 'show':
      case 'view':
        if (target.isEmpty) {
          stdout.writeln(theme.warning.text('  Usage: /skills show <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          stdout.writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        stdout.writeln();
        stdout.writeln(
          '  ${theme.muted.text('╭─')} ${theme.accent.text('Skill: ${skill.name}')} ${theme.muted.text('────────────────────────────────────╮')}',
        );
        stdout.writeln(
          '  ${theme.muted.text('│')} Location: ${theme.muted.text(skill.filePath)}',
        );
        stdout.writeln(
          '  ${theme.muted.text('│')} Status:   ${skill.isEnabled ? theme.success.text('Active') : theme.muted.text('Disabled')}',
        );
        stdout.writeln(
          '  ${theme.muted.text('╰───────────────────────────────────────────────────╯')}',
        );
        stdout.writeln(MarkdownRenderer.render(skill.content, theme));
        stdout.writeln();
        break;

      case 'toggle':
        if (target.isEmpty) {
          stdout.writeln(theme.warning.text('  Usage: /skills toggle <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          stdout.writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        mutated = true;
        skill.isEnabled = !skill.isEnabled;
        agent.session.rebuildSystemPrompt(
          appendPrompt: config?.systemPromptAppend,
        );
        final stateStr = skill.isEnabled
            ? theme.success.text('ENABLED')
            : theme.muted.text('DISABLED');
        stdout.writeln(
          '  ✔ Skill ${theme.accent.text(skill.name)} is now $stateStr.',
        );
        break;

      case 'enable':
        if (target.isEmpty) {
          stdout.writeln(theme.warning.text('  Usage: /skills enable <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          stdout.writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        mutated = true;
        skill.isEnabled = true;
        agent.session.rebuildSystemPrompt(
          appendPrompt: config?.systemPromptAppend,
        );
        stdout.writeln(
          '  ✔ Skill ${theme.accent.text(skill.name)} ${theme.success.text('ENABLED')}.',
        );
        break;

      case 'disable':
        if (target.isEmpty) {
          stdout.writeln(theme.warning.text('  Usage: /skills disable <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          stdout.writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        mutated = true;
        skill.isEnabled = false;
        agent.session.rebuildSystemPrompt(
          appendPrompt: config?.systemPromptAppend,
        );
        stdout.writeln(
          '  ✔ Skill ${theme.accent.text(skill.name)} ${theme.muted.text('DISABLED')}.',
        );
        break;

      case 'run':
      case 'use':
        if (target.isEmpty) {
          stdout.writeln(
            theme.warning.text('  Usage: /skills run <name> [instructions]'),
          );
          return;
        }
        final parts = target.split(RegExp(r'\s+'));
        var skill = SkillsManager.instance.findSkill(parts.first);
        var extra = parts.length > 1 ? parts.sublist(1).join(' ') : '';
        // Skill names may contain spaces, so fall back to matching the whole
        // argument string when the first word is not a skill.
        if (skill == null) {
          skill = SkillsManager.instance.findSkill(target);
          extra = '';
        }
        if (skill == null) {
          stdout.writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        if (!skill.isEnabled) {
          stdout.writeln(
            theme.warning.text(
              '  Skill "${skill.name}" is disabled. Enable it first with /skills enable ${skill.name}.',
            ),
          );
          return;
        }
        // Human invocation: `disable-model-invocation` is a gate on the *model*
        // choosing a skill, not on the human handing it over deliberately.
        final body = SkillsManager.instance.formatSkillBody(skill);
        pendingInvocation = extra.isEmpty
            ? body
            : '$body\n\n## Request\n\n$extra';
        stdout.writeln(
          theme.success.text(
            '  ✔ Invoking skill "${skill.name}"${extra.isEmpty ? '' : ' with your instructions'}.',
          ),
        );
        break;

      case 'reload':
        stdout.writeln(
          theme.muted.text(
            '  Reloading skills from workspace and user directories...',
          ),
        );
        // Reload from the workspace the skills were loaded from, not the
        // process cwd, so overrides keep applying to the right project.
        await SkillsManager.instance.loadSkills(
          workspacePath: SkillsManager.instance.workspacePath,
        );
        agent.session.rebuildSystemPrompt(
          appendPrompt: config?.systemPromptAppend,
        );
        final count = SkillsManager.instance.skills.length;
        final activeCount = SkillsManager.instance.activeSkills.length;
        stdout.writeln(
          theme.success.text(
            '  ✔ Loaded $count skills ($activeCount active). System prompt updated.',
          ),
        );
        break;

      default:
        // If user typed `/skills name`, treat it as toggle if name exists
        final skill = SkillsManager.instance.findSkill(sub);
        if (skill != null) {
          mutated = true;
          skill.isEnabled = !skill.isEnabled;
          agent.session.rebuildSystemPrompt(
            appendPrompt: config?.systemPromptAppend,
          );
          final stateStr = skill.isEnabled
              ? theme.success.text('ENABLED')
              : theme.muted.text('DISABLED');
          stdout.writeln(
            '  ✔ Skill ${theme.accent.text(skill.name)} is now $stateStr.',
          );
        } else {
          stdout.writeln(
            theme.warning.text(
              '  Unknown skill command "$sub". Usage: /skills [list|show|run|toggle|enable|disable|reload] [name]',
            ),
          );
        }
        break;
    }

    // Persist enable/disable changes only: `list` and `show` must not touch
    // .nib/skills.json, and early `return`s above skip this entirely.
    if (mutated) await SkillsManager.instance.saveOverrides();
  }

  void _showConfig() {
    stdout.writeln();
    stdout.writeln(Ansi.boldText('Nib Configuration:'));
    stdout.writeln('  Active Provider:  ${Ansi.cyanText(agent.provider.name)}');
    stdout.writeln(
      '  Active Model:     ${Ansi.brightCyanText(agent.provider.model)}',
    );
    if (agent.provider is OpenAiProvider) {
      final oai = agent.provider as OpenAiProvider;
      stdout.writeln('  Endpoint:         ${Ansi.grayText(oai.baseUrl)}');
    }
    if (config != null && config!.providers.isNotEmpty) {
      stdout.writeln('\n${Ansi.boldText('Configured Providers:')}');
      for (final p in config!.providers.values) {
        final marker = p.name == agent.provider.name
            ? Ansi.greenText(' (active)')
            : '';
        stdout.writeln(
          '  • ${Ansi.yellowText(p.name)}: model=${p.model}, endpoint=${p.baseUrl}$marker',
        );
      }
    }
    stdout.writeln();
  }

  void _handleProvider(List<String> args) {
    if (args.isEmpty) {
      _showConfig();
      return;
    }
    final name = args[0].toLowerCase();
    if (config != null && config!.providers.containsKey(name)) {
      final p = config!.providers[name]!;
      agent.provider = OpenAiProvider(
        name: p.name,
        model: p.model,
        baseUrl: p.baseUrl,
        apiKey: p.apiKey,
      );
      stdout.writeln(
        Ansi.greenText(
          '  ✔ Switched to provider "$name" (${p.model} @ ${p.baseUrl})',
        ),
      );
    } else {
      stdout.writeln(
        Ansi.yellowText(
          '  Provider "$name" not found in config. Available: ${config?.providers.keys.join(', ') ?? 'none'}',
        ),
      );
    }
  }

  void _showHistory() {
    final msgs = agent.session.messages;
    final meter = agent.meter;
    final spent =
        agent.session.totalPromptTokens + agent.session.totalCompletionTokens;
    stdout.writeln();
    stdout.writeln(Ansi.boldText('Session Transcript Summary:'));
    stdout.writeln('  Session ID:         ${Ansi.cyanText(agent.session.id)}');
    stdout.writeln('  Total messages:     ${msgs.length}');
    stdout.writeln(
      '  Tool executions:    ${agent.session.toolExecutionsCount}',
    );
    stdout.writeln('  Undo history depth: ${UndoManager.instance.count}');
    stdout.writeln();

    // Tokens spent is an after-the-fact billing figure, so it lives here rather
    // than on the ambient line's gauge (#20).
    stdout.writeln(
      '  ${Ansi.boldText('Tokens spent:')}       ${Ansi.cyanText(_formatTokens(spent))}',
    );
    stdout.writeln('    prompt:           ${agent.session.totalPromptTokens}');
    stdout.writeln(
      '    completion:        ${agent.session.totalCompletionTokens}',
    );
    stdout.writeln();

    // The raw window numbers the ambient line leaves out, plus the threshold that
    // will trigger compaction. Seeing how far you are from compaction is what
    // keeps the transcript from changing underneath you (#21, doctrine rule 5).
    final occupied = meter.tokensFor(agent.session);
    final provenance = meter.isMeasured
        ? Ansi.greenText('measured (provider usage)')
        : Ansi.yellowText('estimated (chars/4)');
    stdout.writeln(Ansi.boldText('Context gauge:'));
    stdout.writeln(
      '  Occupied:           ${Ansi.cyanText('${_formatTokens(occupied)} / ${_formatTokens(meter.contextWindow)}')}  ${Ansi.boldText(meter.displayFor(agent.session))}',
    );
    stdout.writeln('  Basis:            $provenance');
    stdout.writeln(
      '  Auto-compact at:    ${Ansi.cyanText(_formatTokens(meter.threshold))} (reserve ${_formatTokens(meter.reserve)})',
    );
    stdout.writeln();
  }

  static String _formatTokens(int tokens) =>
      tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : '$tokens';

  void _showTools() {
    stdout.writeln();
    stdout.writeln(Ansi.boldText('Registered Agent Tools:'));
    for (final tool in agent.tools) {
      stdout.writeln(
        '  ${Ansi.brightCyanText(tool.name)}: ${tool.description}',
      );
    }
    stdout.writeln();
  }

  void _handleModel(List<String> args) {
    if (args.isEmpty) {
      stdout.writeln(
        '  Current model: ${Ansi.cyanText(agent.provider.model)} (provider: ${agent.provider.name})',
      );
      return;
    }

    final newModel = args[0];
    if (agent.provider is OpenAiProvider) {
      final current = agent.provider as OpenAiProvider;
      agent.provider = OpenAiProvider(
        name: current.name,
        model: newModel,
        apiKey: current.apiKey,
        baseUrl: current.baseUrl,
      );
      stdout.writeln(Ansi.greenText('  ✔ Model changed to $newModel'));
    } else {
      stdout.writeln(
        Ansi.yellowText(
          '  Model switching currently supports OpenAI-compatible providers.',
        ),
      );
    }
  }

  void _handleSystem(List<String> args) {
    if (args.isEmpty) {
      stdout.writeln();
      stdout.writeln(Ansi.boldText('Current System Prompt:'));
      stdout.writeln(agent.session.systemPrompt);
      stdout.writeln();
    } else {
      final newPrompt = args.join(' ');
      agent.session.systemPrompt = newPrompt;
      agent.session.addSystemPromptIfNeeded();
      stdout.writeln(Ansi.greenText('  ✔ System prompt updated.'));
    }
  }

  void _handleTheme(List<String> args) {
    if (args.isEmpty) {
      stdout.writeln();
      stdout.writeln(Ansi.boldText('Available TrueColor Themes:'));
      for (final t in NibTheme.allThemes.values) {
        final isActive = t.id == NibTheme.current.id;
        final marker = isActive ? ' (active)' : '';
        stdout.writeln(
          '  • ${t.accent.text(t.id.padRight(12))} - ${t.secondary.text(t.displayName)}$marker',
        );
      }
      stdout.writeln('\n  Usage: /theme <name> (e.g. /theme tokyonight)');
      stdout.writeln();
      return;
    }

    final target = args[0].toLowerCase().trim();
    if (NibTheme.allThemes.containsKey(target)) {
      NibTheme.setTheme(target);
      final active = NibTheme.current;
      stdout.writeln(
        active.success.text('  ✔ Switched theme to ${active.displayName}'),
      );
    } else {
      stdout.writeln(
        Ansi.yellowText(
          '  Unknown theme "$target". Available: ${NibTheme.allThemes.keys.join(', ')}',
        ),
      );
    }
  }

  void _handleConfirm() {
    final current = ApprovalManager.instance.requireConfirmation;
    ApprovalManager.instance.requireConfirmation = !current;
    final newState = ApprovalManager.instance.requireConfirmation;
    final theme = NibTheme.current;
    if (newState) {
      stdout.writeln(
        theme.warning.text(
          '  ✔ Interactive confirmation ENABLED (Nib will prompt before modifying files or running destructive commands)',
        ),
      );
    } else {
      stdout.writeln(
        theme.muted.text(
          '  ✔ Interactive confirmation DISABLED (Auto-apply mode)',
        ),
      );
    }
  }

  Future<void> _handleCompact(List<String> args) async {
    final focus = args.isNotEmpty ? args.join(' ') : null;
    stdout.writeln(
      NibTheme.current.muted.text(
        '  Compacting conversation context (Tau-style)...',
      ),
    );
    final result = await CompactionManager.compact(
      session: agent.session,
      provider: agent.provider,
      customInstructions: focus,
    );
    if (result.success) {
      stdout.writeln(
        NibTheme.current.success.text(
          '  ✔ Compacted ${result.replacedMessageCount} messages '
          '(${result.tokensBefore} → ${result.tokensAfter} tokens).',
        ),
      );
    } else {
      stdout.writeln(
        NibTheme.current.warning.text(
          '  Not enough messages in context to compact (needs at least ${CompactionManager.defaultKeepRecentMessages + 1} messages).',
        ),
      );
    }
  }
}
