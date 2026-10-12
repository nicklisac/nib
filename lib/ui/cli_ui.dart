import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dart_console/dart_console.dart';
import '../agent/agent.dart';
import '../agent/approval_manager.dart';
import '../agent/config.dart';
import '../agent/session.dart';
import '../ai/image_attachment.dart';
import 'ambient_line.dart';
import 'ansi.dart';
import 'autocomplete.dart';
import 'key_binding.dart';
import 'markdown_renderer.dart';
import 'prompt_reader.dart';
import 'screen_coordinator.dart';
import 'session_picker.dart';
import 'slash_commands.dart';
import 'status_bar.dart';
import 'terminal_manager.dart';
import 'theme.dart';
import 'transcript_render_model.dart';

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
  SlashCommandHandler get slashHandler => _slashHandler;
  final PromptReader _promptReader = PromptReader();

  /// Retained transcript model for full replay and display filters.
  final TranscriptRenderModel _renderModel = TranscriptRenderModel();
  TranscriptRenderModel get renderModel => _renderModel;
  bool _thinkingExpanded = true;
  bool _toolsExpanded = true;

  /// The gauge lives on the Agent, which is the layer that knows what a request
  /// costs; the line only displays it.
  late final AmbientLine _ambient = AmbientLine(
    agent: agent,
    meter: agent.meter,
  );

  bool _inThoughtBlock = false;

  /// The uncommitted thought/text of the running turn, so a mid-turn redraw
  /// (Ctrl+T, Ctrl+L) can repaint what has streamed so far.
  StringBuffer? _activeThoughtBuffer;
  StringBuffer? _activeTextBuffer;
  bool _isExecutingTurn = false;
  DateTime? _lastSigintTime;
  StreamSubscription<ProcessSignal>? _sigintSub;

  /// Set when the running turn was interrupted. Decides what happens to a
  /// queued message: an interrupted turn restores it as a draft rather than
  /// sending it, because Esc means stop.
  bool _turnInterrupted = false;

  /// The draft held while a turn was interrupted, offered back at the prompt.
  String _resumedDraft = '';

  final void Function(String text)? _outSink;

  /// Whether static session facts are pinned in the bottom band. When they are
  /// not — a non-TTY run, or a terminal too short to spare the row — the dock
  /// prints with the prompt instead, so those facts are on screen either way.
  bool _bandPinned = false;

  CliUi(this.agent, [this.config, void Function(String text)? out])
    : _outSink = out,
      _slashHandler = SlashCommandHandler(agent, config) {
    _slashHandler.onRedraw = () {
      redrawScreen();
    };
    _slashHandler.onThemePreview = (previewTheme) {
      if (ScreenCoordinator.instance.isActive) {
        _refreshBand();
        _ambient.renderDirect();
      }
    };
    _slashHandler.onSessionResumed = (loaded) {
      populateRenderModelFromSession(loaded);
      redrawScreen();
    };
    if (config != null && config!.keybindings.isNotEmpty) {
      _promptReader.keyBindings = KeyBindings.fromJson(config!.keybindings);
    }
    _promptReader.onCompose = (queued) {
      _ambient.showComposition(queued: queued);
    };
    _promptReader.onThinkingCycle = () {
      agent.thinkingLevel = agent.thinkingLevel.next();
      if (ScreenCoordinator.instance.isActive) {
        _ambient.renderDirect();
      }
    };
    _promptReader.onRedraw = () {
      redrawScreen();
    };
    _promptReader.onToggleThinking = () {
      _thinkingExpanded = !_thinkingExpanded;
      redrawScreen();
    };
    _promptReader.onToggleToolResults = () {
      _toolsExpanded = !_toolsExpanded;
      redrawScreen();
    };
    _promptReader.onSessionPicker = () async {
      final chosen = await SessionPicker.pickSession(
        currentSession: agent.session,
      );
      if (chosen != null && chosen != agent.session.id) {
        final loaded = await AgentSession.loadFromDisk(chosen);
        if (loaded != null) {
          agent.session = loaded;
          populateRenderModelFromSession(loaded);
          redrawScreen();
          final theme = NibTheme.current;
          _writeLine(
            theme.success.text(
              '  ✔ Switched to session "$chosen" (${loaded.messages.length} messages).',
            ),
          );
        }
      }
    };
    // The approval prompt *steals* the keys rather than contending for them, and
    // the half-composed draft is held meanwhile rather than dropped.
    ApprovalManager.instance.onApprovalStart = () async {
      // Only wait on a reader that actually exists: no window has run yet at the
      // first approval of a session, and awaiting a completer nobody completes
      // would hang the prompt.
      if (_draftWindowOpen) {
        await _stopTurnInput();
      }
      _ambient.hide();
    };
    ApprovalManager.instance.onApprovalEnd = () {
      // Still inside the same tool execution, so the human still owns the row.
      if (_isExecutingTurn && !_turnInterrupted) _startTurnInput();
    };
  }

  /// Starts the interactive REPL terminal loop.
  Future<void> run() async {
    _setupSigintHandler();

    StreamSubscription<ProcessSignal>? sigwinchSub;
    Timer? resizeDebounce;
    if (ScreenCoordinator.instance.isSupported) {
      _bandPinned = ScreenCoordinator.instance.activate(
        band: StatusBar.bandSegments(agent),
      );
      try {
        if (!Platform.isWindows) {
          sigwinchSub = ProcessSignal.sigwinch.watch().listen((_) {
            resizeDebounce?.cancel();
            resizeDebounce = Timer(const Duration(milliseconds: 50), () {
              ScreenCoordinator.instance.updateTerminalSize();
              _bandPinned = ScreenCoordinator.instance.bandLines > 0;
              _ambient.renderDirect();
              _promptReader.repaintCurrentLine();
            });
          });
        }
      } catch (_) {}
    }

    try {
      if (agent.session.hasUserMessages) {
        populateRenderModelFromSession(agent.session);
        redrawScreen();
      } else {
        // Print welcoming Nib banner
        _writeStreamText(
          Ansi.banner(
            model: agent.provider.model,
            provider: agent.provider.name,
            workspace: Directory.current.path,
          ),
        );
      }

      _ambient.showIdle();

      while (true) {
        final theme = NibTheme.current;

        // Static session facts live in the pinned bottom band. The dock prints
        // in its place when there is no band, so the facts are never missing.
        if (!_bandPinned) {
          _writeLine(StatusBar.render(agent));
        }

        final promptString = ScreenCoordinator.instance.isActive
            ? '${theme.secondary.text('❯')} '
            : '${theme.accent.text('✒')}  ${theme.secondary.text('❯')} ';
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

        final hasAttachments =
            _slashHandler.pendingImages.isNotEmpty ||
            _promptReader.attachedImages.isNotEmpty;

        if (trimmed.isEmpty && !hasAttachments) {
          if (submitted.kind == SubmitKind.flushQueue) {
            await _submitQueued(showDock: false);
          }
          continue;
        }

        final effectiveText = (trimmed.isEmpty && hasAttachments)
            ? 'Describe this image.'
            : trimmed;

        // Check slash commands (/help, /clear, /undo, /theme, etc.)
        if (await _slashHandler.handle(effectiveText)) {
          // /provider, /model, /mock and /theme change what the band says.
          // Repainting after every command is cheaper than tracking which four
          // of them matter, and a repaint only touches rows the band owns.
          _refreshBand();
          // A skill the human invoked runs as a normal turn, with the skill body
          // already loaded into the prompt.
          final invocation = _slashHandler.pendingInvocation;
          if (invocation != null) {
            _slashHandler.pendingInvocation = null;
            if (ScreenCoordinator.instance.isActive) {
              renderUserTurn(invocation);
            }
            await _executeAgentTurn(invocation);
            await _afterTurn();
          }
          continue;
        }

        if (ScreenCoordinator.instance.isActive) {
          renderUserTurn(effectiveText);
        }

        // Check for attached images from /image or prompt mentions/paths or prompt reader
        final imageExtraction = await ImageAttachment.extractFromPrompt(
          effectiveText,
        );
        final attachments = <ImageAttachment>[
          ..._slashHandler.pendingImages,
          ..._promptReader.attachedImages,
          ...imageExtraction.images,
        ];
        _slashHandler.pendingImages.clear();
        _promptReader.attachedImages.clear();

        if (attachments.isNotEmpty) {
          final provConf = config?.providers[agent.provider.name];
          if (provConf?.supportsImages == false) {
            _writeLine(
              theme.warning.text(
                '  ⚠ Model "${agent.provider.model}" is configured as text-only and does not support image input.',
              ),
            );
          } else {
            for (final img in attachments) {
              final label = img.originalPath ?? 'clipboard';
              _writeLine(
                theme.secondary.text(
                  '  🖼 Attached: $label (${img.width}x${img.height}, ${img.mimeType})',
                ),
              );
            }
          }
        }

        // Automatically expand @file mentions into prompt context
        final expandedPrompt = await AutoCompleter.expandFileMentions(trimmed);

        // Execute agent turn with live streaming callbacks
        await _executeAgentTurn(expandedPrompt, images: attachments);
        await _afterTurn();
      }
    } finally {
      ScreenCoordinator.instance.deactivate();
      resizeDebounce?.cancel();
      await sigwinchSub?.cancel();
      await _sigintSub?.cancel();
    }
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
              '${theme.accent.text('✒')}  ${theme.secondary.text('❯')} ',
            );
          }
        }
      });
    } catch (_) {
      // Piped test environments may not support SIGINT signal watching
    }
  }

  /// Re-lays-out and repaints the pinned facts band from current provider state.
  ///
  /// Band rows are outside the DECSTBM region, so this cannot scroll the
  /// transcript; if the facts no longer fit the same number of rows the scroll
  /// region is re-set, which is the only geometry change it can make.
  void _refreshBand() {
    if (!ScreenCoordinator.instance.isActive) return;
    ScreenCoordinator.instance.setBand(
      StatusBar.bandSegments(agent),
      width: ScreenCoordinator.instance.terminalColumns,
    );
    _bandPinned = ScreenCoordinator.instance.bandLines > 0;
  }

  /// Reads one prompt at the human-owned window, restoring any draft the last
  /// turn left behind and offering the queue for confirmation.
  Future<SubmitResult?> _readTurn(String promptString) async {
    var initial = _resumedDraft;
    _resumedDraft = '';

    if (!ScreenCoordinator.instance.isActive) {
      if (_turnInterrupted && initial.isNotEmpty) {
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
    }
    _turnInterrupted = false;

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
  Future<void> _submitQueued({bool showDock = true}) async {
    final queued = _promptReader.takeNextQueued();
    if (queued.trim().isEmpty) {
      ScreenCoordinator.instance.setQueued(const []);
      return;
    }
    _promptReader.addToHistory(queued);
    ScreenCoordinator.instance.setQueued(_promptReader.queuedMessages);
    if (showDock && !_bandPinned) {
      _writeLine(StatusBar.render(agent));
    }
    renderUserTurn(queued.trim());
    final imageExtraction = await ImageAttachment.extractFromPrompt(
      queued.trim(),
    );
    final attachments = <ImageAttachment>[
      ..._slashHandler.pendingImages,
      ..._promptReader.attachedImages,
      ...imageExtraction.images,
    ];
    _slashHandler.pendingImages.clear();
    _promptReader.attachedImages.clear();

    final expanded = await AutoCompleter.expandFileMentions(queued.trim());
    await _executeAgentTurn(expanded, images: attachments);
    await _afterTurn();
  }

  /// What happens to a queued message once the turn that was running is over.
  ///
  /// Turn ended normally → the queue is submitted as the next turn. Turn
  /// interrupted → the queue is restored as the draft instead, because Esc means
  /// stop and auto-sending a moment later is sending something that was not meant
  /// for that moment.
  Future<void> _afterTurn() async {
    if (!_promptReader.hasQueued) {
      ScreenCoordinator.instance.setQueued(const []);
      return;
    }
    if (_turnInterrupted) {
      final all = _promptReader.takeAllQueued();
      ScreenCoordinator.instance.setQueued(const []);
      if (all.isNotEmpty) {
        _resumedDraft = _resumedDraft.isNotEmpty
            ? '${all.join('\n')}\n$_resumedDraft'
            : all.join('\n');
      }
      return;
    }
    await _submitQueued();
  }

  /// Runs a single turn with the given prompt.
  Future<void> runWithPrompt(String prompt) async {
    _setupSigintHandler();
    final imageExtraction = await ImageAttachment.extractFromPrompt(prompt);
    final expandedPrompt = await AutoCompleter.expandFileMentions(prompt);
    await _executeAgentTurn(expandedPrompt, images: imageExtraction.images);
    await _sigintSub?.cancel();
  }

  /// Writes a line of transcript output, clearing the ambient row first and
  /// reclaiming it afterwards. Every write that does not end with a newline must
  /// go through [stdout.write] directly with the row suspended.
  void _writeLine(String line) {
    if (ScreenCoordinator.instance.isActive) {
      ScreenCoordinator.instance.writeTranscript('$line\n');
      return;
    }
    if (_promptReader.isDrafting) {
      _promptReader.eraseCurrentLine();
    } else if (_isExecutingTurn) {
      _ambient.clearForTranscriptWrite();
    } else {
      _ambient.hide();
    }
    if (_outSink != null) {
      _outSink('$line\n');
    } else {
      stdout.writeln(line);
    }
    if (_promptReader.isDrafting) {
      _promptReader.repaintCurrentLine();
    } else if (_isExecutingTurn) {
      _ambient.resumeAfterLineWrite();
    }
  }

  /// The one writer of the ambient row during streaming: wrap the markdown
  /// printer's output so the row is erased before a write and redrawn only when
  /// the write left the cursor at the start of a row. A partial line leaves the
  /// row hidden rather than painted over text — the point of the rule.
  void _writeStreamText(String text) {
    if (ScreenCoordinator.instance.isActive) {
      ScreenCoordinator.instance.writeTranscript(text);
      return;
    }
    final atRowStart = text.endsWith('\n');
    if (_promptReader.isDrafting) {
      _promptReader.eraseCurrentLine();
    } else if (_isExecutingTurn) {
      _ambient.clearForTranscriptWrite();
    } else {
      _ambient.hide();
    }
    if (_outSink != null) {
      _outSink(text);
    } else {
      stdout.write(text);
    }
    if (_promptReader.isDrafting) {
      if (atRowStart) _promptReader.repaintCurrentLine();
    } else if (_isExecutingTurn) {
      if (atRowStart) _ambient.resumeAfterLineWrite();
    }
  }

  /// The single interrupt path: Esc or Ctrl+C, and nothing else. It stops the
  /// turn, keeps the draft, and leaves any queued message for the human to
  /// re-send deliberately.
  void _interruptTurn(String keyName) {
    if (!_isExecutingTurn || _turnInterrupted) return;
    _turnInterrupted = true;
    agent.cancel();

    final draft = TerminalManager.instance.draft;
    final allQueued = _promptReader.takeAllQueued();
    ScreenCoordinator.instance.setQueued(const []);
    final hadDraft = draft.trim().isNotEmpty || allQueued.isNotEmpty;
    final parts = <String>[];
    for (final q in allQueued) {
      if (q.trim().isNotEmpty) {
        parts.add(q.trim());
      }
    }
    if (draft.trim().isNotEmpty) {
      parts.add(draft.trim());
      TerminalManager.instance.draft = '';
    }
    if (parts.isNotEmpty) {
      _resumedDraft = parts.join('\n');
    }
    TerminalManager.instance.clearBuffer();

    final theme = NibTheme.current;
    _writeLine(
      '  ${theme.warning.text('⚠ Turn interrupted ($keyName).')}'
      '${hadDraft ? ' ${theme.muted.text('Draft kept.')}' : ''}',
    );
    _ambient.showInterrupted(keyName: keyName, draftKept: hadDraft);
  }

  Future<void> _executeAgentTurn(
    String prompt, {
    List<ImageAttachment>? images,
  }) async {
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
    _startTurnInput();

    final currentThoughtBuffer = StringBuffer();
    final currentTextBuffer = StringBuffer();
    _activeThoughtBuffer = currentThoughtBuffer;
    _activeTextBuffer = currentTextBuffer;

    final callbacks = AgentCallbacks(
      onThoughtDelta: (thought) {
        _ambient.recordToken();
        currentThoughtBuffer.write(thought);
        if (!_thinkingExpanded) return;
        if (!_inThoughtBlock) {
          _writeStreamText('  ${theme.muted.text('➸⊚ ')}');
          _inThoughtBlock = true;
        }
        _writeStreamText(theme.muted.text(thought));
      },
      onTextDelta: (text) {
        currentTextBuffer.write(text);
        if (_inThoughtBlock) {
          _writeLine('');
          _writeLine('');
          _inThoughtBlock = false;
        }
        markdownPrinter.addDelta(text);
      },
      onToolCallStarted: (call) {
        markdownPrinter.flush();
        if (_inThoughtBlock) {
          _writeLine('');
          _writeLine('');
          _inThoughtBlock = false;
        }
        if (currentThoughtBuffer.isNotEmpty) {
          _renderModel.add(ThoughtBlock(currentThoughtBuffer.toString()));
          currentThoughtBuffer.clear();
        }
        if (currentTextBuffer.isNotEmpty) {
          _renderModel.add(AssistantTextBlock(currentTextBuffer.toString()));
          currentTextBuffer.clear();
        }
        final argsSummary = _formatToolArgsSummary(call.name, call.arguments);
        final topUsed = 10 + call.name.length;
        final topRule = max(2, 40 - topUsed);
        _writeLine(
          '  ${theme.muted.text('╭──')} ${theme.warning.text('›_')} ${theme.accent.text(call.name)} ${theme.muted.text('─' * topRule)}',
        );
        if (argsSummary.isNotEmpty) {
          for (final line in argsSummary.split('\n')) {
            _writeLine('    ${theme.secondary.text(line)}');
          }
        }
        _ambient.showTool(call.name);
      },
      onToolCallFinished: (call, result, duration) {
        final ms = duration.inMilliseconds;
        _renderModel.add(
          ToolCallBlock(
            toolName: call.name,
            arguments: call.arguments,
            result: result,
            durationMs: ms,
          ),
        );
        final preview = _formatResultPreview(call.name, result);
        for (final line in preview) {
          _writeLine('    $line');
        }
        final doneText = 'done (${ms}ms)';
        final bottomUsed = 9 + doneText.length;
        final bottomRule = max(2, 40 - bottomUsed);
        _writeLine(
          '  ${theme.muted.text('╰──')} ${theme.success.text('✔')} ${theme.muted.text(doneText)} ${theme.muted.text('─' * bottomRule)}',
        );
        _writeLine('');
        _ambient.resumeStreaming();
      },
      onToolProgress: (call, line) {
        final clean = line
            .replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '')
            .trim();
        if (clean.isNotEmpty) _ambient.showToolProgress(clean);
      },
      onError: (error) {
        markdownPrinter.flush();
        if (_inThoughtBlock) {
          _writeLine('');
          _inThoughtBlock = false;
        }
        _writeLine('');
        _writeLine('  ${theme.error.text('✖ Error:')} $error');
        _writeLine('');
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
      await agent.runTurn(prompt, images: images, callbacks: callbacks);
    } catch (e) {
      _ambient.clearForTranscriptWrite();
      markdownPrinter.flush();
      _writeLine('  ${theme.error.text('✖ Exception:')} $e');
    } finally {
      await _stopTurnInput();
      final stranded = TerminalManager.instance.draft;
      if (stranded.trim().isNotEmpty) {
        _resumedDraft = stranded;
        TerminalManager.instance.draft = '';
      }
      await inputSub?.cancel();
      _ambient.endTurn();
      markdownPrinter.flush();
      if (currentThoughtBuffer.isNotEmpty) {
        _renderModel.add(ThoughtBlock(currentThoughtBuffer.toString()));
        currentThoughtBuffer.clear();
      }
      if (currentTextBuffer.isNotEmpty) {
        _renderModel.add(AssistantTextBlock(currentTextBuffer.toString()));
        currentTextBuffer.clear();
      }
      _renderModel.add(StatusBlock('  ${theme.muted.text('─' * 38)}'));
      _isExecutingTurn = false;
      _activeThoughtBuffer = null;
      _activeTextBuffer = null;
      TerminalManager.instance.clearBuffer();
    }

    _writeLine('');
    _writeLine('  ${theme.muted.text('─' * 38)}');
    _writeLine('');
  }

  /// Prominently renders the human's message into the scrolling transcript
  /// with a 40-column corner cap header and footer, indented text, and no
  /// left vertical borders so resizing reflows naturally.
  void renderUserTurn(String text) {
    _renderModel.add(UserPromptBlock(text));
    final theme = NibTheme.current;
    _writeLine('');
    _writeLine(
      '  ${theme.muted.text('╭──')} ${theme.accent.text('✒')} ${Ansi.boldText(theme.primary.text('You'))} ${theme.muted.text('─' * 28)}',
    );
    for (final line in text.split('\n')) {
      _writeLine('    ${Ansi.boldText(line)}');
    }
    _writeLine('  ${theme.muted.text('╰──${'─' * 35}')}');
    _writeLine('');
  }

  /// Full screen redraw: clears viewport, re-establishes DECSTBM margins,
  /// re-renders all retained transcript blocks through current visibility filters,
  /// and repaints pinned footer and prompt.
  void redrawScreen() {
    _refreshBand();
    ScreenCoordinator.instance.resetAndClearScreen();

    final theme = NibTheme.current;
    final width = ScreenCoordinator.instance.terminalColumns;

    final renderedLines = _renderModel.renderAll(
      theme: theme,
      terminalWidth: width,
      thinkingExpanded: _thinkingExpanded,
      toolsExpanded: _toolsExpanded,
    );

    for (final line in renderedLines) {
      ScreenCoordinator.instance.writeTranscript('$line\n');
    }

    _inThoughtBlock = false;
    if (_isExecutingTurn) {
      final thought = _activeThoughtBuffer?.toString() ?? '';
      final text = _activeTextBuffer?.toString() ?? '';
      if (thought.trim().isNotEmpty) {
        final prefix = '  ${theme.muted.text('➸⊚ ')}';
        if (_thinkingExpanded) {
          ScreenCoordinator.instance.writeTranscript(
            '$prefix${theme.muted.text(thought.trimLeft())}',
          );
          if (text.isEmpty) {
            // Later deltas continue this same line.
            _inThoughtBlock = true;
          } else {
            ScreenCoordinator.instance.writeTranscript('\n\n');
          }
        } else {
          ScreenCoordinator.instance.writeTranscript(
            '$prefix${theme.muted.text('[thinking collapsed — Ctrl+T to expand]')}\n',
          );
        }
      }
      // Only completed lines: the markdown printer still owns the partial one.
      final cut = text.lastIndexOf('\n');
      if (cut >= 0) {
        final done = text.substring(0, cut);
        if (done.trim().isNotEmpty) {
          for (final line in MarkdownRenderer.render(done, theme).split('\n')) {
            ScreenCoordinator.instance.writeTranscript('$line\n');
          }
        }
      }
    }

    _ambient.showIdle();
    _promptReader.repaintCurrentLine();
  }

  /// Populates the render model from a loaded session transcript.
  void populateRenderModelFromSession(AgentSession session) {
    _renderModel.populateFromSession(session);
  }

  /// Word-wraps text paragraphs to fit within [width] characters.
  static List<String> wrapText(String text, int width) =>
      _wrapText(text, width);

  static List<String> _wrapText(String text, int width) {
    final result = <String>[];
    for (final paragraph in text.split('\n')) {
      if (paragraph.length <= width) {
        result.add(paragraph);
        continue;
      }
      final words = paragraph.split(' ');
      final current = StringBuffer();
      for (final word in words) {
        if (current.isEmpty) {
          if (word.length <= width) {
            current.write(word);
          } else {
            var w = word;
            while (w.length > width) {
              result.add(w.substring(0, width));
              w = w.substring(width);
            }
            current.write(w);
          }
        } else if (current.length + 1 + word.length <= width) {
          current.write(' $word');
        } else {
          result.add(current.toString());
          current.clear();
          var w = word;
          while (w.length > width) {
            result.add(w.substring(0, width));
            w = w.substring(width);
          }
          current.write(w);
        }
      }
      if (current.isNotEmpty) {
        result.add(current.toString());
      }
    }
    return result;
  }

  bool _draftWindowOpen = false;
  Completer<void> _draftReaderExited = Completer<void>();

  void _startTurnInput() {
    if (!stdin.hasTerminal || _draftWindowOpen) return;
    TerminalManager.instance.clearEndWindowSentinels();
    _draftWindowOpen = true;
    _draftReaderExited = Completer<void>();
    unawaited(_readDraftWindow());
  }

  Future<void> _stopTurnInput() async {
    if (!_draftWindowOpen) return;
    _draftWindowOpen = false;
    TerminalManager.instance.endWindow();
    try {
      await _draftReaderExited.future.timeout(
        const Duration(milliseconds: 200),
      );
    } catch (_) {}
  }

  Future<void> _readDraftWindow() async {
    final theme = NibTheme.current;
    final promptString = ScreenCoordinator.instance.isActive
        ? '${theme.secondary.text('⌛︎')} ${theme.accent.text('›')} '
        : '${theme.secondary.text('⌛︎')} ${theme.accent.text('›')} ';
    // Inside this window Esc / Ctrl+C is the interrupt, and nothing else.
    _promptReader.onInterrupt = (keyName) => _interruptTurn(keyName);
    try {
      while (_draftWindowOpen && _isExecutingTurn && !_turnInterrupted) {
        final hasDraft = TerminalManager.instance.draft.isNotEmpty;
        final result = await _promptReader.readSubmit(
          prompt: promptString,
          initial: TerminalManager.instance.draft,
          window: true,
          silent: !hasDraft,
          onStartTyping: () => _ambient.yieldRowToHuman(),
          hasQueued: _promptReader.hasQueued,
        );
        if (result == null || result.kind == SubmitKind.windowEnded) break;
        // Alt+Enter or Enter queues the draft mid-turn.
        if (result.kind == SubmitKind.queue ||
            result.kind == SubmitKind.submit) {
          if (result.text.trim().isNotEmpty) {
            _promptReader.enqueue(result.text);
            if (ScreenCoordinator.instance.isActive) {
              ScreenCoordinator.instance.setQueued(
                _promptReader.queuedMessages,
              );
            } else {
              _writeLine(
                '  ${theme.info.text('⏎ Queued:')} ${theme.muted.text(result.text.trim())}',
              );
            }
            _ambient.showComposition(queued: _promptReader.queued);
            _ambient.resumeRowFromHuman();
          }
          continue;
        }
        break;
      }
    } finally {
      _draftWindowOpen = false;
      _promptReader.onInterrupt = null;
      if (!_draftReaderExited.isCompleted) _draftReaderExited.complete();
    }
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

    final width = _cardWidth();
    final innerWidth = max(20, width - 8);

    // For edit_file, print the diff nicely with preserved color
    if (toolName == 'edit_file') {
      const maxDiffLines = 14;
      final shown = lines.take(maxDiffLines).toList();
      final res = <String>[];
      for (final line in shown) {
        final wrapped = _wrapText(line, innerWidth);
        res.addAll(wrapped);
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
      final wrapped = _wrapText(line, innerWidth);
      for (final w in wrapped) {
        res.add(NibTheme.current.muted.text(w));
      }
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

  int _cardWidth() {
    var cols = 80;
    try {
      if (stdout.hasTerminal) cols = stdout.terminalColumns;
    } catch (_) {}
    if (cols > 100) cols = 100;
    return cols;
  }
}
