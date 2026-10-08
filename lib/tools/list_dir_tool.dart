import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/tool.dart';

/// Tool for listing files and subdirectories.
class ListDirTool extends AgentTool {
  final String workingDirectory;

  ListDirTool({String? workingDirectory})
      : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String get name => 'list_dir';

  @override
  String get description =>
      'List files and subdirectories in a given directory path. Shows file types and sizes.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Directory path to list (default: current workspace root ".").',
          },
          'recursive': {
            'type': 'boolean',
            'description': 'Whether to list subdirectories recursively (default: false).',
          },
          'max_depth': {
            'type': 'integer',
            'description': 'Maximum recursion depth if recursive is true (default: 3).',
          },
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final rawPath = (arguments['path'] as String?)?.trim() ?? '.';
    final recursive = (arguments['recursive'] as bool?) ?? false;
    final maxDepth = (arguments['max_depth'] as num?)?.toInt() ?? 3;

    final targetPath = p.normalize(p.isAbsolute(rawPath) ? rawPath : p.join(workingDirectory, rawPath));
    if (!p.isWithin(workingDirectory, targetPath) && targetPath != workingDirectory) {
      return 'Error: Path "$rawPath" is outside workspace directory "$workingDirectory"';
    }
    final dir = Directory(targetPath);

    if (!await dir.exists()) {
      return 'Error: Directory not found at "$rawPath"';
    }

    try {
      final entries = <FileSystemEntity>[];

      if (recursive) {
        await _collectEntries(dir, entries, 1, maxDepth);
      } else {
        await for (final entity in dir.list(followLinks: false)) {
          entries.add(entity);
        }
      }

      entries.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        return a.path.compareTo(b.path);
      });

      final buffer = StringBuffer();
      final displayRoot = rawPath == '.' ? 'workspace root' : rawPath;
      buffer.writeln('Contents of $displayRoot (${entries.length} items):');

      for (final entity in entries) {
        final rel = p.relative(entity.path, from: targetPath);
        // Skip hidden git internals
        if (rel.startsWith('.git/') || rel == '.git') continue;

        if (entity is Directory) {
          buffer.writeln('  📁 $rel/');
        } else if (entity is File) {
          final size = entity.lengthSync();
          buffer.writeln('  📄 $rel  (${_formatBytes(size)})');
        } else if (entity is Link) {
          buffer.writeln('  🔗 $rel -> (symlink)');
        }
      }

      return buffer.toString().trimRight();
    } catch (e) {
      return 'Error listing directory "$rawPath": $e';
    }
  }

  Future<void> _collectEntries(
    Directory dir,
    List<FileSystemEntity> entries,
    int currentDepth,
    int maxDepth,
  ) async {
    if (currentDepth > maxDepth) return;
    await for (final entity in dir.list(followLinks: false)) {
      final base = p.basename(entity.path);
      if (base == '.git' || base == '.dart_tool' || base == 'build') continue;

      entries.add(entity);
      if (entity is Directory && currentDepth < maxDepth) {
        await _collectEntries(entity, entries, currentDepth + 1, maxDepth);
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
