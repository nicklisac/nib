import 'dart:io';
import 'package:path/path.dart' as p;
import '../agent/approval_manager.dart';
import '../agent/tool.dart';
import '../agent/undo_manager.dart';
import '../ui/diff_formatter.dart';

/// Tool for precise search-and-replace edits inside files.
class EditFileTool extends AgentTool {
  final String workingDirectory;

  EditFileTool({String? workingDirectory})
    : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String get name => 'edit_file';

  @override
  String get description =>
      'Edit an existing file by replacing a contiguous block of text (target_content) with new text (replacement_content). target_content must match exactly.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'The path of the file to edit (relative or absolute).',
      },
      'target_content': {
        'type': 'string',
        'description':
            'The exact contiguous block of text to be replaced (also accepted as oldText). Must uniquely match in the file.',
      },
      'replacement_content': {
        'type': 'string',
        'description':
            'The new text to replace target_content with (also accepted as newText).',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final rawPath = arguments['path'] as String?;
    final targetContent =
        (arguments['target_content'] ??
                arguments['oldText'] ??
                arguments['old_text'])
            as String?;
    final replacementContent =
        (arguments['replacement_content'] ??
                arguments['newText'] ??
                arguments['new_text'])
            as String?;

    if (rawPath == null || rawPath.trim().isEmpty) {
      return 'Error: Path argument is required';
    }
    if (targetContent == null) {
      return 'Error: target_content argument is required';
    }
    if (replacementContent == null) {
      return 'Error: replacement_content argument is required';
    }

    final fullPath = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(workingDirectory, rawPath),
    );
    if (!p.isWithin(workingDirectory, fullPath) &&
        fullPath != workingDirectory) {
      return 'Error: Path "$rawPath" is outside workspace directory "$workingDirectory"';
    }
    final file = File(fullPath);

    if (!await file.exists()) {
      return 'Error: File not found at "$rawPath"';
    }

    try {
      final text = await file.readAsString();

      // Count occurrences
      final occurrences = _countOccurrences(text, targetContent);
      if (occurrences == 0) {
        return 'Error: target_content was not found in "$rawPath". Ensure exact matching including whitespace and indentation.';
      }
      if (occurrences > 1) {
        return 'Error: target_content matched $occurrences times in "$rawPath". Please provide more surrounding context to make the match unique.';
      }

      final index = text.indexOf(targetContent);
      final newText = text.replaceRange(
        index,
        index + targetContent.length,
        replacementContent,
      );

      final approved = await ApprovalManager.instance.confirmFileEdit(
        path: rawPath,
        oldContent: targetContent,
        newContent: replacementContent,
      );
      if (!approved) {
        return 'Edit rejected by user for "$rawPath".';
      }

      await file.writeAsString(newText);

      UndoManager.instance.recordEdit(
        path: fullPath,
        contentBefore: text,
        contentAfter: newText,
      );

      final diff = DiffFormatter.formatDiff(targetContent, replacementContent);
      final buffer = StringBuffer();
      buffer.writeln('Successfully updated "$rawPath":');
      for (final line in diff) {
        buffer.writeln('  $line');
      }

      return buffer.toString().trimRight();
    } catch (e) {
      return 'Error editing file "$rawPath": $e';
    }
  }

  int _countOccurrences(String haystack, String needle) {
    if (needle.isEmpty) return 0;
    int count = 0;
    int index = 0;
    while ((index = haystack.indexOf(needle, index)) != -1) {
      count++;
      index += needle.length;
    }
    return count;
  }
}
