import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../agent/approval_manager.dart';
import '../agent/tool.dart';

/// Tool for executing bash shell commands.
class BashTool extends AgentTool {
  final String workingDirectory;

  BashTool({String? workingDirectory})
      : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  String get name => 'bash';

  @override
  String get description =>
      'Execute a shell command in the workspace directory. Use this to run tests, inspect git status, build code, or run CLI tools.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'The bash command line string to execute.',
          },
          'timeout_seconds': {
            'type': 'integer',
            'description': 'Optional execution timeout in seconds (default: 60).',
          },
        },
        'required': ['command'],
      };

  @override
  Future<String> execute(Map<String, dynamic> arguments) async {
    final command = arguments['command'] as String?;
    if (command == null || command.trim().isEmpty) {
      return 'Error: No command provided';
    }

    final timeoutSeconds = (arguments['timeout_seconds'] as num?)?.toInt() ?? 60;

    final approved = await ApprovalManager.instance.confirmBashCommand(command);
    if (!approved) {
      return 'Command cancelled by user: "$command"';
    }

    try {
      final result = await Process.run(
        'bash',
        ['-c', command],
        workingDirectory: workingDirectory,
        runInShell: true,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () => ProcessResult(
          -1,
          -1,
          '',
          '[Command timed out after $timeoutSeconds seconds]',
        ),
      );

      final out = result.stdout.toString();
      final err = result.stderr.toString();
      final exitCode = result.exitCode;

      final buffer = StringBuffer();

      if (out.isNotEmpty) {
        buffer.write(out);
      }
      if (err.isNotEmpty) {
        if (out.isNotEmpty && !out.endsWith('\n')) buffer.writeln();
        buffer.writeln('[stderr]:');
        buffer.write(err);
      }

      if (out.isEmpty && err.isEmpty) {
        buffer.writeln('[Command executed with exit code $exitCode and produced no output]');
      }

      // Truncate if gigantic (e.g. over 100k characters)
      final fullOutput = buffer.toString();
      const maxLen = 30000;
      if (fullOutput.length > maxLen) {
        return '${fullOutput.substring(0, maxLen)}\n\n...[Output truncated: ${fullOutput.length - maxLen} additional characters omitted]';
      }

      return fullOutput;
    } catch (e) {
      return 'Error executing command: $e';
    }
  }
}
