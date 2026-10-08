import 'dart:io';
import 'package:path/path.dart' as p;

/// Fast fuzzy and prefix autocompleter for workspace files and slash commands.
class AutoCompleter {
  static final List<String> slashCommands = [
    '/help',
    '/undo',
    '/compact',
    '/theme',
    '/sessions',
    '/resume',
    '/config',
    '/provider',
    '/model',
    '/tools',
    '/history',
    '/system',
    '/confirm',
    '/clear',
    '/mock',
    '/exit',
  ];

  /// Finds slash command completions for a given prefix.
  static List<String> completeSlash(String prefix) {
    final lower = prefix.toLowerCase();
    return slashCommands.where((cmd) => cmd.startsWith(lower)).toList();
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

        if (cleanQuery.isEmpty || rel.toLowerCase().contains(cleanQuery.toLowerCase())) {
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
      final file = File(filePath);
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          final snippet = '\n\n[File contents of $filePath]:\n```\n$content\n```\n';
          expanded = '$expanded$snippet';
        } catch (_) {}
      }
    }
    return expanded;
  }
}
