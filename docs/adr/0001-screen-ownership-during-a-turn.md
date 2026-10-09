# Screen ownership during a turn

While a turn streams, the terminal had exactly one owner: the model's output. `StatusBar.render`
ran once per prompt so the bar scrolled away, the submitted prompt was buried under the reply, and
the only keys wired during streaming were Esc and Ctrl+C — so there was nowhere to type, and a
paste auto-sent because input is read one key at a time with no bracketed-paste handling. We
decided the model rather than the six symptoms: **the stream owns the screen while the model is
speaking; the human owns it while a tool is running**, and the human's text becomes a *queued
message* delivered whole when the turn ends.

Rejected: a reserved prompt area with a repaint loop. It answers "my input disappears under the
output" more completely, but a repaint loop is the first step toward the full-screen TUI the map
rules out of scope, and it would have to coexist with the transcript's scrollback ownership.
Rejected: mid-turn steering (injecting typed text into the running conversation). It changes what
the model is shown mid-request, collides with the transcript's ordering and compaction, and is
indistinguishable from an interrupt on the keys we already own.

## Consequences

Ownership flipping per iteration means the ambient line is drawn only at row boundaries, and is
suspended rather than repainted whenever the stream is mid-line — a partially-written line leaves
the row hidden instead of painted over text. That is what keeps this a streaming CLI rather than a
TUI. The single-slot queue is deliberate: a second message composes into the first rather than
displacing it, so no composed text is ever lost. Bracketed paste becomes a hard prerequisite for
typing during a turn, not a nicety — without it, every multi-line paste is an accidental send.

Two consequences the design tickets did not have to face, found while building:

**The ambient line has no idle row.** Issue 22 prototyped an idle frame, but the prototype had no
live prompt under it. In scrollback-only mode the prompt owns every row below the transcript, and
its repaint clears to the bottom of the screen, so a row pinned beneath the prompt would be erased
on each keystroke and redrawn after — the repaint loop this decision rules out. The line therefore
exists only while a turn is running or was just interrupted. The reading an idle human needs, the
context gauge and the compaction threshold, moves into the dock as a snapshot, which is what a dock
is for: it names the state of the window the next exchange is about to be written into.

**The window closes on a chunk boundary, not a timer.** A lone Escape press and an Alt chord are
the same bytes, told apart only by timing. The decoder treats an Escape that ends a read chunk as
the interrupt, and an Alt chord that arrives whole as a chord, which favours losing one stray
character over swallowing the interrupt. Issue 25 owns replacing that with an escape timeout.
