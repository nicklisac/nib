import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../ui/diff_formatter.dart';
import '../ui/terminal_manager.dart';
import '../ui/theme.dart';

/// Manages interactive user approval for file changes and destructive commands.
class ApprovalManager {
  static final ApprovalManager instance = ApprovalManager._();
  ApprovalManager._();

  bool requireConfirmation = false;
  bool confirmAllCommands = false;

  /// Optional hook for testing to provide synthetic keystrokes.
  Future<Key> Function()? keyReader;

  /// Called before the prompt reads a key, and after it has returned one. The
  /// approval prompt *steals* the keys rather than contending for them: the UI
  /// uses these to release any parked draft reader first, and to reopen the draft
  /// window afterwards. The half-composed draft is held meanwhile, never dropped
  /// (#23, feel doctrine rule 2).
  Future<void> Function()? onApprovalStart;
  void Function()? onApprovalEnd;

  /// Runs one approval exchange with the keys stolen from whoever holds them,
  /// and guarantees they are handed back — including when the answer is Esc or an
  /// exception escapes the prompt.
  Future<T> _withStolenKeys<T>(Future<T> Function() prompt) async {
    await onApprovalStart?.call();
    try {
      return await prompt();
    } finally {
      onApprovalEnd?.call();
    }
  }

  Future<Key> _readKey() {
    if (keyReader != null) return keyReader!();
    return TerminalManager.instance.nextKey();
  }

  /// Determines if a shell command contains potentially destructive operations.
  static bool isDestructiveBashCommand(String command) {
    // 1. Known destructive command keywords
    final destructivePattern = RegExp(
      r'\b(rm|mv|dd|mkfs|fdisk|parted|shred|truncate|drop|dropdb|dropuser|chmod|chown|kill|pkill|killall|reboot|shutdown|poweroff|sudo|su)\b',
      caseSensitive: false,
    );
    if (destructivePattern.hasMatch(command)) return true;

    // 2. Destructive git operations (reset, clean, checkout ., restore ., branch -D, push --force/-f)
    final gitDestructivePattern = RegExp(
      r'\bgit\s+(reset|clean|checkout\s+(-\S*\s+)?\.|restore|branch\s+-[dD]|push\b.*?\s(-f|--force))',
    );
    if (gitDestructivePattern.hasMatch(command)) return true;

    // 3. Destructive package publishing
    final pkgDestructive = RegExp(
      r'\b(npm|yarn|pnpm|cargo|pip|gem)\s+(publish|unpublish)\b',
    );
    if (pkgDestructive.hasMatch(command)) return true;

    // 4. Overwrite redirections to sensitive system paths
    if (RegExp(r'>\s*/(etc|dev|boot|usr|bin|sbin)').hasMatch(command)) {
      return true;
    }

    return false;
  }

  /// Asks user for confirmation before writing an edit to a file.
  Future<bool> confirmFileEdit({
    required String path,
    required String oldContent,
    required String newContent,
  }) async {
    if (!requireConfirmation) return true;

    // Headless / non-terminal environments must fail-closed when confirmation is required
    if (!stdout.hasTerminal && keyReader == null) {
      stderr.writeln(
        '  [Approval required for file edit ($path) in non-interactive mode. Rejecting.]',
      );
      return false;
    }

    final theme = NibTheme.current;
    stdout.writeln();
    stdout.writeln(
      '  ${theme.warning.text('⚠')} ${theme.primary.text('Review proposed changes to:')} ${theme.accent.text(path)}',
    );

    return _withStolenKeys(() => _askFileEdit(theme, oldContent, newContent));
  }

  Future<bool> _askFileEdit(
    NibTheme theme,
    String oldContent,
    String newContent,
  ) async {
    while (true) {
      stdout.write(
        '  ${theme.secondary.text('Apply this change?')} ${theme.muted.text('[y: yes, n: no, d: show diff]')} ${theme.accent.text('❯')} ',
      );
      TerminalManager.instance.clearBuffer();
      final key = await _readKey();
      if (key.isControl && key.controlChar == ControlCharacter.escape) {
        stdout.writeln('Esc');
        stdout.writeln(
          '  ${theme.error.text('✖ Change rejected by user (Esc).')}',
        );
        return false;
      }

      final char = key.isControl
          ? (key.controlChar == ControlCharacter.enter ? 'y' : '')
          : key.char.toLowerCase();

      stdout.writeln(
        char.isNotEmpty ? char : (key.isControl ? key.controlChar.name : ''),
      );

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
        stdout.writeln(
          '  ${theme.muted.text('Please enter y, n, or d (or Esc to reject).')}',
        );
      }
    }
  }

  /// Asks user for confirmation before running potentially destructive shell commands.
  Future<bool> confirmBashCommand(String command) async {
    if (!requireConfirmation) return true;

    final isDestructive =
        confirmAllCommands || isDestructiveBashCommand(command);
    if (!isDestructive) return true;

    // Headless / non-terminal environments must fail-closed when confirmation is required
    if (!stdout.hasTerminal && keyReader == null) {
      stderr.writeln(
        '  [Approval required for command ("$command") in non-interactive mode. Rejecting.]',
      );
      return false;
    }

    final theme = NibTheme.current;
    stdout.writeln();
    stdout.writeln(
      '  ${theme.error.text('⚠ Potentially destructive shell command:')}',
    );
    stdout.writeln('    ${theme.code.text(command)}');
    return _withStolenKeys(() => _askBash(theme, command));
  }

  Future<bool> _askBash(NibTheme theme, String command) async {
    stdout.write(
      '  ${theme.secondary.text('Execute?')} ${theme.muted.text('[y/n]')} ${theme.accent.text('❯')} ',
    );

    TerminalManager.instance.clearBuffer();
    final key = await _readKey();
    if (key.isControl && key.controlChar == ControlCharacter.escape) {
      stdout.writeln('Esc');
      stdout.writeln(
        '  ${theme.error.text('✖ Command rejected by user (Esc).')}',
      );
      return false;
    }

    final char = key.isControl
        ? (key.controlChar == ControlCharacter.enter ? 'y' : '')
        : key.char.toLowerCase();

    stdout.writeln(
      char.isNotEmpty ? char : (key.isControl ? key.controlChar.name : ''),
    );
    if (char == 'y') {
      return true;
    } else {
      stdout.writeln('  ${theme.error.text('✖ Command rejected by user.')}');
      return false;
    }
  }
}
