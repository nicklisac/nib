import 'dart:io';
import 'package:path/path.dart' as p;
import '../ai/image_attachment.dart';

/// Metadata for a registered slash command.
class SlashCommandInfo {
  final String command;
  final String description;
  final String usage;

  const SlashCommandInfo(this.command, this.description, [this.usage = '']);
}

/// Fast fuzzy and prefix autocompleter for workspace files and slash commands.
class AutoCompleter {
  static const List<SlashCommandInfo> commandRegistry = [
    SlashCommandInfo(
      '/thinking',
      'Inspect or set thinking level ladder (off..max)',
      '/thinking [level]',
    ),
    SlashCommandInfo(
      '/image',
      'Attach image from path or clipboard into turn context',
      '/image [path]',
    ),
    SlashCommandInfo(
      '/resume',
      'Pick and resume a saved session (interactive picker)',
      '/resume [id]',
    ),
    SlashCommandInfo(
      '/skills',
      'View, enable, or inspect modular skills',
      '/skills [show|toggle|reload] [name]',
    ),
    SlashCommandInfo(
      '/compact',
      'Compact conversation context (Tau-style)',
      '/compact [focus]',
    ),
    SlashCommandInfo(
      '/undo',
      'Revert last tool file changes with snapshot rollback',
      '/undo',
    ),
    SlashCommandInfo(
      '/sessions',
      'List saved conversation sessions',
      '/sessions',
    ),
    SlashCommandInfo(
      '/theme',
      'Switch TrueColor theme (e.g. catppuccin, dracula, rosepine, tokyonight)',
      '/theme [name]',
    ),
    SlashCommandInfo(
      '/config',
      'View active provider, model, and endpoint config',
      '/config',
    ),
    SlashCommandInfo(
      '/provider',
      'Switch active AI provider profile',
      '/provider [name]',
    ),
    SlashCommandInfo('/model', 'Change active model name', '/model [name]'),
    SlashCommandInfo(
      '/tools',
      'List all registered agent tools and parameters',
      '/tools',
    ),
    SlashCommandInfo(
      '/history',
      'Display session message and token stats',
      '/history',
    ),
    SlashCommandInfo(
      '/system',
      'Show active system prompt and injected skills',
      '/system',
    ),
    SlashCommandInfo(
      '/confirm',
      'Toggle tool confirmation safety mode',
      '/confirm',
    ),
    SlashCommandInfo(
      '/new',
      'Start a brand new session with a fresh transcript',
      '/new',
    ),
    SlashCommandInfo(
      '/clear',
      'Clear terminal screen and redraw status bar',
      '/clear',
    ),
    SlashCommandInfo(
      '/redraw',
      'Full terminal redraw: clears screen and re-renders transcript history',
      '/redraw',
    ),
    SlashCommandInfo(
      '/help',
      'Show help documentation and keybindings',
      '/help',
    ),
    SlashCommandInfo('/exit', 'Exit Nib', '/exit'),
  ];

  static List<String> get slashCommands =>
      commandRegistry.map((c) => c.command).toList();

  /// Finds slash command completions for a given prefix.
  static List<String> completeSlash(String prefix) {
    final lower = prefix.toLowerCase();
    return slashCommands.where((cmd) => cmd.startsWith(lower)).toList();
  }

  /// Finds command metadata matching the prefix or query.
  static List<SlashCommandInfo> completeSlashInfo(String prefix) {
    final clean = prefix.toLowerCase().trim();
    if (clean.indexOf('/', 1) != -1) return const [];
    if (clean.isEmpty || clean == '/') return commandRegistry;
    return commandRegistry.where((c) {
      return c.command.startsWith(clean) ||
          c.command.contains(clean.replaceAll('/', '')) ||
          c.description.toLowerCase().contains(clean.replaceAll('/', ''));
    }).toList();
  }

  /// Scans workspace files for fuzzy matching `@query`.
  static List<String> completeFile(String query, {int limit = 8}) {
    final cleanQuery = query.startsWith('@') ? query.substring(1) : query;
    final results = <String>[];
    final currentDir = Directory.current;

    try {
      final entities = currentDir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is! File) continue;

        final rel = p.relative(entity.path, from: currentDir.path);
        if (rel.startsWith('.git/') ||
            rel.startsWith('.dart_tool/') ||
            rel.startsWith('build/')) {
          continue;
        }

        if (cleanQuery.isEmpty ||
            rel.toLowerCase().contains(cleanQuery.toLowerCase())) {
          results.add('@$rel');
          if (results.length >= limit) break;
        }
      }
    } catch (_) {}

    return results;
  }

  /// Expands `@filename` mentions in user input to include the file path or contents.
  static Future<String> expandFileMentions(String prompt) async {
    final mentionPattern = RegExp(r'@([A-Za-z0-9_\-\./]+)');
    final matches = mentionPattern.allMatches(prompt);
    if (matches.isEmpty) return prompt;

    var expanded = prompt;
    for (final match in matches) {
      final filePath = match.group(1)!;
      if (ImageAttachment.isImageFile(filePath)) continue;
      final file = File(filePath);
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          final snippet =
              '\n\n[File contents of $filePath]:\n```\n$content\n```\n';
          expanded = '$expanded$snippet';
        } catch (_) {}
      }
    }
    return expanded;
  }
}
