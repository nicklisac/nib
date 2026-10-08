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

Ownership flipping per iteration means the ambient line is only redrawn outside streaming windows,
which is what keeps this a streaming CLI rather than a TUI. The single-slot queue is deliberate: a
second message composes into the first rather than displacing it, so no composed text is ever lost.
Bracketed paste becomes a hard prerequisite for typing during a turn, not a nicety — without it,
every multi-line paste is an accidental send.