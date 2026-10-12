/// Records a single generation burst between the arrival of the first output
/// token and the end of the provider stream.
class GenerationBurst {
  final int tokens;
  final double durationSeconds;

  const GenerationBurst({required this.tokens, required this.durationSeconds});

  /// Tokens per second generated during this burst.
  double get rate => durationSeconds > 0 ? tokens / durationSeconds : 0.0;
}

/// Tracks LLM generation speed (tok/s) across generation bursts.
///
/// Follows strict lifecycle requirements:
/// 1. Only measures output generation (prompt ingestion/prefill time is bypassed
///    by starting the stopwatch only once the first token delta arrives).
/// 2. Isolated from tool wait times: stopwatch stops upon DoneEvent and stays
///    stopped while tools execute.
/// 3. Reconciles live character-based token estimates (chars/3.8) with the
///    provider's ground-truth completion_tokens upon DoneEvent.
/// 4. Maintains a FIFO buffer of the last 10 generation bursts to report a
///    clean, non-jittery rolling average.
class GenerationVelocityTracker {
  static const int maxBurstHistory = 10;

  final List<GenerationBurst> _recentBursts = [];
  final Stopwatch _burstStopwatch = Stopwatch();
  double _currentBurstEstimatedTokens = 0.0;
  bool _hasReceivedFirstToken = false;

  /// True while an LLM output stream is actively emitting tokens.
  bool get isBurstActive => _burstStopwatch.isRunning;

  /// Starts a new generation burst when a provider request opens.
  /// Note: The stopwatch does NOT start here — it waits until the first token
  /// arrives so TTFT (prompt ingestion/prefill) does not drag down generation rate.
  void startBurst() {
    _burstStopwatch.reset();
    _currentBurstEstimatedTokens = 0.0;
    _hasReceivedFirstToken = false;
  }

  /// Records an emitted output delta (text, thought, or tool arguments chunk).
  /// Starts the generation clock on the very first token.
  void recordDelta(String delta) {
    if (delta.isEmpty) return;
    if (!_hasReceivedFirstToken) {
      _hasReceivedFirstToken = true;
      _burstStopwatch.start();
    }
    // Average 3.8 characters per token across common modern LLM tokenizers
    _currentBurstEstimatedTokens += delta.length / 3.8;
  }

  /// Concludes the active generation burst (e.g. upon DoneEvent).
  /// Reconciles with the provider's exact [actualTokens] (completion_tokens).
  void endBurst({int? actualTokens, double? durationSeconds}) {
    if (_burstStopwatch.isRunning) {
      _burstStopwatch.stop();
    }
    final elapsedSec =
        durationSeconds ?? (_burstStopwatch.elapsedMilliseconds / 1000.0);
    final tokens = actualTokens ?? _currentBurstEstimatedTokens.round();

    if (tokens > 0 && elapsedSec >= 0.05) {
      if (_recentBursts.length >= maxBurstHistory) {
        _recentBursts.removeAt(0);
      }
      _recentBursts.add(
        GenerationBurst(tokens: tokens, durationSeconds: elapsedSec),
      );
    }
  }

  /// Current live generation rate while streaming, falling back to rolling average
  /// if between tokens or after completion.
  double? get currentRate {
    if (_burstStopwatch.isRunning) {
      final elapsedSec = _burstStopwatch.elapsedMilliseconds / 1000.0;
      if (elapsedSec >= 0.1 && _currentBurstEstimatedTokens >= 1.0) {
        return _currentBurstEstimatedTokens / elapsedSec;
      }
    }
    if (_recentBursts.isNotEmpty) {
      return rollingRate;
    }
    return null;
  }

  /// Rolling token-per-second generation speed calculated across the last 10 bursts.
  double get rollingRate {
    if (_recentBursts.isEmpty) return 0.0;
    final totalTokens = _recentBursts.fold(0, (sum, b) => sum + b.tokens);
    final totalSeconds = _recentBursts.fold(
      0.0,
      (sum, b) => sum + b.durationSeconds,
    );
    return totalSeconds > 0 ? totalTokens / totalSeconds : 0.0;
  }

  /// The recent completed bursts (up to [maxBurstHistory]).
  List<GenerationBurst> get recentBursts => List.unmodifiable(_recentBursts);

  /// Clears all bursts and active stopwatch state (e.g. on session reset).
  void reset() {
    _burstStopwatch.reset();
    _currentBurstEstimatedTokens = 0.0;
    _hasReceivedFirstToken = false;
    _recentBursts.clear();
  }
}
