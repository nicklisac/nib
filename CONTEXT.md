# Nib

A personal terminal coding agent: pure Dart, streaming CLI rather than a full-screen TUI,
dogfooded by its own author as the place he does his day-to-day coding.

## Language

**Itch**:
A single observed instance of friction while using Nib — one place, one moment, reported in
passing. Raw evidence, not a request.
_Avoid_: bug report, complaint, nice-to-have

**Itch log**:
The standing list of itches, drained in batches whenever work already reaches the area an itch
lives in. Never triaged at capture time.
_Avoid_: feel log, backlog, honeyhole

**Feel**:
How Nib behaves in flow — latency, interruption, not losing your place, output legible at a
glance. Never a synonym for cosmetics.
_Avoid_: polish, UX, aesthetics

**Feel doctrine**:
The written non-negotiables a feature must not violate. The rules; the itch log is the evidence
they are judged against.
_Avoid_: style guide, guidelines

**Screen ownership**:
Who may write to the terminal at a given moment — the stream or the human. Handed over at a
single boundary: the stream owns the screen while the model is speaking, the human owns it while
a tool is running.
_Avoid_: focus, control, cursor position

**Turn**:
One submitted prompt and everything that happens before control returns to the human — every
iteration, tool call, and streamed line within it.
_Avoid_: response, reply, request

**Iteration**:
One round trip with the model inside a turn. A turn is many iterations; ownership flips per
iteration, not per turn.

**Interrupt**:
The human's gesture that stops a turn — Esc or Ctrl+C, and nothing else. Composed text is never
an interrupt, and an interrupt never discards a draft.
_Avoid_: cancel, abort, break

**Queued message**:
Text composed during a turn and delivered whole when that turn ends. Never injected mid-turn;
never merged into the conversation as an assistant statement.
_Avoid_: steering, interjection, mid-turn injection

**Draft**:
Text the human has typed but not submitted. Survives an interrupt, survives a cancelled turn, and
is never sent by a keystroke the human did not mean as Enter.

**Ambient line**:
The one line at the bottom of the screen that carries state while the human is not typing.
Redrawn in place; never scrolled into history.
_Avoid_: status bar, footer, HUD, statusline

**Dock**:
The badge block naming provider, model, and workspace, printed once with the prompt and left to
scroll away. Distinct from the ambient line: the dock is history, the ambient line is present tense.
_Avoid_: status bar, header

**Context gauge**:
How much of the model's window the next request would occupy — the reading a human acts on, by
compacting or starting over.
_Avoid_: token count, usage, context length

**Tokens spent**:
Tokens billed across the session, counted after the fact. Reported, but not what a human decides
with; never dressed up as a context gauge.
_Avoid_: context usage, remaining context