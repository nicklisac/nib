import 'package:nib/agent/agent.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/mock_provider.dart';
import 'package:nib/ui/cli_ui.dart';
import 'package:nib/ui/slash_commands.dart';
import 'package:nib/ui/theme.dart';
import 'package:nib/ui/transcript_render_model.dart';
import 'package:test/test.dart';

void main() {
  group('TranscriptRenderModel Tests', () {
    test('renders user prompt block with card frame', () {
      final block = UserPromptBlock('Hello world');
      final lines = block.render(theme: NibTheme.current, terminalWidth: 80);

      expect(lines.any((l) => l.contains('You')), isTrue);
      expect(lines.any((l) => l.contains('Hello world')), isTrue);
    });

    test('renders thought block expanded vs collapsed', () {
      final block = ThoughtBlock('Analyzing code and designing plan');
      final expanded = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        thinkingExpanded: true,
      );
      expect(
        expanded.any((l) => l.contains('Analyzing code and designing plan')),
        isTrue,
      );

      final collapsed = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        thinkingExpanded: false,
      );
      expect(collapsed.any((l) => l.contains('thinking collapsed')), isTrue);
      expect(collapsed.any((l) => l.contains('Analyzing code')), isFalse);
    });

    test('renders tool call block compact vs full output', () {
      final longStdout = List.generate(
        20,
        (i) => 'Line $i of output',
      ).join('\n');
      final block = ToolCallBlock(
        toolName: 'bash',
        arguments: {'command': 'dart test'},
        result: longStdout,
        durationMs: 42,
      );

      final compact = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        toolsExpanded: false,
      );
      expect(compact.any((l) => l.contains('bash')), isTrue);
      expect(compact.any((l) => l.contains('done (42ms)')), isTrue);
      expect(compact.any((l) => l.contains('more lines')), isTrue);

      final expanded = block.render(
        theme: NibTheme.current,
        terminalWidth: 80,
        toolsExpanded: true,
      );
      expect(expanded.any((l) => l.contains('Line 19 of output')), isTrue);
      expect(expanded.any((l) => l.contains('more lines')), isFalse);
    });

    test('TranscriptRenderModel manages and renders sequence of blocks', () {
      final model = TranscriptRenderModel();
      model.add(UserPromptBlock('Prompt 1'));
      model.add(ThoughtBlock('Thought 1'));
      model.add(AssistantTextBlock('Response 1'));

      final allLines = model.renderAll(
        theme: NibTheme.current,
        terminalWidth: 80,
      );

      expect(allLines.any((l) => l.contains('Prompt 1')), isTrue);
      expect(allLines.any((l) => l.contains('Thought 1')), isTrue);
      expect(allLines.any((l) => l.contains('Response 1')), isTrue);
    });

    test(
      'populateFromSession populates blocks with thinking and matched tool results',
      () {
        final session = AgentSession(id: 'test-session-1');
        session.addMessage(ChatMessage.user('List the files in the directory'));
        session.addMessage(
          ChatMessage(
            role: Role.assistant,
            thought: 'User wants directory listing.',
            content: 'Here are the files:',
            toolCalls: [
              ToolCall(
                id: 'call_123',
                name: 'list_dir',
                arguments: {'path': '.'},
              ),
            ],
          ),
        );
        session.addMessage(
          ChatMessage(
            role: Role.tool,
            toolCallId: 'call_123',
            content: 'file1.dart\nfile2.dart',
          ),
        );

        final model = TranscriptRenderModel();
        model.populateFromSession(session);

        expect(model.blocks.length, equals(4));
        expect(model.blocks[0], isA<UserPromptBlock>());
        expect(
          (model.blocks[0] as UserPromptBlock).text,
          equals('List the files in the directory'),
        );
        expect(model.blocks[1], isA<ThoughtBlock>());
        expect(
          (model.blocks[1] as ThoughtBlock).thought,
          equals('User wants directory listing.'),
        );
        expect(model.blocks[2], isA<AssistantTextBlock>());
        expect(
          (model.blocks[2] as AssistantTextBlock).text,
          equals('Here are the files:'),
        );
        expect(model.blocks[3], isA<ToolCallBlock>());
        final toolBlock = model.blocks[3] as ToolCallBlock;
        expect(toolBlock.toolName, equals('list_dir'));
        expect(toolBlock.result, equals('file1.dart\nfile2.dart'));
      },
    );

    test(
      'SlashCommandHandler /resume triggers onSessionResumed with loaded session',
      () async {
        final oldSession = AgentSession(id: 'test-resume-session');
        oldSession.addMessage(ChatMessage.user('Existing conversation'));
        await oldSession.saveToDisk();

        final currentSession = AgentSession(id: 'current-session');
        final agent = Agent(provider: MockProvider(), session: currentSession);

        AgentSession? resumedSession;
        final handler = SlashCommandHandler(
          agent,
          null,
          null,
          null,
          (loaded) => resumedSession = loaded,
        );

        final handled = await handler.handle('/resume test-resume-session');
        expect(handled, isTrue);
        expect(agent.session.id, equals('test-resume-session'));
        expect(resumedSession, isNotNull);
        expect(resumedSession!.id, equals('test-resume-session'));
        expect(
          resumedSession!.messages.any(
            (m) => m.content == 'Existing conversation',
          ),
          isTrue,
        );
      },
    );

    test('CliUi /resume loads session and populates renderModel', () async {
      final oldSession = AgentSession(id: 'test-cli-resume');
      oldSession.addMessage(ChatMessage.user('Saved user prompt'));
      oldSession.addMessage(
        ChatMessage(
          role: Role.assistant,
          thought: 'Deep thought',
          content: 'Helpful answer',
        ),
      );
      await oldSession.saveToDisk();

      final currentSession = AgentSession(id: 'current-session-2');
      final agent = Agent(provider: MockProvider(), session: currentSession);
      final ui = CliUi(agent);

      expect(ui.renderModel.blocks, isEmpty);

      // Execute /resume via ui's slash handler
      final handled = await ui.slashHandler.handle('/resume test-cli-resume');
      expect(handled, isTrue);
      expect(agent.session.id, equals('test-cli-resume'));
      expect(ui.renderModel.blocks.length, equals(3));
      expect(ui.renderModel.blocks[0], isA<UserPromptBlock>());
      expect(
        (ui.renderModel.blocks[0] as UserPromptBlock).text,
        equals('Saved user prompt'),
      );
      expect(ui.renderModel.blocks[1], isA<ThoughtBlock>());
      expect(
        (ui.renderModel.blocks[1] as ThoughtBlock).thought,
        equals('Deep thought'),
      );
      expect(ui.renderModel.blocks[2], isA<AssistantTextBlock>());
      expect(
        (ui.renderModel.blocks[2] as AssistantTextBlock).text,
        equals('Helpful answer'),
      );
    });
  });
}
