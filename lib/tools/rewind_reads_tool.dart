import '../agent/tool.dart';

/// Tool allowing the model to replace the immediately preceding read-only tool
/// turn's result(s) with a concise note, keeping dead-end or scaffolding blobs
/// out of the long-lived context prefix (#53).
class RewindReadsTool extends AgentTool {
  static const String toolName = 'rewind_reads';

  /// Minimum combined character count across the previous turn's tool results
  /// required before a rewind is worth the extra round-trip.
  final int minChars;

  RewindReadsTool({this.minChars = 1000});

  @override
  String get name => toolName;

  @override
  int get minRewindChars => minChars;

  @override
  String get description =>
      'Rewind the immediately preceding read-only tool turn (read_file, '
      'search_files, list_dir, web_fetch, web_search, skill) and replace its '
      'raw tool result(s) in-place with a short note. The rewind_reads call '
      'itself is erased from the transcript so the prefix up to the original '
      'tool call stays intact.\n\n'
      'Rules:\n'
      '- Call rewind_reads as the SOLE tool call in your turn.\n'
      '- Only use when the previous turn executed exclusively read-only tools '
      'whose combined output is at least $minChars characters.\n'
      '- Note discipline: state concrete facts learned, what was ruled out, '
      'and where to look next (e.g. "100 matches all in build/archive dirs; '
      'no source hits — inspect lib/agent/ directly", or key facts extracted '
      'from a loaded skill/doc). Never write vague notes like "nothing useful".';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'note': {
        'type': 'string',
        'description':
            'Concise replacement note stating what was learned from the '
            'previous read-only tool output, what is ruled out, and what to '
            'pursue next.',
      },
    },
    'required': ['note'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final note = (arguments['note'] as String?)?.trim() ?? '';
    if (note.isEmpty) {
      return const ToolResult.text(
        'Refused rewind_reads: "note" argument is required and must state what was learned.',
      );
    }
    return ToolResult.text(
      'Refused rewind_reads: rewind_reads must be executed by the agent harness as the sole tool call immediately following a read-only tool turn.',
    );
  }
}
