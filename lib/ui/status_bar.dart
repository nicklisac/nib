import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/agent.dart';
import '../agent/undo_manager.dart';
import 'theme.dart';

/// The dock: the badge block naming provider, model, and workspace.
///
/// Printed once with the prompt and left to scroll away, which is correct
/// behaviour rather than a bug — it names the context of the exchange below it
/// and follows that exchange into history. Present-tense state belongs to the
/// ambient line, not here.
///
/// Deliberately absent: the endpoint URL, which is redundant next to provider and
/// model and stays in `/config`, and the tokens-spent reading, which is billing
/// rather than occupancy and lives in `/history`.
///
/// The context gauge appears here as a *snapshot*, which is what a dock is for: it
/// names the state of the window the exchange below is about to be written into.
/// The ambient line carries the same figure live while a turn runs. Showing it at
/// prompt time is also what makes the compaction threshold visible before
/// compaction fires (doctrine rule 5) without a second row that would have to be
/// defended against every repaint (rule 1).
class StatusBar {
  static String render(Agent agent) {
    final theme = NibTheme.current;
    final model = agent.provider.model;
    final shortModel = model.length > 25
        ? '${model.substring(0, 22)}...'
        : model;
    final provName = agent.provider.name;

    final cwd = p.basename(Directory.current.path);
    final undoCount = UndoManager.instance.count;
    final gauge = agent.meter.displayWithThreshold(agent.session);

    final buf = StringBuffer();

    // The divider at the top of the human-owned window. Its length follows the
    // terminal instead of a hardcoded constant, capped with the transcript (#24).
    buf.writeln('  ${theme.muted.text('─' * _dividerWidth())}');

    final pBadge = '${theme.surface.bg}${theme.accent.fg} $provName \x1B[0m';
    final mBadge = '${theme.surface.bg}${theme.primary.fg} $shortModel \x1B[0m';
    final thinkBadge =
        '${theme.surface.bg}${theme.secondary.fg} 🧠 ${agent.thinkingLevel.label} \x1B[0m';
    final dirBadge = theme.muted.text('📂 $cwd');
    final undoBadge = undoCount > 0
        ? ' ${theme.warning.text('⤺ undo: $undoCount')}'
        : '';

    buf.write('  $pBadge $mBadge $thinkBadge  $dirBadge$undoBadge');
    buf.writeln();
    buf.write('  ${theme.muted.text(gauge)}');
    return buf.toString();
  }

  /// Width of the rule, in characters, leaving room for the two-space indent.
  static int _dividerWidth() {
    var cols = 80;
    try {
      if (stdout.hasTerminal) cols = stdout.terminalColumns;
    } catch (_) {}
    if (cols > 100) cols = 100;
    final width = cols - 2;
    return width < 8 ? 8 : width;
  }
}
