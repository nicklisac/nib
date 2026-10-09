import 'dart:async';
import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../agent/agent.dart';
import '../agent/approval_manager.dart';
import '../agent/config.dart';
import 'ambient_line.dart';
import 'ansi.dart';
import 'autocomplete.dart';
import 'markdown_renderer.dart';
import 'prompt_reader.dart';
import 'slash_commands.dart';
import 'status_bar.dart';
import 'terminal_manager.dart';
import 'theme.dart';

/// The upgraded pure terminal CLI UI for Nib.
///
/// Screen ownership is the organising rule (docs/adr/0001): the stream owns the
/// terminal while the model is speaking, the human owns it while a tool is
/// running. Ownership flips per iteration, not per turn, which is why the idle
/// prompt and the mid-turn draft are the same code path rather than a second
/// input system.
class CliUi {
  final Agent agent;
  final NibConfig? config;
  final SlashCommandHandler _slashHandler;
  final PromptReader _promptReader = PromptReader();

  /// The gauge lives on the Agent, which is the layer that knows what a request
  /// costs; the line only displays it.
  late final AmbientLine _ambient = AmbientLine(
    agent: agent,
    meter: agent.meter,
  );

  bool _inThoughtBlock = false;
  bool _isExecutingTurn = false;
  DateTime? _lastSigintTime;
  StreamSubscription<ProcessSignal>? _sigintSub;

  /// Whether the cursor currently sits at the start of a row, which is the only
  /// place the ambient line may be drawn.
  bool _atRowStart = true;

  /// Set when the running turn was interrupted. Decides what happens to a
  /// queued message: an interrupted turn restores it as a draft rather than
  /// sending it, because Esc means stop.
  bool _turnInterrupted = false;

  /// The draft held while a turn was interrupted, offered back at the prompt.
  String _resumedDraft = '';

  CliUi(this.agent, [this.config])
    : _slashHandler = SlashCommandHandler(agent, config) {
    _promptReader.onCompose = (queued) {
      _ambient.showComposition(queued: queued);
    };
    // The approval prompt *steals* the keys rather than contending for them, and
    // the half-composed draft is held meanwhile rather than dropped.
    ApprovalManager.instance.onApprovalStart = () async {
      // Only wait on a reader that actually exists: no window has run yet at the
      // first approval of a session, and awaiting a completer nobody completes
      // would hang the prompt.
      if (_draftWindowOpen) {
        _closeDraftWindow();
        await _draftReaderExited.future;
      }
      _ambient.hide();
    };
    ApprovalManager.instance.onApprovalEnd = () {
      _atRowStart = true;
      // Still inside the same tool execution, so the human still owns the row.
      if (_isExecutingTurn && !_turnInterrupted) _openDraftWindow();
    };
  }

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
    _atRowStart = true;

    while (true) {
      final theme = NibTheme.current;

      // The dock: provider / model / workspace. Printed once with the prompt and
      // left to scroll away — that is correct behaviour, not a bug. It names the
      // context of the exchange below it and follows that exchange into history.
      _writeLine(StatusBar.render(agent));

      final promptString =
          '${theme.accent.text('nib')} ${theme.secondary.text('❯')} ';
      final submitted = await _readTurn(promptString);

      // Cannot happen at the idle prompt — nothing closes a window there — but a
      // stray close must re-prompt rather than end the session.
      if (submitted != null && submitted.kind == SubmitKind.windowEnded) {
        continue;
      }

      if (submitted == null) {
        // EOF (Ctrl+D)
        _writeLine('');
        _writeLine(theme.muted.text('Session saved. Goodbye!'));
        break;
      }

      final input = submitted.text;
      final trimmed = input.trim();

      if (submitted.kind == SubmitKind.queue) {
        // Composed during a turn is impossible at the idle prompt, but Alt+Enter
        // there means the same thing: hold this, it is not for right now.
        _promptReader.enqueue(trimmed);
        _ambient.showComposition(queued: _promptReader.queued);
        continue;
      }

      if (trimmed.isEmpty) {
        if (submitted.kind == SubmitKind.flushQueue) {
          await _submitQueued();
        }
        continue;
      }

      // Check slash commands (/help, /clear, /undo, /theme, etc.)
      if (await _slashHandler.handle(trimmed)) {
        // A skill the human invoked runs as a normal turn, with the skill body
        // already loaded into the prompt.
        final invocation = _slashHandler.pendingInvocation;
        if (invocation != null) {
          _slashHandler.pendingInvocation = null;
          await _executeAgentTurn(invocation);
          await _afterTurn();
        }
        continue;
      }

      // Automatically expand @file mentions into prompt context
      final expandedPrompt = await AutoCompleter.expandFileMentions(trimmed);

      // Execute agent turn with live streaming callbacks
      await _executeAgentTurn(expandedPrompt);
      await _afterTurn();
    }

    await _sigintSub?.cancel();
  }

  /// Sets up graceful SIGINT (Ctrl+C) handling.
  ///
  /// Raw mode clears ISIG, so during interactive use Ctrl+C arrives as byte 0x03
  /// through the key stream and this handler does not fire; it matters before the
  /// first prompt and for a hard kill. Either way it must not discard a draft.
  void _setupSigintHandler() {
    try {
      _sigintSub = ProcessSignal.sigint.watch().listen((signal) {
        if (_isExecutingTurn) {
          _interruptTurn('Ctrl+C');
        } else {
          final now = DateTime.now();
          if (_lastSigintTime != null &&
              now.difference(_lastSigintTime!) < const Duration(seconds: 2)) {
            _writeLine('\n${NibTheme.current.muted.text('Exiting...')}');
            TerminalManager.instance.shutdown(0);
          } else {
            _lastSigintTime = now;
            _writeLine(
              '  ${NibTheme.current.muted.text('(Press Ctrl+C again to exit, or /exit)')}',
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

  /// Reads one prompt at the human-owned window, restoring any draft the last
  /// turn left behind and offering the queue for confirmation.
  Future<SubmitResult?> _readTurn(String promptString) async {
    var initial = _resumedDraft;
    _resumedDraft = '';

    if (initial.isNotEmpty) {
      final theme = NibTheme.current;
      _writeLine(
        '  ${theme.warning.text('⚠ Turn interrupted.')} ${theme.muted.text('Draft kept at the prompt.')} ${theme.muted.text('⏎ on an empty line sends it.')}',
      );
    } else if (_promptReader.hasQueued) {
      final theme = NibTheme.current;
      _writeLine(
        '  ${theme.muted.text('⏎ ${_promptReader.queued.split('\n').length} queued — ⏎ on an empty line sends it.')}',
      );
    }

    final first = await _promptReader.readSubmit(
      prompt: promptString,
      initial: initial,
      // Not the mid-turn window: here Esc dismisses the palette rather than
      // interrupting, and there is no turn to interrupt. Enter on an empty line
      // still hands a waiting queue over.
      hasQueued: _promptReader.hasQueued,
    );
    if (first == null || first.kind != SubmitKind.submit) return first;

    final continued = await _continueMultiLine(first.text);
    return SubmitResult(continued, SubmitKind.submit);
  }

  /// Explicit opt-in multi-line input: a line ending in a backslash continues, and
  /// text wrapped in triple quotes is a block. These gestures survive #20 because
  /// they are *deliberate*. The accidental case — a paste that sends line by line —
  /// is what bracketed paste now prevents, so nothing here has to guess.
  Future<String> _continueMultiLine(String firstLine) async {
    final theme = NibTheme.current;
    final continuationPrompt =
        '${theme.muted.text('...')} ${theme.secondary.text('❯')} ';
    final trimmed = firstLine.trim();
    final fence = '"""';

    if (trimmed.startsWith(fence)) {
      final buffer = StringBuffer();
      final remainder = trimmed.substring(fence.length);
      if (remainder.endsWith(fence) && remainder.length > fence.length) {
        return remainder.substring(0, remainder.length - fence.length);
      }
      buffer.writeln(remainder);
      return _readUntilBlockEnd(buffer, continuationPrompt, fence);
    }

    if (trimmed.endsWith(r'\')) {
      final buffer = StringBuffer();
      buffer.writeln(trimmed.substring(0, trimmed.length - 1).trim());
      return _readUntilBlockEnd(buffer, continuationPrompt, null);
    }

    return firstLine;
  }

  Future<String> _readUntilBlockEnd(
    StringBuffer buffer,
    String prompt,
    String? blockTerminator,
  ) async {
    while (true) {
      final line = await _promptReader.readLine(prompt: prompt);
      if (line == null) break;
      final t = line.trim();
      if (blockTerminator != null) {
        if (t.endsWith(blockTerminator)) {
          buffer.writeln(t.substring(0, t.length - blockTerminator.length));
          break;
        }
      } else if (t.endsWith(r'\')) {
        buffer.writeln(t.substring(0, t.length - 1).trim());
      } else {
        buffer.writeln(line);
        break;
      }
    }
    return buffer.toString().trim();
  }

  /// Submits the queued message as the next turn. It never enters the transcript
  /// as an assistant statement — it is a user message like any other.
  Future<void> _submitQueued() async {
    final queued = _promptReader.takeQueued();
    if (queued.trim().isEmpty) return;
    _promptReader.addToHistory(queued);
    final expanded = await AutoCompleter.expandFileMentions(queued.trim());
    await _executeAgentTurn(expanded);
    await _afterTurn();
  }

  /// What happens to a queued message once the turn that was running is over.
  ///
  /// Turn ended normally → the queue is submitted as the next turn. Turn
  /// interrupted → the queue is restored as the draft instead, because Esc means
  /// stop and auto-sending a moment later is sending something that was not meant
  /// for that moment.
  Future<void> _afterTurn() async {
    if (!_promptReader.hasQueued) return;
    if (_turnInterrupted) {
      _resumedDraft = _promptReader.takeQueued();
      return;
    }
    await _submitQueued();
  }

  /// Runs a single turn with the given prompt.
  Future<void> runWithPrompt(String prompt) async {
    _setupSigintHandler();
    final expandedPrompt = await AutoCompleter.expandFileMentions(prompt);
    await _executeAgentTurn(expandedPrompt);
    await _sigintSub?.cancel();
  }

  /// Writes a line of transcript output, clearing the ambient row first and
  /// reclaiming it afterwards. Every write that does not end with a newline must
  /// go through [stdout.write] directly with the row suspended.
  void _writeLine(String line) {
    // Mid-turn the row must survive the line; at rest there is no row to keep.
    if (_isExecutingTurn) {
      _ambient.clearForTranscriptWrite();
    } else {
      _ambient.hide();
    }
    stdout.writeln(line);
    _atRowStart = true;
    _ambient.resumeAfterLineWrite();
  }

  /// The one writer of the ambient row during streaming: wrap the markdown
  /// printer's output so the row is erased before a write and redrawn only when
  /// the write left the cursor at the start of a row. A partial line leaves the
  /// row hidden rather than painted over text — the point of the rule.
  void _writeStreamText(String text) {
    _closeDraftWindow();
    _ambient.suspendForInlineWrite();
    stdout.write(text);
    _atRowStart = text.endsWith('\n');
    if (_atRowStart) _ambient.resumeAfterLineWrite();
  }

  /// The single interrupt path: Esc or Ctrl+C, and nothing else. It stops the
  /// turn, keeps the draft, and leaves any queued message for the human to
  /// re-send deliberately.
  void _interruptTurn(String keyName) {
    if (!_isExecutingTurn) return;
    _turnInterrupted = true;
    agent.cancel();

    final draft = TerminalManager.instance.draft;
    final hadDraft = draft.trim().isNotEmpty || _promptReader.hasQueued;
    if (hadDraft) {
      // A mid-turn draft becomes the queue slot, which an interrupt restores as a
      // draft at the prompt. Nothing typed is discarded (feel doctrine rule 2).
      if (draft.trim().isNotEmpty) _promptReader.enqueue(draft);
      TerminalManager.instance.draft = '';
    }
    TerminalManager.instance.clearBuffer();

    final theme = NibTheme.current;
    _writeLine(
      '  ${theme.warning.text('⚠ Turn interrupted ($keyName).')}'
      '${hadDraft ? ' ${theme.muted.text('Draft kept.')}' : ''}',
    );
    _ambient.showInterrupted(keyName: keyName, draftKept: hadDraft);
  }

  Future<void> _executeAgentTurn(String prompt) async {
    _turnInterrupted = false;
    _inThoughtBlock = false;
    _isExecutingTurn = true;
    final theme = NibTheme.current;
    final markdownPrinter = StreamingMarkdownPrinter(
      theme: theme,
      out: _writeStreamText,
    );

    _writeLine('');
    _ambient.startTurn();

    final callbacks = AgentCallbacks(
      onThoughtDelta: (thought) {
        _closeDraftWindow();
        _ambient.recordToken();
        if (!_inThoughtBlock) {
          _ambient.clearForTranscriptWrite();
          stdout.write('  ${theme.muted.text('💭 ')}');
          _atRowStart = false;
          _inThoughtBlock = true;
        }
        _ambient.suspendForInlineWrite();
        stdout.write(theme.muted.text(thought));
        _atRowStart = thought.endsWith('\n');
        if (_atRowStart) _ambient.resumeAfterLineWrite();
      },
      onTextDelta: (text) {
        if (_inThoughtBlock) {
          _ambient.clearForTranscriptWrite();
          stdout.writeln();
          stdout.writeln();
          _atRowStart = true;
          _ambient.resumeAfterLineWrite();
          _inThoughtBlock = false;
        }
        markdownPrinter.addDelta(text);
      },
      onToolCallStarted: (call) {
        markdownPrinter.flush();
        if (_inThoughtBlock) {
          _ambient.clearForTranscriptWrite();
          stdout.writeln();
          stdout.writeln();
          _atRowStart = true;
          _inThoughtBlock = false;
        }
        final argsSummary = _formatToolArgsSummary(call.name, call.arguments);
        // The divider at the top of the human-owned window: one, and it is the
        // tool card's own rule. Its length follows the terminal, not a constant.
        _ambient.clearForTranscriptWrite();
        stdout.writeln(
          '  ${theme.muted.text('╭─')} ${theme.warning.text('⚙')} ${theme.accent.text(call.name)} ${theme.secondary.text(argsSummary)} ${theme.muted.text('─' * _ruleFill(4 + 2 + call.name.length + argsSummary.length))}',
        );
        _atRowStart = true;
        // Ownership flips to the human here. This is the window in which the
        // draft line opens on the same reader path as the idle prompt; nothing is
        // being written, so there is nothing to collide with.
        _ambient.showTool(call.name);
        _openDraftWindow();
      },
      onToolCallFinished: (call, result, duration) {
        _closeDraftWindow();
        final ms = duration.inMilliseconds;
        final preview = _formatResultPreview(call.name, result);
        _ambient.clearForTranscriptWrite();
        for (final line in preview) {
          stdout.writeln('  ${theme.muted.text('│')}  $line');
        }
        stdout.writeln(
          '  ${theme.muted.text('╰─')} ${theme.success.text('✔')} ${theme.muted.text('done (${ms}ms)')} ${theme.muted.text('─' * _ruleFill(4 + 2 + call.name.length + 12))}',
        );
        stdout.writeln();
        _atRowStart = true;
        _ambient.resumeAfterLineWrite();
        _ambient.resumeStreaming();
      },
      onToolProgress: (call, line) {
        final clean = line
            .replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '')
            .trim();
        if (clean.isNotEmpty) _ambient.showToolProgress(clean);
      },
      onError: (error) {
        _closeDraftWindow();
        markdownPrinter.flush();
        if (_inThoughtBlock) {
          _ambient.clearForTranscriptWrite();
          stdout.writeln();
          _atRowStart = true;
          _inThoughtBlock = false;
        }
        _ambient.clearForTranscriptWrite();
        stdout.writeln();
        stdout.writeln('  ${theme.error.text('✖ Error:')} $error');
        stdout.writeln();
        _atRowStart = true;
        _ambient.resumeStreaming();
      },
    );

    // One key path for the whole turn. Esc and Ctrl+C are the exclusive "stop it"
    // gesture; everything else typed during a tool window goes to the draft,
    // which is what the reader owns. #23's single multiplexed owner is this
    // listener plus the reader's `nextInput()`, with no second cancel handler and
    // no spill buffer for typed text to die in.
    StreamSubscription<Object>? inputSub;
    if (stdin.hasTerminal) {
      TerminalManager.instance.initialize();
      inputSub = TerminalManager.instance.inputStream.listen((event) {
        if (_draftWindowOpen) return; // The reader owns the keys right now.
        final key = event is Key ? event : null;
        if (key != null &&
            key.isControl &&
            (key.controlChar == ControlCharacter.escape ||
                key.controlChar == ControlCharacter.ctrlC)) {
          _interruptTurn(
            key.controlChar == ControlCharacter.escape ? 'Esc' : 'Ctrl+C',
          );
        }
      });
    }

    try {
      await agent.runTurn(prompt, callbacks: callbacks);
    } catch (e) {
      _ambient.clearForTranscriptWrite();
      markdownPrinter.flush();
      _writeLine('  ${theme.error.text('✖ Exception:')} $e');
    } finally {
      _closeDraftWindow();
      // Harvest anything still being composed. A tool can finish with a draft in
      // hand and no further tool to reopen the window, and the idle prompt would
      // otherwise overwrite it (feel doctrine rule 2). The queue slot is where it
      // waits: delivered if the turn ended normally, restored if it was stopped.
      final stranded = TerminalManager.instance.draft;
      if (stranded.trim().isNotEmpty) {
        _promptReader.enqueue(stranded);
        TerminalManager.instance.draft = '';
      }
      await inputSub?.cancel();
      _ambient.endTurn();
      markdownPrinter.flush();
      _isExecutingTurn = false;
      // Buffered *keys* may be stale and are discarded; the draft is not a key and
      // is deliberately left alone.
      TerminalManager.instance.clearBuffer();
    }

    _writeLine('');
  }

  /// Opens the human-owned window: a tool is running, nothing is being written,
  /// so the draft line may open at the current cursor on the idle prompt's own
  /// reader path. It is fire-and-forget — the turn does not wait for it — and it
  /// closes itself the moment the stream needs the screen back.
  void _openDraftWindow() {
    if (!stdin.hasTerminal || _draftWindowOpen) return;
    TerminalManager.instance.clearEndWindowSentinels();
    _draftWindowOpen = true;
    unawaited(_readDraftWindow());
  }

  /// Hands the screen back to the stream. The reader is released with a sentinel
  /// rather than left parked, because a parked reader holds the row the transcript
  /// is about to write. A half-composed draft survives the handover: it lives on
  /// [TerminalManager.draft], where neither a stale-key purge nor a window close
  /// can reach it, and the next window reopens with it.
  void _closeDraftWindow() {
    if (!_draftWindowOpen) return;
    _draftWindowOpen = false;
    TerminalManager.instance.endWindow();
  }

  bool _draftWindowOpen = false;
  Completer<void> _draftReaderExited = Completer<void>();

  Future<void> _readDraftWindow() async {
    final theme = NibTheme.current;
    final promptString =
        '${theme.secondary.text('…')} ${theme.accent.text('›')} ';
    _draftReaderExited = Completer<void>();
    // Inside this window Esc / Ctrl+C is the interrupt, and nothing else.
    _promptReader.onInterrupt = (keyName) => _interruptTurn(keyName);
    while (_draftWindowOpen && _isExecutingTurn && !_turnInterrupted) {
      final result = await _promptReader.readSubmit(
        prompt: promptString,
        initial: TerminalManager.instance.draft,
        window: true,
        // Silent until the human types: the window opens on every tool call, and a
        // prompt row that flashes and vanishes is a row Nib wrote for nothing.
        silent: true,
        hasQueued: _promptReader.hasQueued,
      );
      if (result == null) break;
      // Alt+Enter is the queue gesture Nick already uses in Tau: hold this, send
      // it when you are done.
      if (result.kind == SubmitKind.queue) {
        // Alt+Enter: this draft is complete and waits for the turn to end. It must
        // land in the queue slot, not be discarded on the way out.
        _promptReader.enqueue(result.text);
        break;
      }
      if (result.kind != SubmitKind.submit || result.text.trim().isEmpty) {
        break;
      }
      _promptReader.enqueue(result.text);
    }
    _draftWindowOpen = false;
    _promptReader.onInterrupt = null;
    if (!_draftReaderExited.isCompleted) _draftReaderExited.complete();
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
      res.addAll(shown);
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

  /// Width of the tool card's filler rule, following the terminal instead of a
  // hardcoded constant, and capped with the transcript (#24).
  int _ruleFill(int used) {
    var cols = 80;
    try {
      if (stdout.hasTerminal) cols = stdout.terminalColumns;
    } catch (_) {}
    if (cols > 100) cols = 100;
    final fill = cols - used - 4;
    return fill < 2 ? 2 : fill;
  }
}
