import 'dart:io';
import '../ui/diff_formatter.dart';

class FileSnapshot {
  final String path;
  final String contentBefore;
  final String contentAfter;
  final DateTime timestamp;

  FileSnapshot({
    required this.path,
    required this.contentBefore,
    required this.contentAfter,
  }) : timestamp = DateTime.now();
}

/// Tracks file edits and handles one-click /undo operations.
class UndoManager {
  static final UndoManager instance = UndoManager._();
  UndoManager._();

  final List<FileSnapshot> _history = [];

  void recordEdit({
    required String path,
    required String contentBefore,
    required String contentAfter,
  }) {
    _history.add(
      FileSnapshot(
        path: path,
        contentBefore: contentBefore,
        contentAfter: contentAfter,
      ),
    );
  }

  bool get canUndo => _history.isNotEmpty;

  /// Reverts the most recent file change and returns a diff summary.
  Future<String?> undo() async {
    if (_history.isEmpty) return null;

    final snapshot = _history.removeLast();
    final file = File(snapshot.path);

    if (snapshot.contentBefore.isEmpty && await file.exists()) {
      // File was newly created, delete it
      await file.delete();
      return 'Deleted newly created file "${snapshot.path}"';
    } else {
      final currentContent = await file.exists()
          ? await file.readAsString()
          : '';
      await file.writeAsString(snapshot.contentBefore);
      final diff = DiffFormatter.formatSummary(
        snapshot.path,
        currentContent,
        snapshot.contentBefore,
      );
      return 'Reverted "${snapshot.path}":\n$diff';
    }
  }

  int get count => _history.length;
}
