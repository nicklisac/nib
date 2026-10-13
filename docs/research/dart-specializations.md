# Dart specializations for Nib

Ideas for leaning into Dart-specific language and runtime features that the Python (tau) and
TypeScript/pi competitors structurally can't match. Brainstorm from the agy Flash 3.8 review of
this codebase (Oct 2026) plus follow-up triage. Ranked by payoff. Not a commitment list.

## Do these

### 1. Stream backpressure via `StreamSubscription.pause()`

The cheapest real win. During an approval prompt or a slow render, pause `_activeStreamSub`
(`lib/agent/agent.dart`) instead of buffering tokens in userland. In Dart the pause propagates
through the SSE stream down to the TCP receive window - the provider's own stack throttles at the
OS level and app memory stays flat. pi buffers in userland; tau has no clean equivalent.
Roughly a day of work, and it's a correctness win under pressure, not a micro-optimization.

### 2. Isolate pool for the three event-loop blockers

Nib is 100% single-isolate today. Three synchronous hotspots stall the loop (violates feel rule 8,
time-to-first-token):

- Myers diff in `diff_formatter.dart` on thousand-line files
- `search_files_tool.dart` walking directories with regexes
- markdown/highlight parsing while the human is mid-typing

Fix: one shared isolate group for these three, `Isolate.exit()` for zero-copy transfer of the big
strings back. This is the jank-killer. Read-only work only - see "Don't do these" for why
speculative agents don't qualify.

### 3. Extension types for tool args

Tools do `arguments['command'] as String?` casts on raw `Map<String, dynamic>` everywhere.
`extension type BashArgs(Map<String, dynamic> _)` gives compile-time typed access with zero
allocation - no wrapper class, no runtime validation churn per token event. zod and pydantic both
pay allocation costs. Slow-burn refactor; adopt per-tool as each gets touched.

## Maybe

### 4. Sealed classes for screen states

`cli_ui.dart` juggles boolean flags (`_inThoughtBlock`, `_turnInterrupted`) where exhaustive
pattern matching would make screen-ownership bugs unrepresentable. Pairs with ADR-0001. Worth it
when the UI layer next gets a real change, not as a standalone sweep.

### 5. tree-sitter via FFI

The edit tool is substring-matching and val_highlight is regex-based; AST-level edit validation
would be strictly better. But there's no maintained pub.dev binding, so this is FFI-wrapping C -
real cost, defer until highlighting/editing is actually a felt problem.

## Don't do these

- **Hot reload for the CLI.** `dart compile exe` structurally can't. The party trick is off the
  table for production nib.
- **Speculative parallel agents.** Stateful tool runs (shell, disk writes) need workspace
  snapshotting that eats the payoff. Isolates pay off for read-only work only (idea 2).
- **RxDart.** dart:async streams are already the right primitive; the library adds indirection.
- **FFI custom allocators.** Not Nib's bottleneck.

## Context

The strategic frame (see session history / tau & pi comparisons): Nib is Tau-shaped, not
Pi-shaped - a fast single-binary agent you modify by editing the source, because hot-loaded
extensions are welded to Node. These specializations sharpen the single-binary fast-core pitch;
none of them try to buy back the self-extension trick.