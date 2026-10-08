import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../ui/ansi.dart';
import '../ui/diff_formatter.dart';
import '../ui/terminal_manager.dart';
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
      TerminalManager.instance.clearBuffer();
      final key = await TerminalManager.instance.nextKey();
      if (key.isControl && key.controlChar == ControlCharacter.escape) {
        stdout.writeln('Esc');
        stdout.writeln('  ${theme.error.text('✖ Change rejected by user (Esc).')}');
        return false;
      }

      final char = key.isControl
          ? (key.controlChar == ControlCharacter.enter ? 'y' : '')
          : key.char.toLowerCase();

      stdout.writeln(char.isNotEmpty ? char : (key.isControl ? key.controlChar.name : ''));

      if (char == 'y') {
        return true;
      } else if (char == 'n') {
        stdout.writeln('  ${theme.error.text('✖ Change rejected by user.')}');
        return false;
      } else if (char == 'd') {
        final diff = DiffFormatter.formatDiff(oldContent, newContent);
        stdout.writeln();
        for (final line in diff) {
          stdout.writeln('    $line');
        }
        stdout.writeln();
      } else {
        stdout.writeln('  ${theme.muted.text('Please enter y, n, or d (or Esc to reject).')}');
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

    TerminalManager.instance.clearBuffer();
    final key = await TerminalManager.instance.nextKey();
    if (key.isControl && key.controlChar == ControlCharacter.escape) {
      stdout.writeln('Esc');
      stdout.writeln('  ${theme.error.text('✖ Command rejected by user (Esc).')}');
      return false;
    }

    final char = key.isControl
        ? (key.controlChar == ControlCharacter.enter ? 'y' : '')
        : key.char.toLowerCase();

    stdout.writeln(char.isNotEmpty ? char : (key.isControl ? key.controlChar.name : ''));
    if (char == 'y') {
      return true;
    } else {
      stdout.writeln('  ${theme.error.text('✖ Command rejected by user.')}');
      return false;
    }
  }
}
