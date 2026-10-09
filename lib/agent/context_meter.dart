import 'compaction.dart';
import 'session.dart';

/// The context gauge: how much of the model's window the *next request* would
/// occupy — the reading a human acts on, by compacting or starting over.
///
/// Tau's model, copied exactly: an estimate is always available (chars/4 plus
/// per-message overhead), and provider-reported usage replaces it and is marked
/// as measured. The two are never blended into one figure, and an estimate is
/// always written with a `~` so it cannot look like a measurement (feel doctrine
/// rule 4).
class ContextMeter {
  /// Prompt tokens reported by the provider for the most recent request. Null
  /// until a provider actually sends usage — the distinction Tau keeps as
  /// `has_provider_context_usage`.
  int? measuredPromptTokens;

  /// The window the gauge is measured against, from config, defaulting to 128k.
  /// Deliberately the same source the compaction trigger reads, so the gauge and
  /// the trigger cannot disagree about how close the threshold is.
  final int contextWindow;

  final int? _reserveOverride;

  ContextMeter({
    this.contextWindow = CompactionManager.defaultContextWindowTokens,
    int? reserve,
  }) : _reserveOverride = reserve;

  /// Tokens held back for the reply. The rule lives here and nowhere else, so the
  /// gauge a human reads and the compaction trigger that fires cannot disagree
  /// about how close the threshold is (feel doctrine rule 5).
  int get reserve =>
      _reserveOverride ??
      (contextWindow > 32000
          ? CompactionManager.defaultCompactionReserveTokens
          : contextWindow ~/ 4);

  /// True when the numerator is provider-reported rather than estimated. An
  /// estimate must never be formatted to look like this reading.
  bool get isMeasured => measuredPromptTokens != null;

  /// Records usage from a completed request. Only the prompt side feeds the
  /// gauge; completion tokens are spend, not occupancy, and live in `/history`.
  void recordPromptTokens(int? promptTokens) {
    if (promptTokens != null) measuredPromptTokens = promptTokens;
  }

  /// Tokens the next request would occupy.
  int tokensFor(AgentSession session) =>
      measuredPromptTokens ??
      CompactionManager.estimateTokens(
        session.messages,
        systemPrompt: session.systemPrompt,
      );

  /// Fraction of the window, clamped so a blown window reads as full rather than
  /// as 137%.
  double fractionFor(AgentSession session) {
    if (contextWindow <= 0) return 0;
    return (tokensFor(session) / contextWindow).clamp(0.0, 1.0);
  }

  /// Whole percent: the ambient line spends four characters on this field, and a
  /// decimal buys nothing a human acts on.
  int percentFor(AgentSession session) => (fractionFor(session) * 100).round();

  /// The gauge as displayed. The `~` prefix discloses that it is an estimate.
  String displayFor(AgentSession session) =>
      isMeasured ? '${percentFor(session)}%' : '~${percentFor(session)}%';

  /// Tokens at which auto-compaction fires, on the same basis as [tokensFor].
  /// Surfaced rather than hidden: losing your place begins with the transcript
  /// changing underneath you without warning (feel doctrine rule 5).
  int get threshold =>
      contextWindow - reserve < 0 ? 0 : contextWindow - reserve;

  /// The gauge as displayed alongside the threshold that will trigger
  /// compaction, e.g. `~23% · compact at 111.6k`.
  String displayWithThreshold(AgentSession session) =>
      '${displayFor(session)} · compact at ${_formatTokens(threshold)}';

  static String _formatTokens(int tokens) =>
      tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : '$tokens';

  bool atThresholdFor(AgentSession session) => tokensFor(session) >= threshold;
}
