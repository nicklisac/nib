import 'dart:async';
import 'dart:io';
import '../agent/agent.dart';
import '../agent/context_meter.dart';
import '../agent/undo_manager.dart';
import 'screen_coordinator.dart';
import 'terminal_manager.dart';
import 'theme.dart';

/// Field priorities for the ambient line, highest first. When the row does not
/// fit, fields are dropped whole from the tail — never truncated mid-field,
/// which renders as `Compiling nib v0.0…` and reads as a bug.
///
/// Everything here is present tense. Static session facts — provider, model,
/// workspace — live in the pinned top header instead, which is why none of them
/// can be a casualty of the drop loop: on a narrow window the telemetry is the
/// point of this row, and it used to lose to a model name.
enum AmbientField {
  stateGlyph,
  runningTool,
  elapsed,
  tokenRate,
  queue,
  gauge,
  thinkingLevel,
  tokensSpent,
  toolProgress,

  /// How many edits can be rolled back. Only worth a field while it is nonzero.
  undoCount,

  /// Which key stopped the turn. Drops first: at 40 columns the facts that matter
  /// are *interrupted* and *draft kept*, and the key name must not push the
  /// doctrine-relevant one off the row.
  interruptKey,
}

/// Which of the two owners holds the screen right now, and what it is doing.
enum AmbientState { idle, streaming, tool, interrupted }

/// The one row at the bottom of the screen that carries present-tense state
/// while the human is not typing. Redrawn in place; never scrolled into history.
///
/// Distinct from the dock, which names provider/model/workspace, is printed once
/// with the prompt, and is *supposed* to scroll away with the exchange it labels.
///
/// The spinner is subsumed rather than stacked: this is the same single in-place
/// row the spinner already owned, with the gauge appended. One writer, one row.
class AmbientLine {
  /// The two fields that are never dropped: the glyph answers "can I type", the
  /// gauge is the reason the row exists.
  static const Set<AmbientField> _neverDrops = {
    AmbientField.stateGlyph,
    AmbientField.gauge,
  };

  /// Left gutter the row is drawn with, matching the transcript's indent. Counted
  /// against the width budget: a row that fits only after the indent is added is
  /// a row that wraps.
  static const int _indent = 2;

  /// Compact arrow flight sequence into the inner ring target:
  /// Launch up, glide across, strike, and hold embedded for impact.
  static const List<String> _frames = [
    '➹   ⊚',
    ' ➸  ⊚',
    '  ➸ ⊚',
    '   ➸⊚',
    '   ➸⊚',
    '   ➸⊚',
  ];

  final Agent agent;
  final ContextMeter meter;

  /// Where the row is written. Injectable so the write *protocol* — suspend before
  /// an inline write, redraw only at a row start — is testable without a TTY.
  final void Function(String text) _out;

  /// True when [_out] is the real terminal rather than a test sink.
  final bool _writesToTerminal;

  AmbientState _state = AmbientState.idle;
  String _message = '';
  String _runningTool = '';
  String _toolProgress = '';
  int _queuedCount = 0;
  bool _draftKept = false;
  String _interruptKey = '';

  Timer? _timer;
  final Stopwatch _stopwatch = Stopwatch();
  int _frameIndex = 0;
  int _tokenCount = 0;
  bool _visible = false;

  /// Whether the cursor currently sits at the start of a row. The line may only
  /// be drawn there: writing it while the stream is mid-line would overwrite
  /// transcript text, i.e. write a row Nib does not own (feel doctrine rule 1).
  bool _atRowStart = true;

  /// Whether the row has been handed to the human's draft line.
  ///
  /// While a tool runs, the draft prompt opens on the row this line was drawing —
  /// one row, one writer (#22). Without this the animation timer keeps emitting
  /// `\r\x1B[2K` onto the row you are typing on, wiping each keystroke ~100ms after
  /// you make it, which reads as having no text box at all. It re-arms at the next
  /// boundary: a new iteration, or the next tool.
  bool _yielded = false;

  AmbientLine({
    required this.agent,
    required this.meter,
    void Function(String text)? out,
  }) : _out = out ?? stdout.write,
       _writesToTerminal = out == null;

  bool get isVisible => _visible;

  /// Whether the row may be drawn right now: it must be showing, and the cursor
  /// must be at the start of a row. Drawing while the stream is mid-line would
  /// paint over transcript text — writing a row Nib does not own (feel doctrine
  /// rule 1) — so a partial line leaves the row hidden rather than overwritten.
  bool get mayDraw => _visible && !_yielded && _atRowStart;

  AmbientState get state => _state;
  String get runningTool => _runningTool;

  /// Starts (or restarts) the row for a new turn.
  void startTurn({String message = 'thinking'}) {
    _state = AmbientState.streaming;
    _message = message;
    _runningTool = '';
    _toolProgress = '';
    _draftKept = false;
    _interruptKey = '';
    _tokenCount = 0;
    _stopwatch
      ..reset()
      ..start();
    _show();
  }

  /// Switches to the tool-running frame and names the tool that owns the wait.
  void showTool(String label) {
    _state = AmbientState.tool;
    _runningTool = label;
    _toolProgress = '';
    _stopwatch
      ..reset()
      ..start();
    _show();
  }

  /// The live output line of a long-running tool. Lowest priority field: it is
  /// the first thing dropped when the row runs out of width.
  void showToolProgress(String line) {
    _toolProgress = line;
    _render();
  }

  /// Back to the streaming frame after a tool finishes.
  void resumeStreaming() {
    _state = AmbientState.streaming;
    _runningTool = '';
    _toolProgress = '';
    _message = 'thinking';
    _stopwatch
      ..reset()
      ..start();
    _show();
  }

  /// The turn ended and control returned to the human. The row goes away rather
  /// than staying to say "idle": at rest the prompt is the readout.
  void endTurn() {
    _state = AmbientState.idle;
    _runningTool = '';
    _toolProgress = '';
    _stopwatch.stop();
    if (ScreenCoordinator.instance.isActive) {
      _show();
    } else {
      hide();
    }
  }

  /// Sets the row to idle state and shows it if supported.
  void showIdle() {
    _state = AmbientState.idle;
    _show();
  }

  /// The turn was interrupted. Stays up briefly with the one fact that matters:
  /// the draft survived (feel doctrine rule 2).
  void showInterrupted({required String keyName, required bool draftKept}) {
    _state = AmbientState.interrupted;
    _interruptKey = keyName;
    _draftKept = draftKept;
    _runningTool = '';
    _toolProgress = '';
    _stopwatch.stop();
    _show();
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), () {
      if (_state == AmbientState.interrupted) {
        _state = AmbientState.idle;
        if (ScreenCoordinator.instance.isActive) {
          _show();
        } else {
          hide();
        }
      }
    });
  }

  void recordToken() {
    _tokenCount++;
  }

  /// Mirrors what the human has composed, so the row can show a queue indicator.
  /// The draft text itself is never echoed here: it is already on the prompt row,
  /// and duplicating it would cost a second row (#22).
  void showComposition({required String queued}) {
    _queuedCount = queued.isEmpty
        ? 0
        : queued.split('\n').where((l) => l.trim().isNotEmpty).length;
    _render();
  }

  /// Call before a write that does not end with a newline, so the row is never
  /// painted over.
  void suspendForInlineWrite() => clearForTranscriptWrite();

  /// Erases the row ahead of a transcript write, but keeps the row alive: the turn
  /// is still running, so the next legal moment brings it back. [hide] is for when
  /// the turn is over; using it mid-turn would leave the row missing for the rest
  /// of the iteration.
  ///
  /// Clears *only when the ambient row is what is displayed there*. Once the cursor
  /// is mid-line the row belongs to the transcript, and erasing it deletes the text
  /// already written — streaming a token after a token would delete every token
  /// before it and leave the whole line walking in from column 0. That is feel
  /// doctrine rule 1, the rule this class exists to honour.
  void clearForTranscriptWrite() {
    _clearOwnRowIfDisplayed();
    _atRowStart = false;
  }

  void _clearOwnRowIfDisplayed() {
    if (ScreenCoordinator.instance.isActive) {
      ScreenCoordinator.instance.renderStatus('');
      return;
    }
    if (_visible && _atRowStart) _clearRow();
  }

  /// Marks the cursor as sitting at the start of a fresh row, where drawing is
  /// legal again, and repaints.
  void resumeAfterLineWrite() {
    _atRowStart = true;
    _render();
  }

  /// Hands the row to the human's draft line and stops touching the screen.
  ///
  /// The row is cleared once here because at this moment it holds only this line's
  /// own text; from now on the draft owns it, and any later redraw would land on
  /// top of what the human is typing.
  void yieldRowToHuman() {
    if (ScreenCoordinator.instance.isActive) return;
    _clearRow();
    _yielded = true;
    _visible = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Called when the human finishes drafting (e.g. message queued) and the tool
  /// is still running. The ambient line reclaims row ownership and resumes animating.
  void resumeRowFromHuman() {
    _yielded = false;
    _visible = true;
    _atRowStart = true;
    _render();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void hide() {
    // Same ownership rule: mid-line there is no row of ours to remove, and
    // clearing would take transcript text with it.
    _clearOwnRowIfDisplayed();
    _visible = false;
    _timer?.cancel();
    _timer = null;
  }

  void _show() {
    // A boundary: turn start, tool start, or a tool finishing. The cursor is on a
    // fresh row, so the line may own it again unless the human is drafting.
    if (!ScreenCoordinator.instance.isActive &&
        (TerminalManager.instance.isDrafting ||
            TerminalManager.instance.draft.isNotEmpty)) {
      _atRowStart = true;
      _yielded = true;
      _visible = false;
      return;
    }
    _atRowStart = true;
    _yielded = false;
    _visible = true;
    _render();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _tick() {
    _frameIndex = (_frameIndex + 1) % _frames.length;
    _render();
  }

  void _clearRow() {
    if (_canWrite) _out('\r\x1B[2K');
  }

  /// A real terminal only, unless a test sink was supplied.
  bool get _canWrite => _writesToTerminal ? stdout.hasTerminal : true;

  void _render() {
    if (!_canWrite) return;
    if (ScreenCoordinator.instance.isActive) {
      ScreenCoordinator.instance.renderStatus(render(width: _terminalCols));
      return;
    }
    if (!mayDraw) return;
    _out('\r\x1B[2K${render(width: _terminalCols)}');
  }

  /// Directly re-renders the current status line (e.g. after terminal resize).
  void renderDirect() => _render();

  int get _terminalCols {
    try {
      if (stdout.hasTerminal) return stdout.terminalColumns;
    } catch (_) {}
    return 80;
  }

  /// The row's content, computed without touching the terminal. Split out so the
  /// width behaviour is testable rather than eyeballed.
  String render({int width = 80}) {
    final theme = NibTheme.current;
    final fields = <AmbientField, String>{};

    final streaming =
        _state == AmbientState.streaming || _state == AmbientState.tool;
    final glyph = switch (_state) {
      AmbientState.streaming => theme.warning.text(_frames[_frameIndex]),
      AmbientState.tool => theme.warning.text(
        _frameIndex % 2 == 0 ? '›_' : '› ',
      ),
      AmbientState.interrupted => theme.error.text('✖'),
      AmbientState.idle => theme.muted.text('⏸'),
    };
    fields[AmbientField.stateGlyph] = glyph;

    if (_state == AmbientState.streaming) {
      fields[AmbientField.runningTool] = theme.secondary.text(_message);
    } else if (_state == AmbientState.tool) {
      fields[AmbientField.runningTool] = theme.accent.text(_runningTool);
    } else if (_state == AmbientState.interrupted) {
      // Short on purpose. Naming the key is detail, and at 40 columns the detail
      // that matters is *interrupted* plus *draft kept*; the key name gets its own
      // droppable field rather than inflating the state word.
      fields[AmbientField.runningTool] = theme.error.text('interrupted');
      if (_interruptKey.isNotEmpty) {
        fields[AmbientField.interruptKey] = theme.error.text(_interruptKey);
      }
    } else {
      fields[AmbientField.runningTool] = theme.muted.text('idle');
    }

    if (streaming && _stopwatch.isRunning) {
      fields[AmbientField.elapsed] = theme.muted.text(
        _formatDuration(_stopwatch.elapsed),
      );
    }

    if (_state == AmbientState.streaming && _tokenCount > 2) {
      final seconds = _stopwatch.elapsedMilliseconds / 1000.0;
      if (seconds > 0.1) {
        fields[AmbientField.tokenRate] = theme.accent.text(
          '${(_tokenCount / seconds).toStringAsFixed(1)} tok/s',
        );
      }
    }

    final hasDraft = TerminalManager.instance.draft.trim().isNotEmpty;
    if (_queuedCount > 0) {
      fields[AmbientField.queue] = theme.info.text('⏎ $_queuedCount queued');
    } else if (_draftKept || hasDraft) {
      fields[AmbientField.queue] = theme.warning.text('draft kept');
    }

    final gaugeText = meter.displayFor(agent.session);
    final hot = meter.fractionFor(agent.session) > 0.9;
    fields[AmbientField.gauge] = hot
        ? theme.warning.text(gaugeText)
        : theme.secondary.text(gaugeText);

    final thinkLabel = agent.thinkingLevel.label;
    fields[AmbientField.thinkingLevel] = agent.thinkingLevel.isOff
        ? theme.muted.text('➸⊚ off')
        : theme.secondary.text('➸⊚ $thinkLabel');

    final undoCount = UndoManager.instance.count;
    if (undoCount > 0) {
      fields[AmbientField.undoCount] = theme.warning.text('⤺ $undoCount');
    }

    final spent =
        agent.session.totalPromptTokens + agent.session.totalCompletionTokens;
    if (spent > 0) {
      fields[AmbientField.tokensSpent] = theme.muted.text(
        '${_formatTokens(spent)} tok',
      );
    }

    if (_toolProgress.isNotEmpty) {
      fields[AmbientField.toolProgress] = theme.muted.text(_toolProgress);
    }

    // Drop from the tail until the row fits. The gauge and the state glyph stay
    // whatever the cost, so the row can degrade to `⚙ 23%` but never loses the
    // two things a human acts on.
    final keep = AmbientField.values.toList();
    var assembled = _join(keep, fields);
    while (_indent + _plainLength(assembled) > width) {
      final dropAt = keep.lastIndexWhere((f) => !_neverDrops.contains(f));
      if (dropAt < 0) break;
      keep.removeAt(dropAt);
      assembled = _join(keep, fields);
    }

    return '${' ' * _indent}$assembled';
  }

  String _join(List<AmbientField> keep, Map<AmbientField, String> fields) =>
      keep.map((f) => fields[f]).whereType<String>().join(_joiner);

  String get _joiner => NibTheme.current.muted.text(' · ');

  static int _plainLength(String styled) =>
      styled.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '').length;

  static String _formatTokens(int tokens) =>
      tokens > 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : '$tokens';

  static String _formatDuration(Duration d) => d.inSeconds < 1
      ? '${d.inMilliseconds}ms'
      : '${(d.inMilliseconds / 1000.0).toStringAsFixed(1)}s';
}
