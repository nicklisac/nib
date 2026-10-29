import 'dart:async';

import '../agent/check_runner.dart';
import '../agent/tool.dart';

/// Returns the current project-check verdict without the model having to run
/// the check command through bash (#54). Rules, in order:
///
/// - Mutations already recorded in the current bundle: run the check now and
///   wait (the background schedule only fires at bundle close, so answering
///   from cache here would be stale on the edits being asked about).
/// - A check is in flight: await it.
/// - A completed verdict covers the current state: return it as-is. This is
///   the cache hit that replaces the model's own blocking bash call.
/// - Otherwise: start a run and await it.
class CheckStatusTool extends AgentTool {
  static const String toolName = 'check_status';

  final CheckController controller;

  CheckStatusTool(this.controller);

  @override
  String get name => toolName;

  @override
  String get description =>
      'Return the current status of the project check (the configured '
      'check command). Waits if a check is running, returns the cached '
      'verdict if nothing changed since it ran, and runs the check now if '
      'you edited files in this step. Prefer this over running the check '
      'command through bash: it avoids duplicate work and build-lock '
      'collisions. A clean verdict means the configured command passed, '
      'not that the code is correct.';

  @override
  Map<String, dynamic> get parameters => const {
    'type': 'object',
    'properties': {},
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments) async {
    final s = controller.settings;
    if (!controller.isActive || s == null) {
      return const ToolResult.text(
        '[check not run: experiment enabled but no check.command configured '
        'for this project]',
      );
    }

    CheckVerdict? verdict;
    if (controller.bundleHasMutations || controller.lastCompleted == null) {
      // Fresh state (or first ever run): the verdict must describe it.
      verdict = await controller.start();
    } else {
      final inflight = controller.inFlight;
      if (inflight != null) {
        verdict = await inflight;
      }
      verdict ??= controller.lastCompleted;
      if (verdict == null || _isStale(verdict)) {
        verdict = await controller.start();
      }
    }

    // Superseded by newer edits while waiting: run once more on the newest
    // state rather than reporting nothing.
    verdict ??= await controller.start();
    if (verdict == null) {
      return const ToolResult.text('[check not run: cancelled]');
    }
    final changed = controller.changedPathsSince(verdict.seq);
    final stale = changed.isEmpty
        ? ''
        : '\n[stale: as of the state after that check; ${changed.length} '
              'file${changed.length == 1 ? '' : 's'} changed since]';
    return ToolResult.text('${verdict.transcriptText}$stale');
  }

  bool _isStale(CheckVerdict v) =>
      controller.changedPathsSince(v.seq).isNotEmpty;

  @override
  void cancel() {}
}
