import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/agent.dart';
import '../agent/undo_manager.dart';
import '../ai/openai_provider.dart';
import 'ansi.dart';
import 'theme.dart';

/// Renders a sleek status dock showing model, context, undo stack, and workspace.
class StatusBar {
  static String render(Agent agent) {
    final theme = NibTheme.current;
    final model = agent.provider.model;
    final shortModel = model.length > 25 ? '${model.substring(0, 22)}...' : model;
    final provName = agent.provider.name;

    String endpoint = '';
    if (agent.provider is OpenAiProvider) {
      final url = (agent.provider as OpenAiProvider).baseUrl;
      final uri = Uri.tryParse(url);
      if (uri != null) {
        endpoint = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      }
    }

    final cwd = p.basename(Directory.current.path);
    final undoCount = UndoManager.instance.count;
    final totalTokens = agent.session.totalPromptTokens + agent.session.totalCompletionTokens;
    final tokenStr = totalTokens > 1000
        ? '${(totalTokens / 1000).toStringAsFixed(1)}k'
        : '$totalTokens';

    final buf = StringBuffer();

    // Subtle divider
    final termWidth = stdout.hasTerminal ? stdout.terminalColumns : 80;
    final dividerLen = termWidth > 80 ? 80 : termWidth;
    buf.writeln('  ${theme.muted.text('─' * (dividerLen - 4))}');

    // Badges line
    final pBadge = '${theme.surface.bg}${theme.accent.fg} $provName \x1B[0m';
    final mBadge = '${theme.surface.bg}${theme.primary.fg} $shortModel \x1B[0m';
    final dirBadge = '${theme.muted.text('📂 $cwd')}';
    final tokBadge = '${theme.info.text('⚡ ${tokenStr} tok')}';
    final undoBadge = undoCount > 0 ? ' ${theme.warning.text('⤺ undo: $undoCount')}' : '';
    final endBadge = endpoint.isNotEmpty ? ' ${theme.muted.text('($endpoint)')}' : '';

    buf.write('  $pBadge $mBadge  $dirBadge  $tokBadge$undoBadge$endBadge');
    return buf.toString();
  }
}
