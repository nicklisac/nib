import 'dart:io';
import 'package:test/test.dart';
import 'package:nib/agent/session.dart';
import 'package:nib/agent/undo_manager.dart';
import 'package:nib/tools/edit_file_tool.dart';
import 'package:nib/tools/write_file_tool.dart';
import 'package:nib/ui/diff_formatter.dart';

void main() {
  group('Diff & Undo & Session Persistence Test', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nib_undo_test_');
      AgentSession.storageDirectoryOverride = tempDir.path;
    });

    tearDown(() async {
      AgentSession.storageDirectoryOverride = null;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('DiffFormatter formats additions and deletions with color codes', () {
      final diff = DiffFormatter.formatDiff(
        'line 1\nline 2',
        'line 1\nline two',
      );
      expect(diff, anyElement(contains('line 2')));
      expect(diff, anyElement(contains('line two')));
    });

    test('UndoManager reverts EditFileTool modifications', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final editTool = EditFileTool(workingDirectory: tempDir.path);

      await writeTool.execute({
        'path': 'sample.txt',
        'content': 'Initial text\nKeep this',
      });

      final editRes = await editTool.execute({
        'path': 'sample.txt',
        'target_content': 'Initial text',
        'replacement_content': 'Modified text',
      });

      expect(editRes, contains('Modified text'));
      expect(editRes, contains('+'));

      final current = await File('${tempDir.path}/sample.txt').readAsString();
      expect(current, contains('Modified text'));

      // Undo the modification
      expect(UndoManager.instance.canUndo, isTrue);
      final undoSummary = await UndoManager.instance.undo();
      expect(undoSummary, contains('Reverted'));

      final reverted = await File('${tempDir.path}/sample.txt').readAsString();
      expect(reverted, contains('Initial text'));
      expect(reverted, isNot(contains('Modified text')));
    });

    test('Session saves and restores from disk', () async {
      final session = AgentSession(
        id: 'test_session_${DateTime.now().millisecondsSinceEpoch}',
      );
      session.addSystemPromptIfNeeded();
      session.recordUsage(150, 42);

      await session.saveToDisk();

      final restored = await AgentSession.loadFromDisk(session.id);
      expect(restored, isNotNull);
      expect(restored!.id, equals(session.id));
      expect(restored.totalPromptTokens, equals(150));
      expect(restored.totalCompletionTokens, equals(42));
    });
  });
}
