/// The 7-step thinking level ladder matching Tau.
enum ThinkingLevel {
  off('off'),
  minimal('minimal'),
  low('low'),
  medium('medium'),
  high('high'),
  xhigh('xhigh'),
  max('max');

  final String label;
  const ThinkingLevel(this.label);

  /// Returns the next level cycling forward (for shift+tab).
  ThinkingLevel next() {
    final nextIdx = (index + 1) % ThinkingLevel.values.length;
    return ThinkingLevel.values[nextIdx];
  }

  bool get isOff => this == ThinkingLevel.off;

  /// Parses string to [ThinkingLevel], throwing [FormatException] on unknown value.
  static ThinkingLevel parse(String val) {
    final lower = val.trim().toLowerCase();
    for (final level in ThinkingLevel.values) {
      if (level.label == lower) return level;
    }
    throw FormatException(
      'Unknown thinking level "$val". Valid levels: '
      '${ThinkingLevel.values.map((l) => l.label).join(', ')}',
    );
  }

  /// Parses string to [ThinkingLevel], falling back to [ThinkingLevel.medium] if invalid.
  static ThinkingLevel fromString(String val) {
    try {
      return parse(val);
    } catch (_) {
      return ThinkingLevel.medium;
    }
  }

  /// Default budget tokens mapping for Anthropic (tau_coding/thinking.py:65-80).
  int? get anthropicBudget => switch (this) {
    ThinkingLevel.off => null,
    ThinkingLevel.minimal => 1024,
    ThinkingLevel.low => 2048,
    ThinkingLevel.medium => 4096,
    ThinkingLevel.high => 8192,
    ThinkingLevel.xhigh => 16384,
    ThinkingLevel.max => 32768,
  };

  /// Default OpenAI reasoning_effort value.
  /// Note: 'off' returns null so reasoning_effort is omitted (avoiding HTTP 400).
  String? get openAiReasoningEffort => switch (this) {
    ThinkingLevel.off => null,
    ThinkingLevel.minimal => 'minimal',
    ThinkingLevel.low => 'low',
    ThinkingLevel.medium => 'medium',
    ThinkingLevel.high => 'high',
    ThinkingLevel.xhigh => 'high',
    ThinkingLevel.max => 'high',
  };

  /// Local Qwen/chat-template kwargs (tabbyAPI / exllama).
  /// TabbyAPI Qwen chat-template accepts xhigh, medium, low, or enable_thinking: false.
  Map<String, dynamic> get localChatTemplateKwargs => switch (this) {
    ThinkingLevel.off => {'enable_thinking': false},
    ThinkingLevel.minimal => {'reasoning_effort': 'low'},
    ThinkingLevel.low => {'reasoning_effort': 'low'},
    ThinkingLevel.medium => {'reasoning_effort': 'medium'},
    ThinkingLevel.high => {'reasoning_effort': 'medium'},
    ThinkingLevel.xhigh => {'reasoning_effort': 'xhigh'},
    ThinkingLevel.max => {'reasoning_effort': 'xhigh'},
  };
}
