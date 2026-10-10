import 'dart:io';

import 'screen_coordinator.dart';

/// Where UI output that belongs to the transcript goes, and how a block that
/// repaints itself in place gives its rows back.
///
/// Slash commands and the session picker used to write straight to stdout.
/// With the footer pinned, the raw cursor sits in the footer, so those writes
/// landed on the prompt row and the next prompt repaint erased them — /history
/// rendered into invisibility. Routing through this interface means output
/// enters the DECSTBM region at the coordinator's tracked row when one is
/// active, and appends normally when one is not.
abstract class TranscriptWriter {
  /// Writes one line of transcript output, newline included.
  void writeLine(String line);

  /// Gives back the last [rows] rows of transcript output so a fixed-height
  /// block — a menu — can rewrite them. Rows that already scrolled out of the
  /// region are beyond reach and stay as they are.
  void rewind(int rows);
}

/// Appends to stdout and rewinds with relative cursor movement: the behaviour
/// from before rows were pinned, correct whenever no coordinator owns the
/// screen.
class StdoutTranscriptWriter implements TranscriptWriter {
  const StdoutTranscriptWriter();

  @override
  void writeLine(String line) => stdout.writeln(line);

  @override
  void rewind(int rows) {
    stdout.write('\x1B[${rows}A');
    stdout.write('\r\x1B[J');
  }
}

/// Chooses the writer for the current screen: the coordinator while it owns
/// the terminal, stdout otherwise. Tests that construct handlers directly get
/// the stdout writer and keep printing into the test runner's sink.
TranscriptWriter resolveTranscriptWriter(TranscriptWriter? writer) {
  if (writer != null) return writer;
  final coord = ScreenCoordinator.instance;
  return coord.isActive ? coord : const StdoutTranscriptWriter();
}
