import 'dart:async';
import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../agent/agent.dart';
import '../agent/config.dart';
import 'ansi.dart';
import 'autocomplete.dart';
import 'markdown_renderer.dart';
import 'prompt_reader.dart';
import 'slash_commands.dart';
import 'spinner.dart';
import 'status_bar.dart';
import 'terminal_manager.dart';
import 'theme.dart';

/// The upgraded pure terminal CLI UI for Nib.
class CliUi {
  final Agent agent;
  final NibConfig? config;
  final SlashCommandHandler _slashHandler;
  final TerminalSpinner _spinner = TerminalSpinner();
  final PromptReader _promptReader = PromptReader();

  bool _inThoughtBlock = false;
  bool _isExecutingTurn = false;
  DateTime? _lastSigintTime;
  StreamSubscription<ProcessSignal>? _sigintSub;

  CliUi(this.agent, [this.config])
    : _slashHandler = SlashCommandHandler(agent, config);

  /// Starts the interactive REPL terminal loop.
  Future<void> run() async {
    _setupSigintHandler();

    // Print welcoming Nib banner
    stdout.write(
      Ansi.banner(
        model: agent.provider.model,
        provider: agent.provider.name,
        workspace: Directory.current.path,
      ),
    );

    while (true) {
      final theme = NibTheme.current;

      // Render modern dock status bar above prompt
      stdout.writeln(StatusBar.render(agent));

      final promptString =
          '${theme.accent.text('nib')} ${theme.secondary.text('❯')} ';
      final input = await _readMultiLineInput(promptString);

      if (input == null) {
        // EOF (Ctrl+D)
        stdout.writeln();
        stdout.writeln(theme.muted.text('Session saved. Goodbye!'));
        break;
      }

      final trimmed = input.trim();
      if (trimmed.isEmpty) continue;

      // Check slash commands (/help, /clear, /undo, /theme, etc.)
      if (await _slashHandler.handle(trimmed)) {
        continue;
      }

      // Automatically expand @file mentions into prompt context
      final expandedPrompt = await AutoCompleter.expandFileMentions(trimmed);

      // Execute agent turn with live streaming callbacks
      await _executeAgentTurn(expandedPrompt);
    }

    await _sigintSub?.cancel();
  }

  /// Sets up graceful SIGINT (Ctrl+C) handling.
  void _setupSigintHandler() {
    try {
      _sigintSub = ProcessSignal.sigint.watch().listen((signal) {
        if (_isExecutingTurn) {
          _spinner.stop();
          agent.cancel();
          stdout.writeln(
            '\n  ${NibTheme.current.warning.text('⚠ Turn cancelled by user.')}',
          );
        } else {
          final now = DateTime.now();
          if (_lastSigintTime != null &&
              now.difference(_lastSigintTime!) < const Duration(seconds: 2)) {
            stdout.writeln('\n${NibTheme.current.muted.text('Exiting...')}');
            TerminalManager.instance.shutdown(0);
          } else {
            _lastSigintTime = now;
            stdout.writeln(
              '\n  ${NibTheme.current.muted.text('(Press Ctrl+C again to exit, or /exit)')}',
            );
            final theme = NibTheme.current;
            stdout.write(
              '${theme.accent.text('nib')} ${theme.secondary.text('❯')} ',
            );
          }
        }
      });
    } catch (_) {
      // Piped test environments may not support SIGINT signal watching
    }
  }

  /// Handles multi-line input (if ends with `\` or wrapped in `"""`).
  Future<String?> _readMultiLineInput(String prompt) async {
    String? firstLine = await _promptReader.readLine(prompt: prompt);
    if (firstLine == null) return null;

    final theme = NibTheme.current;

    // Check for multi-line block mode: starts with """
    if (firstLine.trim().startsWith('"""')) {
      final buffer = StringBuffer();
      final remainder = firstLine.trim().substring(3);
      if (remainder.endsWith('"""') && remainder.length > 3) {
        return remainder.substring(0, remainder.length - 3);
      }
      buffer.writeln(remainder);

      while (true) {
        final line = await _promptReader.readLine(
          prompt: '${theme.muted.text('...')} ${theme.secondary.text('❯')} ',
        );
        if (line == null) break;
        if (line.trim().endsWith('"""')) {
          buffer.writeln(line.trim().substring(0, line.trim().length - 3));
          break;
        }
        buffer.writeln(line);
      }
      return buffer.toString().trim();
    }

    // Check trailing backslash continuation: \
    if (firstLine.trim().endsWith('\\')) {
      final buffer = StringBuffer();
      buffer.writeln(
        firstLine.trim().substring(0, firstLine.trim().length - 1).trim(),
      );

      while (true) {
        final nextLine = await _promptReader.readLine(
          prompt: '${theme.muted.text('...')} ${theme.secondary.text('❯')} ',
        );
        if (nextLine == null) break;
        if (nextLine.trim().endsWith('\\')) {
          buffer.writeln(
            nextLine.trim().substring(0, nextLine.trim().length - 1).trim(),
          );
        } else {
          buffer.writeln(nextLine);
          break;
        }
      }
      return buffer.toString().trim();
    }

    return firstLine;
  }

  /// Runs a single turn with the given prompt.
  Future<void> runWithPrompt(String prompt) async {
    _setupSigintHandler();
    final expandedPrompt = await AutoCompleter.expandFileMentions(prompt);
    await _executeAgentTurn(expandedPrompt);
    await _sigintSub?.cancel();
  }

  Future<void> _executeAgentTurn(String prompt) async {
    stdout.writeln();
    _inThoughtBlock = false;
    _isExecutingTurn = true;
    final theme = NibTheme.current;
    final markdownPrinter = StreamingMarkdownPrinter(theme: theme);

    _spinner.start('Thinking...');

    final callbacks = AgentCallbacks(
      onThoughtDelta: (thought) {
        _spinner.recordToken();
        if (!_inThoughtBlock) {
          _spinner.stop();
          stdout.write('  ${theme.muted.text('💭 ')}');
          _inThoughtBlock = true;
        }
        stdout.write(theme.muted.text(thought));
      },
      onTextDelta: (text) {
        _spinner.stop();
        if (_inThoughtBlock) {
          stdout.writeln();
          stdout.writeln();
          _inThoughtBlock = false;
        }
        markdownPrinter.addDelta(text);
      },
      onToolCallStarted: (call) {
        _spinner.stop();
        if (_inThoughtBlock) {
          stdout.writeln();
          stdout.writeln();
          _inThoughtBlock = false;
        }
        markdownPrinter.flush();
        final argsSummary = _formatToolArgsSummary(call.name, call.arguments);
        stdout.writeln();
        stdout.writeln(
          '  ${theme.muted.text('╭─')} ${theme.warning.text('⚙')} ${theme.accent.text(call.name)} ${theme.secondary.text(argsSummary)} ${theme.muted.text('──────────────────────────────')}',
        );
        _spinner.start('Running ${call.name}...');
      },
      onToolCallFinished: (call, result, duration) {
        _spinner.stop();
        final ms = duration.inMilliseconds;
        final preview = _formatResultPreview(call.name, result);
        if (preview.isNotEmpty) {
          for (final line in preview) {
            stdout.writeln('  ${theme.muted.text('│')}  $line');
          }
        }
        stdout.writeln(
          '  ${theme.muted.text('╰─')} ${theme.success.text('✔')} ${theme.muted.text('done (${ms}ms)')} ${theme.muted.text('──────────────────────────────────────')}',
        );
        stdout.writeln();
      },
      onToolProgress: (call, line) {
        final clean = line
            .replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '')
            .trim();
        if (clean.isNotEmpty) {
          const maxLen = 45;
          final short = clean.length > maxLen
              ? '${clean.substring(0, maxLen)}...'
              : clean;
          _spinner.updateMessage('${call.name}: $short');
        }
      },
      onError: (error) {
        _spinner.stop();
        if (_inThoughtBlock) {
          stdout.writeln();
          _inThoughtBlock = false;
        }
        markdownPrinter.flush();
        stdout.writeln();
        stdout.writeln('  ${theme.error.text('✖ Error:')} $error');
        stdout.writeln();
      },
    );

    StreamSubscription<Key>? keySub;
    if (stdin.hasTerminal) {
      TerminalManager.instance.initialize();
      keySub = TerminalManager.instance.keyStream.listen((key) {
        if (key.isControl &&
            (key.controlChar == ControlCharacter.escape ||
                key.controlChar == ControlCharacter.ctrlC)) {
          _spinner.stop();
          agent.cancel();
          TerminalManager.instance.clearBuffer();
          final keyName = key.controlChar == ControlCharacter.escape
              ? 'Esc'
              : 'Ctrl+C';
          stdout.writeln(
            '\n  ${theme.warning.text('⚠ Turn cancelled by user ($keyName).')}',
          );
        }
      });
    }

    try {
      await agent.runTurn(prompt, callbacks: callbacks);
    } catch (e) {
      _spinner.stop();
      markdownPrinter.flush();
      stdout.writeln();
      stdout.writeln('  ${theme.error.text('✖ Exception:')} $e');
    } finally {
      await keySub?.cancel();
      _spinner.stop();
      markdownPrinter.flush();
      _isExecutingTurn = false;
      TerminalManager.instance.clearBuffer();
    }

    stdout.writeln();
  }

  String _formatToolArgsSummary(String toolName, Map<String, dynamic> args) {
    if (toolName == 'bash' && args.containsKey('command')) {
      final cmd = args['command'] as String;
      return '"$cmd"';
    }
    if ((toolName == 'read_file' ||
            toolName == 'write_file' ||
            toolName == 'edit_file') &&
        args.containsKey('path')) {
      final path = args['path'] as String;
      if (args.containsKey('start_line') || args.containsKey('end_line')) {
        return '$path (${args['start_line'] ?? 1}-${args['end_line'] ?? 'end'})';
      }
      return path;
    }
    if (toolName == 'list_dir' && args.containsKey('path')) {
      return args['path'] as String;
    }
    if (toolName == 'search_files' && args.containsKey('query')) {
      return '"${args['query']}"';
    }
    if (args.isEmpty) return '';
    return args.entries.map((e) => '${e.key}: ${e.value}').take(2).join(', ');
  }

  List<String> _formatResultPreview(String toolName, String result) {
    final lines = result.split('\n');
    if (lines.isEmpty || (lines.length == 1 && lines[0].isEmpty)) {
      return [];
    }

    // For edit_file, print the diff nicely with preserved color
    if (toolName == 'edit_file') {
      const maxDiffLines = 14;
      final shown = lines.take(maxDiffLines).toList();
      final res = <String>[];
      for (final line in shown) {
        res.add(line);
      }
      if (lines.length > maxDiffLines) {
        res.add(
          NibTheme.current.muted.text(
            '... (${lines.length - maxDiffLines} more lines)',
          ),
        );
      }
      return res;
    }

    // Limit preview for bash and other tools
    const maxPreviewLines = 6;
    final shown = lines.take(maxPreviewLines).toList();
    final res = <String>[];
    for (final line in shown) {
      final truncated = line.length > 100
          ? '${line.substring(0, 97)}...'
          : line;
      res.add(NibTheme.current.muted.text(truncated));
    }

    if (lines.length > maxPreviewLines) {
      res.add(
        NibTheme.current.muted.text(
          '... (${lines.length - maxPreviewLines} more lines)',
        ),
      );
    }

    return res;
  }
}
