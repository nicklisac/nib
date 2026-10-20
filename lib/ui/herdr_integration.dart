import 'dart:io';

/// Manages agent lifecycle reporting to Herdr (https://herdr.dev).
///
/// When running inside a Herdr pane (`HERDR_ENV == '1'`), Nib automatically
/// reports its lifecycle state (`idle`, `working`, `blocked`) and resume
/// command so that Herdr can track Nib alongside other agents in the
/// sidebar, workspace status indicators, and automation commands.
class HerdrIntegration {
  static HerdrIntegration? _testInstance;
  static final HerdrIntegration _singleton = HerdrIntegration._();
  static HerdrIntegration get instance => _testInstance ?? _singleton;
  static set testInstance(HerdrIntegration? inst) => _testInstance = inst;

  HerdrIntegration._() : _customEnv = null, _customRunner = null;

  /// Visible constructor for testing.
  HerdrIntegration.forTesting({
    Map<String, String>? environment,
    Future<void> Function(String executable, List<String> arguments)? runner,
  }) : _customEnv = environment,
       _customRunner = runner;

  final Map<String, String>? _customEnv;
  final Future<void> Function(String executable, List<String> arguments)?
  _customRunner;

  Map<String, String> get _env => _customEnv ?? Platform.environment;

  bool get isHerdr => _env['HERDR_ENV'] == '1';
  String? get paneId => _env['HERDR_PANE_ID'];
  String get herdrBin => _env['HERDR_BIN_PATH'] ?? 'herdr';

  int _seq = 0;
  String? _lastState;

  int _nextSeq() {
    return DateTime.now().millisecondsSinceEpoch + (++_seq);
  }

  /// Reports an agent state change to Herdr.
  Future<void> reportState(
    String state, {
    String? message,
    bool withResume = false,
  }) async {
    if (!isHerdr) return;
    final pane = paneId;
    if (pane == null || pane.isEmpty) return;
    if (_lastState == state && message == null && !withResume) return;
    _lastState = state;

    final seq = _nextSeq();
    final args = <String>[
      'pane',
      'report-agent',
      pane,
      '--source',
      'nib',
      '--agent',
      'nib',
      '--state',
      state,
      '--seq',
      seq.toString(),
    ];

    if (message != null && message.isNotEmpty) {
      args.addAll(['--message', message]);
    }

    if (withResume) {
      args.addAll(['--', 'nib', '--resume']);
    }

    if (_customRunner != null) {
      await _customRunner(herdrBin, args);
      return;
    }

    // Fire and forget so TUI rendering is never blocked by IPC
    Process.run(herdrBin, args).catchError((_) => ProcessResult(0, 0, '', ''));
  }

  void reportIdle({bool withResume = false}) {
    reportState('idle', withResume: withResume);
  }

  void reportWorking() {
    reportState('working');
  }

  void reportBlocked([String? message]) {
    reportState('blocked', message: message ?? 'Approval required');
  }

  void release() {
    if (!isHerdr) return;
    final pane = paneId;
    if (pane == null || pane.isEmpty) return;

    final seq = _nextSeq();
    final args = <String>[
      'pane',
      'release-agent',
      pane,
      '--source',
      'nib',
      '--agent',
      'nib',
      '--seq',
      seq.toString(),
    ];

    if (_customRunner != null) {
      _customRunner(herdrBin, args);
      return;
    }

    try {
      Process.runSync(herdrBin, args);
    } catch (_) {}
  }
}
