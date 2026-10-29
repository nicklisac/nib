# Nib

A minimalist terminal CLI coding agent written entirely in Dart, inspired by Pi and Tau.
Nib is a pure terminal streaming CLI (not a full-screen TUI): ANSI formatting, live token
streaming, interactive tool execution blocks, persistent shell history, context
compaction, and multi-language syntax highlighting.

## Build, test, and run

```bash
dart pub get          # install dependencies
dart analyze          # static analysis (CI uses --fatal-infos)
dart test             # unit tests
dart format .         # formatting (CI fails on any unformatted file)

./nib                 # run (auto-compiles a kernel snapshot, then launches in ~0.07s)
./nib --mock          # offline demo mode, no API keys
./nib --mock "prompt" # one-shot prompt
```

`./nib` caches a kernel snapshot at `.dart_tool/nib.snapshot` and rebuilds it when any
file under `bin/` or `lib/`, or `pubspec.yaml`/`pubspec.lock`, is newer. Use `dart run
bin/nib.dart` to bypass the cache (it recompiles from source every launch, ~3.6s).

Run a single test file: `dart test test/agent_test.dart`. Filter by name:
`dart test -n "compaction"`.

## Architecture

Four layers, and the dependency direction matters: `ui` depends on `agent`, `agent`
depends on `ai` and `tools`, and `agent` never imports `ui`.

- `lib/ai/` — provider layer. `provider.dart` defines the `LLMProvider` streaming
  interface; `openai_provider.dart` and `anthropic_provider.dart` implement it, and
  `mock_provider.dart` provides a scripted offline provider used by the tests.
  `event_stream.dart` defines the streaming events (`TextDeltaEvent`,
  `ThoughtDeltaEvent`, `ToolCallCompleteEvent`, `DoneEvent`, `ErrorEvent`).
- `lib/agent/` — the harness, independent of any UI. `agent.dart` holds the core loop
  (stream → parse tool calls → execute → repeat). `session.dart` owns the transcript,
  token accounting, and `~/.nib/sessions/` persistence. Also `compaction.dart`,
  `config.dart`, `undo_manager.dart`, `approval_manager.dart`, `skills.dart`.
- `lib/tools/` — one file per tool, each subclassing `AgentTool` from
  `agent/tool.dart`. Tools are registered as a list in `bin/nib.dart`.
- `lib/ui/` — terminal presentation: streaming CLI, readline history, autocomplete,
  markdown/syntax rendering, themes, status bar, slash commands.

To add a tool: subclass `AgentTool` in `lib/tools/`, implement `name`, `description`,
`parameters` (JSON Schema), and `execute`, then add it to the `tools` list in
`bin/nib.dart`.

## Conventions

- Every tool guards its paths: writes and reads outside the workspace root are
  rejected. Keep that invariant in any new file-touching tool.
- Tool output is capped at `Agent.maxToolOutputChars` before it enters the transcript.
- The tool loop is intentionally unbounded by default (`max_turns: 0` in
  `~/.nib/config.json`). The real guard is `max_stuck_iterations` (default `5`), which
  trips only once the same tool calls have returned byte-identical results more times
  than that within one prompt, so legitimate polling is never interrupted.
  `hard_iteration_cap` (default `200`) backstops a misbehaving provider. All three are
  read from config, per provider if set there, so never hardcode a ceiling or
  reintroduce a fixed low cap like the old 20-iteration limit.
- Skills are lazy: the system prompt carries only a name and description index, and the
  model pulls a skill body through the `skill` tool. Do not inject skill bodies into the
  system prompt.
- Skills are discovered only from `.nib/skills/` (workspace) and `~/.nib/skills/`
  (global). Skill directories belonging to other agent harnesses are deliberately not
  scanned.
- Feel is a requirement, not polish. The non-negotiables a feature must not violate live in
  [`docs/feel.md`](docs/feel.md); read it before building UI or input behaviour, and cite the rule
  number when a change touches one.
- CI (`.github/workflows/ci.yml`) runs `dart format --set-exit-if-changed`,
  `dart analyze --fatal-infos`, and `dart test`. All three must pass.
- When the user mentions something that bugs them in passing — a UI or QoL irritation,
  a rough edge, "this flickers", "this is annoying" — append a one-line entry to the
  [itch log](https://github.com/nicklisac/nib/issues/19) (`gh issue edit 19 --body-file`),
  then carry on with what they actually asked for. Capture without asking and without
  triaging; the log is visible on the tracker, which is what gets it read.
- Before proposing a new experiment — a bet about agent behaviour gated behind `/experiments` — read
  the [experiment ledger](https://github.com/nicklisac/nib/issues/55) and add a row at the `idea`
  state, with its deciding number, before writing code. Experiments that touch `lib/` also get their
  own issue; a prompt tweak or config default is a row plus the commit. An experiment that reaches no
  measurement by the time that area of `lib/` is next touched is deleted, with a line saying so.

## Agent skills

### Issue tracker

Issues and specs for this repo live as GitHub issues on `nicklisac/nib`; the `gh` CLI
is the interface. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout: `CONTEXT.md` at the repo root plus `docs/adr/`. Both are created
lazily by the domain-modeling skill when terms actually get resolved. See
`docs/agents/domain.md`.

### Wayfinder maps

One active map: [nicklisac/nib#1 — Wayfinder map: Nib daily-driver parity](https://github.com/nicklisac/nib/issues/1),
labelled `wayfinder:map`. Its destination: Nib becomes the daily driver in place of Tau, with
nothing unnecessary. Planning phase only so far — tickets resolve decisions, they do not build.

The map is an index, not a store: it gists each decision and links to the ticket that holds it.
Read the map body before picking a ticket, and never restate a ticket's detail back into the map.
Open tickets are its child issues, found by query; `docs/agents/issue-tracker.md` covers the
tracker conventions (sub-issues, native blocking, claim-by-assignee).
