import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../agent/approval_manager.dart';
import '../agent/tool.dart';

/// Tool for executing bash shell commands.
class BashTool extends AgentTool {
  final String workingDirectory;
  Process? _activeProcess;

  Timer? _escalateTimer;

  BashTool({String? workingDirectory})
      : workingDirectory = workingDirectory ?? Directory.current.path;

  @override
  void cancel() {
    try {
      final proc = _activeProcess;
      if (proc != null) {
        proc.kill(ProcessSignal.sigterm);
        _escalateTimer?.cancel();
        _escalateTimer = Timer(const Duration(milliseconds: 500), () {
          try {
            proc.kill(ProcessSignal.sigkill);
          } catch (_) {}
        });
      }
    } catch (_) {}
  }

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
      final process = await Process.start(
        'bash',
        ['-c', command],
        workingDirectory: workingDirectory,
        runInShell: false,
      );
      _activeProcess = process;

      final outBuffer = StringBuffer();
      final errBuffer = StringBuffer();

      final outSub = process.stdout
          .transform(utf8.decoder)
          .listen((chunk) {
            outBuffer.write(chunk);
            if (onProgress != null) {
              final lastLine = chunk.trim().split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
              if (lastLine.isNotEmpty) {
                onProgress!(lastLine);
              }
            }
          });

      final errSub = process.stderr
          .transform(utf8.decoder)
          .listen((chunk) {
            errBuffer.write(chunk);
            if (onProgress != null) {
              final lastLine = chunk.trim().split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
              if (lastLine.isNotEmpty) {
                onProgress!(lastLine);
              }
            }
          });

      bool timedOut = false;
      final timer = Timer(Duration(seconds: timeoutSeconds), () {
        timedOut = true;
        try {
          process.kill(ProcessSignal.sigterm);
          _escalateTimer?.cancel();
          _escalateTimer = Timer(const Duration(seconds: 2), () {
            try {
              process.kill(ProcessSignal.sigkill);
            } catch (_) {}
          });
        } catch (_) {}
      });

      final exitCode = await process.exitCode;
      timer.cancel();
      _escalateTimer?.cancel();
      try {
        await Future.wait([outSub.asFuture(), errSub.asFuture()])
            .timeout(const Duration(milliseconds: 500));
      } catch (_) {}
      _activeProcess = null;

      final out = outBuffer.toString();
      final err = errBuffer.toString();

      if (timedOut) {
        return '[Command timed out after $timeoutSeconds seconds]\n$out\n$err'.trim();
      }

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
      _activeProcess = null;
      return 'Error executing command: $e';
    }
  }
}
