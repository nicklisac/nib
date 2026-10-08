import 'dart:io';

/// ANSI escape codes and terminal styling utilities.
class Ansi {
  static bool get isSupported => stdout.hasTerminal;

  // Formatting
  static const reset = '\x1B[0m';
  static const bold = '\x1B[1m';
  static const dim = '\x1B[2m';
  static const italic = '\x1B[3m';
  static const underline = '\x1B[4m';

  // Foreground Colors
  static const black = '\x1B[30m';
  static const red = '\x1B[31m';
  static const green = '\x1B[32m';
  static const yellow = '\x1B[33m';
  static const blue = '\x1B[34m';
  static const magenta = '\x1B[35m';
  static const cyan = '\x1B[36m';
  static const white = '\x1B[37m';
  static const gray = '\x1B[90m';
  static const brightCyan = '\x1B[96m';
  static const brightMagenta = '\x1B[95m';

  // Clean styled wrappers
  static String style(String text, String code) =>
      isSupported ? '$code$text$reset' : text;

  static String boldText(String text) => style(text, bold);
  static String dimText(String text) => style(text, dim);
  static String cyanText(String text) => style(text, cyan);
  static String brightCyanText(String text) => style(text, brightCyan);
  static String magentaText(String text) => style(text, magenta);
  static String greenText(String text) => style(text, green);
  static String yellowText(String text) => style(text, yellow);
  static String redText(String text) => style(text, red);
  static String grayText(String text) => style(text, gray);

  /// Minimal Pi & Tau inspired banner for Nib
  static String banner({required String model, required String provider, required String workspace}) {
    final buf = StringBuffer();
    buf.writeln();
    buf.writeln('${boldText(brightCyanText('  ✒   NIB'))} ${dimText('· Dart Terminal Coding Agent (in the style of Pi & Tau)')}');
    buf.writeln('  ${dimText('model:')} ${boldText(cyanText(model))} ${dimText('· provider:')} ${yellowText(provider)}');
    buf.writeln('  ${dimText('workspace:')} ${grayText(workspace)}');
    buf.writeln('  ${dimText('type')} ${boldText('/help')} ${dimText('for slash commands, or ask anything to start.')}');
    buf.writeln(dimText('  ─────────────────────────────────────────────────────────────────'));
    return buf.toString();
  }
}
