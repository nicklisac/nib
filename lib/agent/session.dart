import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../ai/chat_message.dart';

/// Manages the conversation transcript, system prompt, persistence, and turns.
class AgentSession {
  final String id;
  String systemPrompt;
  final List<ChatMessage> _messages = [];
  int totalPromptTokens = 0;
  int totalCompletionTokens = 0;
  int toolExecutionsCount = 0;

  AgentSession({
    String? id,
    String? systemPrompt,
  })  : id = id ?? 'session_${DateTime.now().millisecondsSinceEpoch}',
        systemPrompt = systemPrompt ?? _defaultSystemPrompt;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  void addMessage(ChatMessage message) {
    _messages.add(message);
  }

  void addSystemPromptIfNeeded() {
    if (_messages.isEmpty || _messages.first.role != Role.system) {
      _messages.insert(0, ChatMessage.system(systemPrompt));
    } else {
      _messages[0] = ChatMessage.system(systemPrompt);
    }
  }

  void clearMessages() {
    _messages.clear();
  }

  void clearHistory() {
    _messages.clear();
    addSystemPromptIfNeeded();
  }

  void recordUsage(int? promptTokens, int? completionTokens) {
    if (promptTokens != null) totalPromptTokens += promptTokens;
    if (completionTokens != null) totalCompletionTokens += completionTokens;
  }

  /// Automatically persists session transcript to ~/.nib/sessions/<id>.jsonl
  Future<void> saveToDisk() async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;

      final sessionDir = Directory(p.join(home, '.nib', 'sessions'));
      if (!await sessionDir.exists()) {
        await sessionDir.create(recursive: true);
      }

      final file = File(p.join(sessionDir.path, '$id.jsonl'));
      final sink = file.openWrite();

      // Write metadata header
      sink.writeln(jsonEncode({
        '_type': 'meta',
        'id': id,
        'system_prompt': systemPrompt,
        'prompt_tokens': totalPromptTokens,
        'completion_tokens': totalCompletionTokens,
        'tool_executions': toolExecutionsCount,
        'timestamp': DateTime.now().toIso8601String(),
      }));

      // Write messages
      for (final msg in _messages) {
        sink.writeln(jsonEncode(msg.toJson()));
      }

      await sink.flush();
      await sink.close();
    } catch (_) {}
  }

  /// Loads a session from disk by its ID (checking ~/.nib/sessions/ then ~/.tart/sessions/).
  static Future<AgentSession?> loadFromDisk(String id) async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return null;

      var file = File(p.join(home, '.nib', 'sessions', '$id.jsonl'));
      if (!await file.exists()) {
        file = File(p.join(home, '.tart', 'sessions', '$id.jsonl'));
        if (!await file.exists()) return null;
      }

      final lines = await file.readAsLines();
      if (lines.isEmpty) return null;

      AgentSession? session;

      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final json = jsonDecode(line) as Map<String, dynamic>;

        if (json['_type'] == 'meta') {
          session = AgentSession(
            id: json['id'] as String?,
            systemPrompt: json['system_prompt'] as String?,
          );
          session.totalPromptTokens = json['prompt_tokens'] as int? ?? 0;
          session.totalCompletionTokens = json['completion_tokens'] as int? ?? 0;
          session.toolExecutionsCount = json['tool_executions'] as int? ?? 0;
        } else if (session != null) {
          session.addMessage(ChatMessage.fromJson(json));
        }
      }

      return session;
    } catch (_) {
      return null;
    }
  }

  /// Returns the most recent session ID from ~/.nib/sessions/ (or ~/.tart/sessions/)
  static Future<String?> getMostRecentSessionId() async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return null;

      final dirs = [
        Directory(p.join(home, '.nib', 'sessions')),
        Directory(p.join(home, '.tart', 'sessions')),
      ];

      final files = <File>[];
      for (final sessionDir in dirs) {
        if (await sessionDir.exists()) {
          final entities = await sessionDir.list().toList();
          files.addAll(entities.whereType<File>().where((f) => f.path.endsWith('.jsonl')));
        }
      }
      if (files.isEmpty) return null;

      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      final mostRecent = files.first;
      return p.basenameWithoutExtension(mostRecent.path);
    } catch (_) {
      return null;
    }
  }

  /// Lists saved sessions with their date, turn count, and last prompt.
  static Future<List<Map<String, dynamic>>> listSavedSessions() async {
    final list = <Map<String, dynamic>>[];
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return list;

      final dirs = [
        Directory(p.join(home, '.nib', 'sessions')),
        Directory(p.join(home, '.tart', 'sessions')),
      ];

      final seenIds = <String>{};
      final files = <File>[];

      for (final dir in dirs) {
        if (await dir.exists()) {
          final entities = await dir.list().where((e) => e is File && e.path.endsWith('.jsonl')).toList();
          for (final e in entities) {
            final f = e as File;
            final id = p.basenameWithoutExtension(f.path);
            if (seenIds.add(id)) {
              files.add(f);
            }
          }
        }
      }

      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

      for (final f in files.take(10)) {
        final id = p.basenameWithoutExtension(f.path);
        final lines = await f.readAsLines();
        String summary = '';
        int messageCount = 0;
        for (final line in lines) {
          try {
            final parsed = jsonDecode(line) as Map<String, dynamic>;
            if (parsed['role'] == 'user') {
              summary = (parsed['content'] as String? ?? '').replaceAll('\n', ' ');
              messageCount++;
            }
          } catch (_) {}
        }
        list.add({
          'id': id,
          'modified': f.statSync().modified,
          'user_turns': messageCount,
          'last_prompt': summary.length > 50 ? '${summary.substring(0, 47)}...' : summary,
        });
      }
    } catch (_) {}
    return list;
  }

  static const String _defaultSystemPrompt = '''
You are Nib, an expert proactive coding assistant running directly inside the user's terminal CLI.
You are built in the minimalist and capable philosophy of Pi and Tau.

You have access to tools to interact directly with the user's local project workspace:
- bash: Run commands, tests, git operations, and inspect terminal output.
- read_file: Read files with exact line numbers.
- write_file: Create new files or overwrite existing files.
- edit_file: Perform precise, surgical search-and-replace edits.
- list_dir: Explore folders and discover project structure.
- search_files: Search code across files.

Guidelines:
1. Always inspect files or directory layout before making blind changes.
2. When modifying existing files, prefer edit_file for surgical edits.
3. Verify changes when appropriate (e.g. run tests or check git diff using bash).
4. Be concise, direct, and actionable in your explanations.
''';
}
