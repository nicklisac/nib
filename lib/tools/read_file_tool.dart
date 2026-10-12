import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/tool.dart';
import '../ai/image_attachment.dart';

/// Tool for reading file contents with line numbering, or inspecting images for multimodal models.
class ReadFileTool extends AgentTool {
  final String workingDirectory;

  ReadFileTool({String? workingDirectory})
    : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String get name => 'read_file';

  @override
  String get description =>
      'Read the contents of a file in the workspace with line numbers. Optionally specify line ranges. If an image file (PNG, JPEG, GIF, WEBP, BMP, TIFF, ICO) is specified, loads and inspects the image for vision-capable models.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description':
            'The path of the file to read (relative to workspace or absolute).',
      },
      'start_line': {
        'type': 'integer',
        'description':
            'Optional 1-indexed starting line number (text files only).',
      },
      'end_line': {
        'type': 'integer',
        'description':
            'Optional 1-indexed ending line number (inclusive, text files only).',
      },
    },
    'required': ['path'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final rawPath = arguments['path'] as String?;
    if (rawPath == null || rawPath.trim().isEmpty) {
      return const ToolResult.text('Error: Path argument is required');
    }

    final fullPath = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(workingDirectory, rawPath),
    );
    if (!p.isWithin(workingDirectory, fullPath) &&
        fullPath != workingDirectory) {
      return ToolResult.text(
        'Error: Path "$rawPath" is outside workspace directory "$workingDirectory"',
      );
    }
    final file = File(fullPath);

    if (!await file.exists()) {
      return ToolResult.text('Error: File not found at "$rawPath"');
    }

    // Check if the file is a recognized image type
    if (ImageAttachment.isImageFile(fullPath)) {
      try {
        final attachment = await ImageAttachment.fromFile(file);
        if (attachment == null) {
          return ToolResult.text(
            'Error: Could not decode "$rawPath" as a valid image.',
          );
        }
        return ToolResult(
          'Read image "$rawPath" (${attachment.width}x${attachment.height}, ${attachment.mimeType}).',
          images: [attachment],
        );
      } catch (e) {
        return ToolResult.text('Error reading image file "$rawPath": $e');
      }
    }

    try {
      final lines = await file.readAsLines();
      final totalLines = lines.length;

      int startLine = (arguments['start_line'] as num?)?.toInt() ?? 1;
      int endLine = (arguments['end_line'] as num?)?.toInt() ?? totalLines;

      if (startLine < 1) startLine = 1;
      if (endLine > totalLines) endLine = totalLines;
      if (startLine > endLine) {
        return ToolResult.text(
          'File "$rawPath" has $totalLines lines. Requested start_line $startLine is greater than end_line $endLine.',
        );
      }

      final buffer = StringBuffer();
      final padWidth = endLine.toString().length;

      for (int i = startLine; i <= endLine; i++) {
        final lineNum = i.toString().padLeft(padWidth);
        final lineContent = lines[i - 1];
        buffer.writeln('$lineNum | $lineContent');
      }

      return ToolResult.text(buffer.toString().trimRight());
    } catch (e) {
      // If reading text failed (e.g. invalid UTF-8 bytes), check if this is an image
      try {
        final attachment = await ImageAttachment.fromFile(file);
        if (attachment != null) {
          return ToolResult(
            'Read image "$rawPath" (${attachment.width}x${attachment.height}, ${attachment.mimeType}).',
            images: [attachment],
          );
        }
      } catch (_) {}

      return ToolResult.text('Error reading file "$rawPath": $e');
    }
  }
}
