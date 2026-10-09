import 'package:test/test.dart';
import 'package:nib/agent/agent.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/thinking_level.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/ui/slash_commands.dart';

void main() {
  group('ThinkingLevel Ladder & Cycling', () {
    test('cycles through the full 7-level Tau ladder in order', () {
      expect(ThinkingLevel.off.next(), equals(ThinkingLevel.minimal));
      expect(ThinkingLevel.minimal.next(), equals(ThinkingLevel.low));
      expect(ThinkingLevel.low.next(), equals(ThinkingLevel.medium));
      expect(ThinkingLevel.medium.next(), equals(ThinkingLevel.high));
      expect(ThinkingLevel.high.next(), equals(ThinkingLevel.xhigh));
      expect(ThinkingLevel.xhigh.next(), equals(ThinkingLevel.max));
      expect(ThinkingLevel.max.next(), equals(ThinkingLevel.off));
    });

    test(
      'parse parses valid levels case-insensitively and throws on invalid',
      () {
        expect(ThinkingLevel.parse('off'), equals(ThinkingLevel.off));
        expect(ThinkingLevel.parse('Minimal'), equals(ThinkingLevel.minimal));
        expect(ThinkingLevel.parse('LOW'), equals(ThinkingLevel.low));
        expect(ThinkingLevel.parse('medium'), equals(ThinkingLevel.medium));
        expect(ThinkingLevel.parse('HIGH'), equals(ThinkingLevel.high));
        expect(ThinkingLevel.parse('xhigh'), equals(ThinkingLevel.xhigh));
        expect(ThinkingLevel.parse('MAX'), equals(ThinkingLevel.max));

        expect(() => ThinkingLevel.parse('unknown'), throwsFormatException);
      },
    );

    test('fromString falls back to medium on invalid input', () {
      expect(ThinkingLevel.fromString('bogus'), equals(ThinkingLevel.medium));
      expect(ThinkingLevel.fromString(''), equals(ThinkingLevel.medium));
      expect(ThinkingLevel.fromString('high'), equals(ThinkingLevel.high));
    });

    test('isOff reports accurately', () {
      expect(ThinkingLevel.off.isOff, isTrue);
      expect(ThinkingLevel.medium.isOff, isFalse);
    });
  });

  group('Provider-specific Thinking Mappings', () {
    test(
      'Anthropic budgets match Tau specification (tau_coding/thinking.py)',
      () {
        expect(ThinkingLevel.off.anthropicBudget, isNull);
        expect(ThinkingLevel.minimal.anthropicBudget, equals(1024));
        expect(ThinkingLevel.low.anthropicBudget, equals(2048));
        expect(ThinkingLevel.medium.anthropicBudget, equals(4096));
        expect(ThinkingLevel.high.anthropicBudget, equals(8192));
        expect(ThinkingLevel.xhigh.anthropicBudget, equals(16384));
        expect(ThinkingLevel.max.anthropicBudget, equals(32768));
      },
    );

    test('OpenAI reasoning_effort omits parameter when off to prevent 400', () {
      expect(ThinkingLevel.off.openAiReasoningEffort, isNull);
      expect(ThinkingLevel.minimal.openAiReasoningEffort, equals('minimal'));
      expect(ThinkingLevel.low.openAiReasoningEffort, equals('low'));
      expect(ThinkingLevel.medium.openAiReasoningEffort, equals('medium'));
      expect(ThinkingLevel.high.openAiReasoningEffort, equals('high'));
      expect(ThinkingLevel.xhigh.openAiReasoningEffort, equals('high'));
      expect(ThinkingLevel.max.openAiReasoningEffort, equals('high'));
    });

    test('Local Qwen / TabbyAPI chat_template_kwargs mapping', () {
      expect(
        ThinkingLevel.off.localChatTemplateKwargs,
        equals({'enable_thinking': false}),
      );
      expect(
        ThinkingLevel.minimal.localChatTemplateKwargs,
        equals({'reasoning_effort': 'low'}),
      );
      expect(
        ThinkingLevel.medium.localChatTemplateKwargs,
        equals({'reasoning_effort': 'medium'}),
      );
      expect(
        ThinkingLevel.high.localChatTemplateKwargs,
        equals({'reasoning_effort': 'medium'}),
      );
      expect(
        ThinkingLevel.xhigh.localChatTemplateKwargs,
        equals({'reasoning_effort': 'xhigh'}),
      );
      expect(
        ThinkingLevel.max.localChatTemplateKwargs,
        equals({'reasoning_effort': 'xhigh'}),
      );
    });
  });

  group('SlashCommandHandler /thinking and /image commands', () {
    test('/thinking sets agent thinking level', () async {
      final agent = Agent(
        provider: MockProvider(),
        session: AgentSession(),
        thinkingLevel: ThinkingLevel.medium,
      );
      final handler = SlashCommandHandler(agent);

      expect(agent.thinkingLevel, equals(ThinkingLevel.medium));

      final handledInfo = await handler.handle('/thinking');
      expect(handledInfo, isTrue);

      final handledSet = await handler.handle('/thinking high');
      expect(handledSet, isTrue);
      expect(agent.thinkingLevel, equals(ThinkingLevel.high));

      final handledOff = await handler.handle('/thinking off');
      expect(handledOff, isTrue);
      expect(agent.thinkingLevel, equals(ThinkingLevel.off));
    });
  });
}
