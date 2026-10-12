import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/approval_manager.dart';
import '../agent/tool.dart';
import '../agent/undo_manager.dart';

/// Tool for creating or overwriting files.
class WriteFileTool extends AgentTool {
  final String workingDirectory;

  WriteFileTool({String? workingDirectory})
    : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String get name => 'write_file';

  @override
  String get description =>
      'Create a new file or completely overwrite an existing file with the provided content.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'The path of the file to write (relative or absolute).',
      },
      'content': {
        'type': 'string',
        'description': 'The complete text content to write to the file.',
      },
    },
    'required': ['path', 'content'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final rawPath = arguments['path'] as String?;
    final content = arguments['content'] as String?;

    if (rawPath == null || rawPath.trim().isEmpty) {
      return const ToolResult.text('Error: Path argument is required');
    }
    if (content == null) {
      return const ToolResult.text('Error: Content argument is required');
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

    try {
      final beforeContent = await file.exists()
          ? await file.readAsString()
          : '';
      final approved = await ApprovalManager.instance.confirmFileEdit(
        path: rawPath,
        oldContent: beforeContent,
        newContent: content,
      );
      if (!approved) {
        return ToolResult.text('File write rejected by user for "$rawPath".');
      }

      await file.parent.create(recursive: true);
      await file.writeAsString(content);

      UndoManager.instance.recordEdit(
        path: fullPath,
        contentBefore: beforeContent,
        contentAfter: content,
      );

      final lineCount = content.split('\n').length;
      return ToolResult.text(
        'Successfully wrote $lineCount lines to "$rawPath" (${content.length} bytes)',
      );
    } catch (e) {
      return ToolResult.text('Error writing to file "$rawPath": $e');
    }
  }
}
