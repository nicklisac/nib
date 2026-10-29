import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Injectable process launcher (tests hand in a fake; production uses
/// [Process.start]).
typedef ProcessStarter =
    Future<Process> Function(String exec, List<String> args);

/// Per-project check configuration, read from the workspace `.nib/config.json`
/// `check` block (#54). The command is the human's; nib never reinterprets it.
class CheckSettings {
  final String command;
  final int timeoutMs;
  final int graceMs;

  /// `true` (`report: "always"`, default) delivers clean verdicts to the
  /// model too; `false` (`report: "issues"`) delivers only failures and
  /// not-runs. Silence is never allowed to mean "clean" (#54 contract).
  final bool reportAlways;

  const CheckSettings({
    required this.command,
    this.timeoutMs = 30000,
    this.graceMs = 1000,
    this.reportAlways = true,
  });
}

enum CheckKind { clean, failed, notRun }

/// One completed check run. [transcriptText] is byte-stable for a given
/// outcome: no elapsed times, ids, or timestamps, because the tool-loop
/// runaway guard hashes results into its iteration signature
/// (`agent.dart`), and per-run timing jitter there would permanently disable
/// stuck detection on mutating loops (#54).
class CheckVerdict {
  final CheckKind kind;
  final String transcriptText;

  /// Mutation sequence value this verdict describes the state of.
  final int seq;

  /// Wall-clock duration, UI-only, never in [transcriptText].
  final int durationMs;

  const CheckVerdict({
    required this.kind,
    required this.transcriptText,
    required this.seq,
    this.durationMs = 0,
  });
}

/// Owns the post-bundle project check for one session (#54).
///
/// Lifecycle rules, all load-bearing and tested:
/// - One in-flight check per project. A new start kills the running process
///   tree and the killed run never delivers anything.
/// - Only runs that complete produce verdicts. A completed verdict may go
///   stale; stale delivery is stamped with how many changed paths it is behind.
/// - The grace window adapts: after 3 consecutive completions slower than
///   `graceMs`, inline waiting is skipped until one lands inside the grace.
class CheckController {
  final String workspace;
  CheckSettings? settings;
  bool enabled;
  final ProcessStarter _start;

  CheckController({
    required this.workspace,
    required this.settings,
    this.enabled = false,
    ProcessStarter? processStarter,
  }) : _start =
           processStarter ??
           ((exec, args) =>
               Process.start(exec, args, workingDirectory: workspace));

  /// Active means the flag is on AND the human configured a command. An
  /// enabled experiment with no command is inert and says so once at startup
  /// (never auto-detects a command).
  bool get isActive => enabled && settings != null;

  int _mutationSeq = 0;
  int get mutationSeq => _mutationSeq;

  CheckVerdict? _completed;
  CheckVerdict? get lastCompleted => _completed;

  /// Paths changed since a given sequence value, for stale-verdict stamping.
  final List<(int, String)> _changes = [];

  /// Distinct paths that changed after [seq]. Used to stamp stale verdicts.
  Set<String> changedPathsSince(int seq) => {
    for (final (s, p) in _changes)
      if (s > seq) p,
  };

  /// Notice text with stale stamp when the world moved on (#54).
  String noticeFor(CheckVerdict v) {
    final changed = changedPathsSince(v.seq);
    if (changed.isEmpty) return v.transcriptText;
    final n = changed.length;
    return '${v.transcriptText}\n[stale: as of the state after that check; '
        '$n file${n == 1 ? '' : 's'} changed since]';
  }

  // In-flight bookkeeping.
  Process? _proc;
  Timer? _escalate;
  Completer<CheckVerdict?>? _inFlight;
  final List<Future<CheckVerdict?>> _pendingDeliveries = [];
  final List<String> _notices = [];

  List<String> takeNotices() {
    final out = List<String>.from(_notices);
    _notices.clear();
    return out;
  }

  List<Future<CheckVerdict?>> takePending() {
    final out = List<Future<CheckVerdict?>>.from(_pendingDeliveries);
    _pendingDeliveries.clear();
    return out;
  }

  Future<void> drainPending({required Duration bound}) async {
    final pending = takePending();
    if (pending.isEmpty) return;
    await Future.wait(pending).then((_) {}).timeout(bound, onTimeout: () {});
  }

  /// UI-facing state string for the ambient line; nothing model-visible
  /// carries timing (#54).
  String lastUiState = 'idle';

  /// Register a check whose grace window expired: when it completes, its
  /// (stale-stamped) notice queues for delivery at the next iteration
  /// boundary, and the turn-end drain waits on the same future (#54).
  void attachLateDelivery(Future<CheckVerdict?> future) {
    lastUiState = 'running';
    final tracked = future.then((verdict) {
      lastUiState = switch (verdict?.kind) {
        CheckKind.clean => 'clean',
        CheckKind.failed => 'failed',
        CheckKind.notRun => 'not run',
        null => 'superseded',
      };
      if (verdict != null && deliversTo(verdict)) {
        _notices.add(noticeFor(verdict));
      }
      return verdict;
    });
    _pendingDeliveries.add(tracked);
  }

  Future<CheckVerdict?>? get inFlight => _inFlight?.future;

  /// Adaptive grace: skip inline waiting while the last 3 completions all
  /// overran. One in-grace completion re-arms it (#54).
  final List<int> _recentDurations = [];
  bool get graceWorthwhile {
    final g = settings?.graceMs ?? 1000;
    if (_recentDurations.length < 3) return true;
    return _recentDurations.take(3).any((d) => d <= g);
  }

  bool _externalRunSuppressesNext = false;

  /// True while the agent is executing a bundle that has already mutated
  /// files. `check_status` uses this to refuse cache answers: a verdict from
  /// before edits the model can see would be a confident wrong answer (#54).
  bool bundleHasMutations = false;

  /// Called by the bash tool before it starts a command (#54): a concurrent
  /// build would collide on compiler locks and the model would read the
  /// collision as a code failure. If the command *is* the configured check,
  /// its result stands in for the verdict and the next scheduled run is
  /// skipped.
  void beforeBashRun(String command) {
    if (!enabled) return;
    final s = settings;
    if (s != null) {
      if (command.trim() == s.command.trim()) {
        _externalRunSuppressesNext = true;
      }
      cancelInFlight();
      return;
    }
    // Enabled but unconfigured: observe only (flag on, so zero cost when
    // off). Offer the human a one-time suggestion at idle; never guess a
    // verdict from it (#54).
    if (suggestionsAllowed && _plausibleCheck.hasMatch(command)) {
      _suggestion = command.trim();
    }
  }

  static final RegExp _plausibleCheck = RegExp(
    r'^\s*(?:npm\s+(?:run\s+|exec\s+)?(?:check|lint|build|test)\b|pnpm\s+(?:run\s+)?(?:check|lint|build|test)\b|yarn\s+(?:check|lint|build|test)\b|npx\s+tsc\b|tsc\s+--noEmit\b|cargo\s+(?:check|test|build)\b|go\s+(?:vet|build)\b|dart\s+analyze\b|pytest\b)',
  );

  String? _suggestion;
  String? get pendingSuggestion => _suggestion;
  void clearSuggestion() => _suggestion = null;
  bool suggestionsAllowed = true;

  /// Persist an accepted or declined suggestion (#54): accepted writes the
  /// command to the workspace sidecar, declined writes `suggest: false` so
  /// the offer never recurs.
  void resolveSuggestion(String command, bool accepted) {
    _suggestion = null;
    if (accepted) {
      settings = CheckSettings(command: command);
      suggestionsAllowed = false;
    } else {
      suggestionsAllowed = false;
    }
  }

  /// Record workspace mutations from a tool call. Edits landing while a check
  /// runs kill it and it is restarted on the newer state at bundle close; the
  /// killed run delivers nothing.
  void recordMutation(String path) {
    _mutationSeq++;
    _changes.add((_mutationSeq, path));
    if (_changes.length > 200) _changes.removeAt(0);
    cancelInFlight();
  }

  /// Cancel the running check (kill tree). A cancelled run never delivers.
  void cancelInFlight() {
    final completer = _inFlight;
    _inFlight = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
    final p = _proc;
    _proc = null;
    if (p != null) _killTree(p);
  }

  /// Cancel everything, including queued deliveries (turn cancellation).
  void cancelAll() {
    cancelInFlight();
    _pendingDeliveries.clear();
    _notices.clear();
  }

  /// Start a check for the current state. Returns a future that resolves to
  /// the verdict on completion, or `null` if the run was killed or the
  /// scheduled start was absorbed by an equivalent external bash run.
  Future<CheckVerdict?> start() {
    final s = settings;
    if (!isActive || s == null) return Future.value();
    if (_externalRunSuppressesNext) {
      _externalRunSuppressesNext = false;
      return Future.value();
    }
    cancelInFlight();
    final completer = Completer<CheckVerdict?>();
    _inFlight = completer;
    final seqAtStart = _mutationSeq;
    final stopwatch = Stopwatch()..start();

    () async {
      CheckVerdict verdict;
      try {
        final process = await _start(
          Platform.isWindows ? 'cmd.exe' : 'bash',
          Platform.isWindows ? ['/c', s.command] : ['-c', s.command],
        );
        // If this run was superseded while the OS was still spawning it,
        // kill immediately and stay silent.
        if (!identical(completer, _inFlight)) {
          _killTree(process);
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        _proc = process;

        final out = StringBuffer();
        final err = StringBuffer();
        final outSub = process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(out.write);
        final errSub = process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(err.write);

        bool timedOut = false;
        final timer = Timer(Duration(milliseconds: s.timeoutMs), () {
          timedOut = true;
          _killTree(process);
        });

        int code;
        try {
          code = await process.exitCode;
        } finally {
          timer.cancel();
          await outSub.cancel();
          await errSub.cancel();
          _escalate?.cancel();
        }
        if (!identical(completer, _inFlight)) {
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        _proc = null;
        stopwatch.stop();
        final ms = stopwatch.elapsedMilliseconds;
        _recentDurations.insert(0, ms);
        if (_recentDurations.length > 3) _recentDurations.removeLast();

        if (timedOut) {
          verdict = CheckVerdict(
            kind: CheckKind.notRun,
            transcriptText:
                '[check not run: timed out after ${s.timeoutMs} ms]',
            seq: seqAtStart,
            durationMs: ms,
          );
        } else if (code == 127) {
          // The command runs through `bash -c`, so a missing binary surfaces
          // as exit 127 rather than a ProcessException. Report it as the
          // not-run reason the contract names, not as a code failure.
          verdict = CheckVerdict(
            kind: CheckKind.notRun,
            transcriptText: '[check not run: command not found]',
            seq: seqAtStart,
            durationMs: ms,
          );
        } else if (code == 0) {
          verdict = CheckVerdict(
            kind: CheckKind.clean,
            transcriptText: '[check clean: ${s.command}]',
            seq: seqAtStart,
            durationMs: ms,
          );
        } else {
          final raw = '${err.toString().trim()}\n${out.toString().trim()}'
              .trim();
          final lines = raw
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .take(15)
              .join('\n');
          verdict = CheckVerdict(
            kind: CheckKind.failed,
            transcriptText:
                '[check failed: ${s.command} (exit code $code)]\n$lines\n'
                'If you changed related files in the same change, some '
                'failures may be expected.',
            seq: seqAtStart,
            durationMs: ms,
          );
        }
      } on ProcessException {
        stopwatch.stop();
        verdict = CheckVerdict(
          kind: CheckKind.notRun,
          transcriptText: '[check not run: command not found]',
          seq: seqAtStart,
          durationMs: stopwatch.elapsedMilliseconds,
        );
      } catch (e) {
        stopwatch.stop();
        verdict = CheckVerdict(
          kind: CheckKind.notRun,
          transcriptText: '[check not run: check runner failed: $e]',
          seq: seqAtStart,
          durationMs: stopwatch.elapsedMilliseconds,
        );
      }

      if (!identical(completer, _inFlight)) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      _inFlight = null;
      _completed = verdict;
      if (!completer.isCompleted) completer.complete(verdict);
    }();

    return completer.future;
  }

  /// Whether a verdict of this kind should reach the model transcript under
  /// the current report mode. Clean verdicts with `report: "issues"` are
  /// cached for `check_status` but not pushed (#54).
  bool deliversTo(CheckVerdict v) {
    final s = settings;
    if (s == null) return false;
    if (v.kind == CheckKind.clean && !s.reportAlways) return false;
    return true;
  }

  /// Kill the whole process tree: npm/npx/glab wrappers orphan real compiler
  /// children otherwise. POSIX escalates SIGTERM -> SIGKILL after 500 ms and
  /// reaps direct children with `pkill -P` first (the pattern bash_tool uses
  /// and Map 3 blesses); Windows uses taskkill /T.
  void _killTree(Process p) {
    try {
      if (Platform.isWindows) {
        Process.start('taskkill', [
          '/F',
          '/T',
          '/PID',
          '${p.pid}',
        ], mode: ProcessStartMode.detached);
      } else {
        unawaited(
          Process.run('pkill', [
            '-P',
            '${p.pid}',
          ], runInShell: false).then((_) {}).catchError((Object _) {}),
        );
        p.kill(ProcessSignal.sigterm);
        _escalate?.cancel();
        _escalate = Timer(const Duration(milliseconds: 500), () {
          try {
            p.kill(ProcessSignal.sigkill);
          } catch (_) {}
        });
      }
    } catch (_) {}
  }

  /// System-prompt section injected only when the experiment is live. Kept
  /// under ten lines; disabled means zero prompt cost, matching the
  /// experiments convention (#54).
  String? get promptSection {
    if (!isActive) return null;
    return '''

## Post-bundle project check (experiment)

A background check runs after every tool call bundle that edits files, using the project's configured check command.
Its verdict appears inline on the edit result when the check is fast, or later as a "[check ...]" notice when it is not; "[check running async]" means a verdict is coming.
Verdicts: "[check clean: ...]", "[check failed: ... (exit code N)]" followed by the command's own output, or "[check not run: reason]".
A failure notice may reflect an intermediate state of a multi-bundle change; use judgement before "fixing" errors your own next edit would have resolved.
Do not run the check command through bash yourself; call `check_status` when you need the verdict now.
The check only proves what its configured command models. A clean verdict is not a correctness claim.''';
  }
}
