import 'dart:io';
import 'dart:math';
import '../agent/agent.dart';
import '../agent/approval_manager.dart';
import '../agent/compaction.dart';
import '../agent/config.dart';
import '../agent/session.dart';
import '../agent/skills.dart';
import '../agent/thinking_level.dart';
import '../agent/undo_manager.dart';
import '../ai/anthropic_provider.dart';
import '../ai/image_attachment.dart';
import '../ai/mock_provider.dart';
import '../ai/openai_provider.dart';
import 'ansi.dart';
import 'markdown_renderer.dart';
import 'provider_wizard.dart';
import 'session_picker.dart';
import 'terminal_manager.dart';
import 'theme.dart';
import 'theme_picker.dart';
import 'transcript_writer.dart';

/// Handles slash commands within the interactive CLI loop.
class SlashCommandHandler {
  final Agent agent;
  final NibConfig? config;

  /// Set by `/skills run <name>`: the full skill body, prefixed to whatever the
  /// human asked for. The REPL runs it as the next turn so a human can invoke a
  /// skill marked `disable-model-invocation`, which the model cannot load itself.
  String? pendingInvocation;

  /// Images attached via `/image` waiting to be attached to the next turn.
  final List<ImageAttachment> pendingImages = [];

  /// Where command output goes. Resolved per call so a handler built before the
  /// coordinator activates still writes to the right place, and tests that
  /// construct one directly keep printing to stdout.
  TranscriptWriter get _out => resolveTranscriptWriter(_writer);
  final TranscriptWriter? _writer;
  void Function()? onRedraw;
  void Function(NibTheme theme)? onThemePreview;
  void Function(AgentSession session)? onSessionResumed;

  SlashCommandHandler(
    this.agent, [
    this.config,
    TranscriptWriter? writer,
    this.onRedraw,
    this.onSessionResumed,
    this.onThemePreview,
  ]) : _writer = writer;

  /// Writes one transcript line through the coordinator when it owns the
  /// screen, and to stdout when it does not.
  void _writeln([String line = '']) => _out.writeLine(line);

  /// Returns true if input was a slash command and handled.
  Future<bool> handle(String input) async {
    final trimmed = input.trim();
    if (!trimmed.startsWith('/')) {
      return false;
    }

    final parts = trimmed.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final args = parts.sublist(1);

    // Absolute file/directory paths (e.g. '/home/user/image.png' or '/usr/bin')
    // contain additional slashes or exist on disk. They are input paths, not commands.
    if (cmd.length < 2 || cmd.indexOf('/', 1) != -1) {
      return false;
    }
    try {
      if (File(parts[0]).existsSync() || Directory(parts[0]).existsSync()) {
        return false;
      }
    } catch (_) {}

    switch (cmd) {
      case '/help':
        _showHelp();
        return true;

      case '/thinking':
        _handleThinking(args);
        return true;

      case '/image':
        await _handleImage(args);
        return true;

      case '/new':
        await _handleNew();
        return true;

      case '/clear':
        agent.session.clearHistory();
        await agent.session.saveToDisk();
        _writeln(Ansi.greenText('  ✔ Conversation history cleared.'));
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

      case '/setup':
        await _handleSetup();
        return true;

      case '/model':
        _handleModel(args);
        return true;

      case '/theme':
        await _handleTheme(args);
        return true;

      case '/confirm':
        _handleConfirm();
        return true;

      case '/system':
        _handleSystem(args);
        return true;

      case '/mock':
        agent.provider = MockProvider();
        _writeln(
          Ansi.yellowText(
            '  ✔ Switched to offline MockProvider (no API key required).',
          ),
        );
        return true;

      case '/redraw':
        onRedraw?.call();
        return true;

      case '/exit':
      case '/quit':
      case '/q':
        _writeln(Ansi.dimText('Goodbye!'));
        TerminalManager.instance.shutdown(0);

      default:
        _writeln(
          Ansi.yellowText(
            '  Unknown command "$cmd". Type /help for available commands.',
          ),
        );
        return true;
    }
  }

  void _showHelp() {
    _writeln();
    _writeln(Ansi.boldText('Available Slash Commands:'));
    _writeln('  ${Ansi.cyanText('/help')}             Show this help message');
    _writeln(
      '  ${Ansi.cyanText('/thinking [level]')} Inspect or change thinking level ladder (off..max)',
    );
    _writeln(
      '  ${Ansi.cyanText('/image [path]')}     Attach image from path or clipboard into next prompt',
    );
    _writeln(
      '  ${Ansi.cyanText('/undo')}             Revert the last file change made by Nib',
    );
    _writeln(
      '  ${Ansi.cyanText('/compact [focus]')}  Compact older conversation entries into structured checkpoint',
    );
    _writeln(
      '  ${Ansi.cyanText('/theme [name]')}     Switch TrueColor theme (e.g. catppuccin, dracula, rosepine, ...)',
    );
    _writeln(
      '  ${Ansi.cyanText('/confirm')}          Toggle interactive change confirmation mode',
    );
    _writeln('  ${Ansi.cyanText('/sessions')}         List saved sessions');
    _writeln(
      '  ${Ansi.cyanText('/resume [id]')}      Resume a session (interactive picker if no id given)',
    );
    _writeln(
      '  ${Ansi.cyanText('/skills [cmd]')}     Inspect and toggle modular agent skills (list, show, toggle, reload)',
    );
    _writeln(
      '  ${Ansi.cyanText('/config')}           Display active configuration & endpoints',
    );
    _writeln(
      '  ${Ansi.cyanText('/provider [name]')}  Switch between configured providers',
    );
    _writeln(
      '  ${Ansi.cyanText('/setup')}            Interactively configure AI provider, model, and key',
    );
    _writeln(
      '  ${Ansi.cyanText('/model [name]')}     Display or switch the current model',
    );
    _writeln(
      '  ${Ansi.cyanText('/tools')}            List all registered agent tools',
    );
    _writeln(
      '  ${Ansi.cyanText('/history')}          Display conversation stats & token usage',
    );
    _writeln(
      '  ${Ansi.cyanText('/system [prompt]')}  Display or update the system prompt',
    );
    _writeln(
      '  ${Ansi.cyanText('/new')}              Start a brand new session with a fresh transcript',
    );
    _writeln(
      '  ${Ansi.cyanText('/clear')}            Clear conversation history',
    );
    _writeln(
      '  ${Ansi.cyanText('/redraw')}           Redraw terminal screen and replay transcript',
    );
    _writeln('  ${Ansi.cyanText('/exit')}             Exit the CLI');
    _writeln();
    _writeln(Ansi.boldText('Keys'));
    final keys = [
      ('Esc / Ctrl+C', 'stop the turn; your draft is kept'),
      ('Shift+Tab', 'cycle thinking level ladder (off..max)'),
      ('Ctrl+L', 'full screen redraw with current display filters'),
      ('Ctrl+T', 'toggle thinking trace visibility'),
      ('Ctrl+O', 'toggle tool output verbosity (compact/expanded)'),
      ('alt+enter', 'queue what you typed while a turn runs'),
      ('enter', 'on an empty line, send the queued message'),
      ('ctrl+j', 'newline instead of sending'),
      ('paste', 'inserts literally; it never sends'),
    ];
    for (final key in keys) {
      _writeln(
        '  ${Ansi.cyanText(key.$1.padRight(14))} ${Ansi.grayText(key.$2)}',
      );
    }
    _writeln();
  }

  Future<void> _handleUndo() async {
    if (!UndoManager.instance.canUndo) {
      _writeln(Ansi.yellowText('  No file edits in history to undo.'));
      return;
    }
    final result = await UndoManager.instance.undo();
    if (result != null) {
      _writeln();
      _writeln('  ${Ansi.greenText('✔ Undo successful:')}');
      _writeln('  $result');
      _writeln();
    }
  }

  Future<void> _showSessions() async {
    final list = await AgentSession.listSavedSessions();
    _writeln();
    _writeln(Ansi.boldText('Saved Sessions (~/.nib/sessions/):'));
    if (list.isEmpty) {
      _writeln('  ${Ansi.dimText('No saved sessions found yet.')}');
    } else {
      for (final s in list) {
        final id = s['id'] as String;
        final turns = s['user_turns'] as int;
        final preview = s['last_prompt'] as String;
        final isCurrent = id == agent.session.id;
        final marker = isCurrent ? Ansi.greenText(' (current)') : '';
        _writeln(
          '  • ${Ansi.cyanText(id)}$marker ${Ansi.dimText('[$turns turns]')} ${Ansi.grayText(preview)}',
        );
      }
    }
    _writeln();
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
      _writeln(Ansi.redText('  Failed to load session "$id".'));
      return;
    }

    agent.session = loaded;
    if (onSessionResumed != null) {
      onSessionResumed!(loaded);
    }
    _writeln(
      NibTheme.current.success.text(
        '  ✔ Resumed session "$id" (${loaded.messages.length} messages loaded).',
      ),
    );
  }

  Future<void> _handleNew() async {
    // Save current session first if it has any user messages
    if (agent.session.hasUserMessages) {
      await agent.session.saveToDisk();
    }

    final workspace = Directory.current.path;
    final newSession = AgentSession.createNew(
      appendPrompt: config?.systemPromptAppend,
      workspacePath: workspace,
    );

    agent.session = newSession;
    UndoManager.instance.clearHistory();
    agent.meter.reset();

    _writeln(
      NibTheme.current.success.text(
        '  ✔ Started new session "${newSession.id}".',
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
        _writeln();
        _writeln(
          Ansi.boldText(
            'Registered Agent Skills (${all.where((s) => s.isEnabled).length}/${all.length} active):',
          ),
        );
        if (all.isEmpty) {
          _writeln(
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
            _writeln(
              '  $statusBadge $scopeBadge ${theme.accent.text(s.name.padRight(16))} ${theme.muted.text(s.description)}',
            );
          }
        }
        _writeln(
          '\n  ${theme.muted.text('Commands: /skills show <name> | /skills run <name> [instructions] | /skills enable|disable <name> | /skills reload')}',
        );
        _writeln();
        break;

      case 'show':
      case 'view':
        if (target.isEmpty) {
          _writeln(theme.warning.text('  Usage: /skills show <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          _writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        _writeln();
        final title = 'Skill: ${skill.name}';
        final topUsed = 9 + title.length;
        final topRule = max(2, 40 - topUsed);
        _writeln(
          '  ${theme.muted.text('╭──')} ${theme.accent.text(title)} ${theme.muted.text('─' * topRule)}',
        );
        _writeln('    Location: ${theme.muted.text(skill.filePath)}');
        _writeln(
          '    Status:   ${skill.isEnabled ? theme.success.text('Active') : theme.muted.text('Disabled')}',
        );
        _writeln('  ${theme.muted.text('╰──${'─' * 35}')}');
        _writeln(MarkdownRenderer.render(skill.content, theme));
        _writeln();
        break;

      case 'toggle':
        if (target.isEmpty) {
          _writeln(theme.warning.text('  Usage: /skills toggle <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          _writeln(theme.warning.text('  Skill "$target" not found.'));
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
        _writeln(
          '  ✔ Skill ${theme.accent.text(skill.name)} is now $stateStr.',
        );
        break;

      case 'enable':
        if (target.isEmpty) {
          _writeln(theme.warning.text('  Usage: /skills enable <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          _writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        mutated = true;
        skill.isEnabled = true;
        agent.session.rebuildSystemPrompt(
          appendPrompt: config?.systemPromptAppend,
        );
        _writeln(
          '  ✔ Skill ${theme.accent.text(skill.name)} ${theme.success.text('ENABLED')}.',
        );
        break;

      case 'disable':
        if (target.isEmpty) {
          _writeln(theme.warning.text('  Usage: /skills disable <name>'));
          return;
        }
        final skill = SkillsManager.instance.findSkill(target);
        if (skill == null) {
          _writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        mutated = true;
        skill.isEnabled = false;
        agent.session.rebuildSystemPrompt(
          appendPrompt: config?.systemPromptAppend,
        );
        _writeln(
          '  ✔ Skill ${theme.accent.text(skill.name)} ${theme.muted.text('DISABLED')}.',
        );
        break;

      case 'run':
      case 'use':
        if (target.isEmpty) {
          _writeln(
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
          _writeln(theme.warning.text('  Skill "$target" not found.'));
          return;
        }
        if (!skill.isEnabled) {
          _writeln(
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
        _writeln(
          theme.success.text(
            '  ✔ Invoking skill "${skill.name}"${extra.isEmpty ? '' : ' with your instructions'}.',
          ),
        );
        break;

      case 'reload':
        _writeln(
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
        _writeln(
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
          _writeln(
            '  ✔ Skill ${theme.accent.text(skill.name)} is now $stateStr.',
          );
        } else {
          _writeln(
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

  void _handleThinking(List<String> args) {
    if (args.isEmpty) {
      _writeln();
      _writeln(Ansi.boldText('Thinking Level Configuration:'));
      _writeln('  Current Level: ${Ansi.cyanText(agent.thinkingLevel.label)}');
      _writeln(
        '  Ladder:        ${ThinkingLevel.values.map((l) => l == agent.thinkingLevel ? Ansi.cyanText('[${l.label}]') : l.label).join(' · ')}',
      );
      _writeln('  Shortcut:      Shift+Tab cycles live during prompting.');
      _writeln();
      return;
    }
    try {
      final level = ThinkingLevel.parse(args[0]);
      agent.thinkingLevel = level;
      _writeln(Ansi.greenText('  ✔ Thinking level set to "${level.label}".'));
    } catch (e) {
      _writeln(Ansi.redText('  ✖ $e'));
    }
  }

  Future<void> _handleImage(List<String> args) async {
    if (args.isEmpty) {
      _writeln(Ansi.grayText('  Checking clipboard for image...'));
      final clip = await ImageAttachment.fromClipboard();
      if (clip != null) {
        pendingImages.add(clip);
        _writeln(
          Ansi.greenText(
            '  ✔ Grabbed image from clipboard (${clip.width}x${clip.height}, ${clip.mimeType}). It will be included with your next prompt.',
          ),
        );
      } else {
        _writeln(
          Ansi.yellowText(
            '  ✖ No image found in clipboard. Use: /image <file-path> or mention @image.png (Tier 3).',
          ),
        );
      }
      return;
    }

    final rawPath = args.join(' ');
    final file = File(rawPath);
    if (!await file.exists()) {
      _writeln(Ansi.redText('  ✖ File "$rawPath" does not exist.'));
      return;
    }

    final attachment = await ImageAttachment.fromFile(file);
    if (attachment == null) {
      _writeln(
        Ansi.redText(
          '  ✖ Could not decode "$rawPath" as a valid image (PNG, JPEG, GIF, WEBP, BMP supported).',
        ),
      );
      return;
    }

    pendingImages.add(attachment);
    _writeln(
      Ansi.greenText(
        '  ✔ Attached image: $rawPath (${attachment.width}x${attachment.height}, ${attachment.mimeType}). It will be included with your next prompt.',
      ),
    );
  }

  void _showConfig() {
    _writeln();
    _writeln(Ansi.boldText('Nib Configuration:'));
    _writeln('  Active Provider:  ${Ansi.cyanText(agent.provider.name)}');
    _writeln(
      '  Active Model:     ${Ansi.brightCyanText(agent.provider.model)}',
    );
    _writeln(
      '  Thinking Level:   ${Ansi.magentaText(agent.thinkingLevel.label)}',
    );
    if (agent.provider is OpenAiProvider) {
      final oai = agent.provider as OpenAiProvider;
      _writeln('  Endpoint:         ${Ansi.grayText(oai.baseUrl)}');
    }
    if (config != null && config!.providers.isNotEmpty) {
      _writeln('\n${Ansi.boldText('Configured Providers:')}');
      for (final p in config!.providers.values) {
        final marker = p.name == agent.provider.name
            ? Ansi.greenText(' (active)')
            : '';
        _writeln(
          '  • ${Ansi.yellowText(p.name)}: model=${p.model}, endpoint=${p.baseUrl}$marker',
        );
      }
    }
    _writeln();
  }

  Future<void> _handleSetup() async {
    final updated = await ProviderSetupWizard.run(
      existingConfig: config,
      writer: _writer,
    );
    if (updated != null) {
      final pId = updated.defaultProvider.toLowerCase();
      if (pId == 'mock') {
        agent.provider = MockProvider();
      } else if (updated.providers.containsKey(pId)) {
        final p = updated.providers[pId]!;
        if (pId == 'anthropic') {
          agent.provider = AnthropicProvider(
            model: p.model,
            apiKey: p.resolvedApiKey,
            baseUrl: p.baseUrl.isNotEmpty ? p.baseUrl : null,
          );
        } else {
          agent.provider = OpenAiProvider(
            name: p.name,
            model: p.model,
            apiKey: p.resolvedApiKey,
            baseUrl: p.baseUrl,
          );
        }
      }
      _writeln(
        Ansi.greenText(
          '  ✔ Switched active provider to "${agent.provider.name}" (${agent.provider.model}).',
        ),
      );
    }
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
        apiKey: p.resolvedApiKey,
      );
      _writeln(
        Ansi.greenText(
          '  ✔ Switched to provider "$name" (${p.model} @ ${p.baseUrl})',
        ),
      );
    } else {
      _writeln(
        Ansi.yellowText(
          '  Provider "$name" not found in config. Available: ${config?.providers.keys.join(', ') ?? 'none'}',
        ),
      );
    }
  }

  void _showHistory() {
    final msgs = agent.session.messages;
    final meter = agent.meter;
    final session = agent.session;
    _writeln();
    _writeln(Ansi.boldText('Session Transcript Summary:'));
    _writeln('  Session ID:         ${Ansi.cyanText(session.id)}');
    _writeln('  Total messages:     ${msgs.length}');
    _writeln('  Tool executions:    ${session.toolExecutionsCount}');
    _writeln('  Undo history depth: ${UndoManager.instance.count}');
    _writeln();

    _writeln(
      '  ${Ansi.boldText('Session tokens generated:')}  ${Ansi.cyanText('${_formatTokens(session.totalCompletionTokens)} tok')}',
    );
    if (session.cumulativePromptTokens > 0) {
      final cached = session.cumulativeCachedTokens;
      final totalIn = session.cumulativePromptTokens;
      final cacheRate = totalIn > 0
          ? (cached / totalIn * 100).toStringAsFixed(1)
          : '0.0';
      _writeln(
        '  Cumulative input tokens:  ${Ansi.cyanText(_formatTokens(totalIn))} (cached: ${_formatTokens(cached)}, $cacheRate% cache hit)',
      );
    }
    _writeln();

    // The raw window numbers the ambient line leaves out, plus the threshold that
    // will trigger compaction. Seeing how far you are from compaction is what
    // keeps the transcript from changing underneath you (#21, doctrine rule 5).
    final occupied = meter.tokensFor(session);
    final provenance = meter.isMeasured
        ? Ansi.greenText('measured (provider usage)')
        : Ansi.yellowText('estimated (chars/4)');
    _writeln(Ansi.boldText('Context gauge (active prompt occupancy):'));
    _writeln(
      '  Occupied:           ${Ansi.cyanText('${_formatTokens(occupied)} / ${_formatTokens(meter.contextWindow)}')}  ${Ansi.boldText(meter.displayFor(session))}',
    );
    if (session.cachedPromptTokens > 0) {
      final cachedPct = occupied > 0
          ? (session.cachedPromptTokens / occupied * 100).toStringAsFixed(1)
          : '0.0';
      _writeln(
        '  Cached in prompt:   ${Ansi.greenText(_formatTokens(session.cachedPromptTokens))} ($cachedPct% of active prompt)',
      );
    }
    _writeln('  Basis:              $provenance');
    _writeln(
      '  Auto-compact at:    ${Ansi.cyanText(_formatTokens(meter.threshold))} (reserve ${_formatTokens(meter.reserve)})',
    );
    if (agent.velocityTracker.rollingRate > 0) {
      _writeln(
        '  Generation speed:   ${Ansi.cyanText('${agent.velocityTracker.rollingRate.toStringAsFixed(1)} tok/s')} (rolling avg)',
      );
    }
    _writeln();
  }

  static String _formatTokens(int tokens) =>
      tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : '$tokens';

  void _showTools() {
    _writeln();
    _writeln(Ansi.boldText('Registered Agent Tools:'));
    for (final tool in agent.tools) {
      _writeln('  ${Ansi.brightCyanText(tool.name)}: ${tool.description}');
    }
    _writeln();
  }

  void _handleModel(List<String> args) {
    if (args.isEmpty) {
      _writeln(
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
      _writeln(Ansi.greenText('  ✔ Model changed to $newModel'));
    } else {
      _writeln(
        Ansi.yellowText(
          '  Model switching currently supports OpenAI-compatible providers.',
        ),
      );
    }
  }

  void _handleSystem(List<String> args) {
    if (args.isEmpty) {
      _writeln();
      _writeln(Ansi.boldText('Current System Prompt:'));
      _writeln(agent.session.systemPrompt);
      _writeln();
    } else {
      final newPrompt = args.join(' ');
      agent.session.systemPrompt = newPrompt;
      agent.session.addSystemPromptIfNeeded();
      _writeln(Ansi.greenText('  ✔ System prompt updated.'));
    }
  }

  Future<void> _handleTheme(List<String> args) async {
    if (args.isEmpty) {
      final chosen = await ThemePicker.pickTheme(
        currentTheme: NibTheme.current,
        writer: _out,
        onPreview: (previewTheme) {
          if (onThemePreview != null) {
            onThemePreview!(previewTheme);
          } else {
            onRedraw?.call();
          }
        },
      );
      if (chosen != null) {
        onRedraw?.call();
      } else {
        if (onThemePreview != null) {
          onThemePreview!(NibTheme.current);
        } else {
          onRedraw?.call();
        }
      }
      return;
    }

    final target = args[0].toLowerCase().trim().replaceAll('_', '-');
    final aliases = <String, String>{
      'rose-pine': 'rosepine',
      'monokai-pro': 'monokai',
      'one-dark': 'onedark',
      'solarized': 'solarized-dark',
      'github': 'github-dark',
      'synthwave84': 'synthwave',
      'synthwave-84': 'synthwave',
    };
    final resolved = aliases[target] ?? target;

    if (NibTheme.allThemes.containsKey(resolved)) {
      NibTheme.setTheme(resolved);
      onRedraw?.call();
    } else {
      _writeln(
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
      _writeln(
        theme.warning.text(
          '  ✔ Interactive confirmation ENABLED (Nib will prompt before modifying files or running destructive commands)',
        ),
      );
    } else {
      _writeln(
        theme.muted.text(
          '  ✔ Interactive confirmation DISABLED (Auto-apply mode)',
        ),
      );
    }
  }

  Future<void> _handleCompact(List<String> args) async {
    final focus = args.isNotEmpty ? args.join(' ') : null;
    _writeln(
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
      _writeln(
        NibTheme.current.success.text(
          '  ✔ Compacted ${result.replacedMessageCount} messages '
          '(${result.tokensBefore} → ${result.tokensAfter} tokens).',
        ),
      );
    } else {
      _writeln(
        NibTheme.current.warning.text(
          '  Not enough messages in context to compact (needs at least ${CompactionManager.defaultKeepRecentMessages + 1} messages).',
        ),
      );
    }
  }
}
