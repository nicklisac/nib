import 'dart:io';
import '../ui/ansi.dart';
import '../ui/diff_formatter.dart';
import '../ui/theme.dart';

/// Manages interactive user approval for file changes and destructive commands.
class ApprovalManager {
  static final ApprovalManager instance = ApprovalManager._();
  ApprovalManager._();

  bool requireConfirmation = false;

  /// Asks user for confirmation before writing an edit to a file.
  Future<bool> confirmFileEdit({
    required String path,
    required String oldContent,
    required String newContent,
  }) async {
    if (!requireConfirmation || !stdout.hasTerminal) return true;

    final theme = NibTheme.current;
    stdout.writeln();
    stdout.writeln('  ${theme.warning.text('⚠')} ${theme.primary.text('Review proposed changes to:')} ${theme.accent.text(path)}');

    while (true) {
      stdout.write('  ${theme.secondary.text('Apply this change?')} ${theme.muted.text('[y: yes, n: no, d: show diff]')} ${theme.accent.text('❯')} ');
      final input = stdin.readLineSync()?.trim().toLowerCase();

      if (input == 'y' || input == 'yes' || input == '') {
        return true;
      } else if (input == 'n' || input == 'no') {
        stdout.writeln('  ${theme.error.text('✖ Change rejected by user.')}');
        return false;
      } else if (input == 'd' || input == 'diff') {
        final diff = DiffFormatter.formatDiff(oldContent, newContent);
        stdout.writeln();
        for (final line in diff) {
          stdout.writeln('    $line');
        }
        stdout.writeln();
      }
    }
  }

  /// Asks user for confirmation before running potentially destructive shell commands.
  Future<bool> confirmBashCommand(String command) async {
    if (!requireConfirmation || !stdout.hasTerminal) return true;

    final isDestructive = RegExp(r'\b(rm|git\s+reset|git\s+clean|drop|truncate)\b')
        .hasMatch(command);

    if (!isDestructive) return true;

    final theme = NibTheme.current;
    stdout.writeln();
    stdout.writeln('  ${theme.error.text('⚠ Potentially destructive shell command:')}');
    stdout.writeln('    ${theme.code.text(command)}');
    stdout.write('  ${theme.secondary.text('Execute?')} ${theme.muted.text('[y/n]')} ${theme.accent.text('❯')} ');

    final input = stdin.readLineSync()?.trim().toLowerCase();
    return input == 'y' || input == 'yes';
  }
}
