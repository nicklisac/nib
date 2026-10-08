import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/tool.dart';

/// Tool for reading file contents with line numbering.
class ReadFileTool extends AgentTool {
  final String workingDirectory;

  ReadFileTool({String? workingDirectory})
      : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String get name => 'read_file';

  @override
  String get description =>
      'Read the contents of a file in the workspace with line numbers. Optionally specify line ranges.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'The path of the file to read (relative to workspace or absolute).',
          },
          'start_line': {
            'type': 'integer',
            'description': 'Optional 1-indexed starting line number.',
          },
          'end_line': {
            'type': 'integer',
            'description': 'Optional 1-indexed ending line number (inclusive).',
          },
        },
        'required': ['path'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final rawPath = arguments['path'] as String?;
    if (rawPath == null || rawPath.trim().isEmpty) {
      return 'Error: Path argument is required';
    }

    final fullPath = p.isAbsolute(rawPath) ? rawPath : p.join(workingDirectory, rawPath);
    final file = File(fullPath);

    if (!await file.exists()) {
      return 'Error: File not found at "$rawPath"';
    }

    try {
      final lines = await file.readAsLines();
      final totalLines = lines.length;

      int startLine = (arguments['start_line'] as num?)?.toInt() ?? 1;
      int endLine = (arguments['end_line'] as num?)?.toInt() ?? totalLines;

      if (startLine < 1) startLine = 1;
      if (endLine > totalLines) endLine = totalLines;
      if (startLine > endLine) {
        return 'File "$rawPath" has $totalLines lines. Requested start_line $startLine is greater than end_line $endLine.';
      }

      final buffer = StringBuffer();
      final padWidth = endLine.toString().length;

      for (int i = startLine; i <= endLine; i++) {
        final lineNum = i.toString().padLeft(padWidth);
        final lineContent = lines[i - 1];
        buffer.writeln('$lineNum | $lineContent');
      }

      return buffer.toString().trimRight();
    } catch (e) {
      return 'Error reading file "$rawPath": $e';
    }
  }
}
