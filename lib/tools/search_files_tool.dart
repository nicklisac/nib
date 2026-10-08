import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/tool.dart';

/// Tool for searching text or regular expressions across project files.
class SearchFilesTool extends AgentTool {
  final String workingDirectory;

  SearchFilesTool({String? workingDirectory})
      : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String get name => 'search_files';

  @override
  String get description =>
      'Search for regex patterns or literal text across files in the workspace directory.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The string or regular expression pattern to search for.',
          },
          'path': {
            'type': 'string',
            'description': 'Directory to search within (default: "." workspace root).',
          },
          'is_regex': {
            'type': 'boolean',
            'description': 'Whether the query is a regular expression (default: false).',
          },
          'case_sensitive': {
            'type': 'boolean',
            'description': 'Whether the search is case-sensitive (default: false).',
          },
        },
        'required': ['query'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final query = arguments['query'] as String?;
    if (query == null || query.isEmpty) {
      return 'Error: Query argument is required';
    }

    final rawPath = (arguments['path'] as String?)?.trim() ?? '.';
    final isRegex = (arguments['is_regex'] as bool?) ?? false;
    final caseSensitive = (arguments['case_sensitive'] as bool?) ?? false;

    final targetPath = p.isAbsolute(rawPath) ? rawPath : p.join(workingDirectory, rawPath);
    final targetDir = Directory(targetPath);

    if (!await targetDir.exists()) {
      return 'Error: Directory not found at "$rawPath"';
    }

    Pattern pattern;
    try {
      pattern = isRegex
          ? RegExp(query, caseSensitive: caseSensitive)
          : (caseSensitive ? query : RegExp(RegExp.escape(query), caseSensitive: false));
    } catch (e) {
      return 'Error in regular expression: $e';
    }

    final results = <String>[];
    int totalMatches = 0;
    const maxMatches = 100;

    await for (final entity in targetDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final relPath = p.relative(entity.path, from: workingDirectory);
      if (relPath.startsWith('.git/') ||
          relPath.startsWith('.dart_tool/') ||
          relPath.contains('/build/')) {
        continue;
      }

      // Skip common binary files
      final ext = p.extension(relPath).toLowerCase();
      if ({'.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.tar', '.gz', '.exe', '.so', '.dylib', '.lock'}.contains(ext)) {
        continue;
      }

      try {
        final lines = await entity.readAsLines();
        for (int i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (pattern.allMatches(line).isNotEmpty) {
            results.add('$relPath:${i + 1}: ${line.trim()}');
            totalMatches++;
            if (totalMatches >= maxMatches) break;
          }
        }
      } catch (_) {
        // Binary or unreadable file, ignore
      }

      if (totalMatches >= maxMatches) break;
    }

    if (results.isEmpty) {
      return 'No matches found for "$query".';
    }

    final buffer = StringBuffer();
    buffer.writeln('Found $totalMatches matches for "$query":');
    for (final res in results) {
      buffer.writeln('  $res');
    }
    if (totalMatches >= maxMatches) {
      buffer.writeln('  ...[Truncated after $maxMatches matches]');
    }

    return buffer.toString().trimRight();
  }
}
