import 'dart:async';
import 'dart:io';
import 'theme.dart';

/// Smooth terminal animated spinner for live thinking, tool execution, and token speed tracking.
class TerminalSpinner {
  static const List<String> _frames = [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  String _message = '';
  Timer? _timer;
  int _frameIndex = 0;
  final Stopwatch _stopwatch = Stopwatch();
  int _tokenCount = 0;
  bool _isActive = false;

  bool get isActive => _isActive;

  void start(String message) {
    if (!stdout.hasTerminal) return;
    _message = message;
    _stopwatch.reset();
    _stopwatch.start();
    _tokenCount = 0;
    _isActive = true;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 75), (_) {
      _render();
    });
    _render();
  }

  void updateMessage(String message) {
    _message = message;
    if (_isActive) _render();
  }

  void recordToken() {
    _tokenCount++;
  }

  void stop() {
    if (!_isActive) return;
    _isActive = false;
    _timer?.cancel();
    _timer = null;
    _stopwatch.stop();
    _clearLine();
  }

  void success(String finalMessage) {
    stop();
    final ms = _stopwatch.elapsedMilliseconds;
    final theme = NibTheme.current;
    stdout.writeln(
      '  ${theme.success.text('✔')} $finalMessage ${theme.muted.text('(${ms}ms)')}',
    );
  }

  void failure(String finalMessage) {
    stop();
    final theme = NibTheme.current;
    stdout.writeln('  ${theme.error.text('✖')} $finalMessage');
  }

  void _render() {
    if (!_isActive) return;
    _frameIndex = (_frameIndex + 1) % _frames.length;
    final frame = _frames[_frameIndex];
    final theme = NibTheme.current;

    final elapsed = _formatDuration(_stopwatch.elapsed);
    String rateInfo = '';
    if (_tokenCount > 2) {
      final seconds = _stopwatch.elapsedMilliseconds / 1000.0;
      if (seconds > 0.1) {
        final tps = (_tokenCount / seconds).toStringAsFixed(1);
        rateInfo = ' ${theme.accent.text('$tps tok/s')}';
      }
    }

    final line =
        '  ${theme.warning.text(frame)} $_message ${theme.muted.text('[$elapsed]')}$rateInfo';
    stdout.write('\r\x1B[2K$line');
  }

  void _clearLine() {
    if (stdout.hasTerminal) {
      stdout.write('\r\x1B[2K');
    }
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 1) {
      return '${d.inMilliseconds}ms';
    } else {
      return '${(d.inMilliseconds / 1000.0).toStringAsFixed(1)}s';
    }
  }
}
