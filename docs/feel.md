# Feel doctrine

The non-negotiables a Nib feature must not violate. The [itch log](https://github.com/nicklisac/nib/issues/19)
is the evidence that they are being broken; this file is the rule they are judged against.

*Feel* is how Nib behaves in flow — latency, interruption, not losing your place, output legible at a
glance. It is never a synonym for cosmetics.

## The rules

**1. Nib never writes to a row it does not own.**
The stream owns the screen while the model is speaking; the human owns it while a tool is running.
Ownership flips per iteration, not per turn. Nothing else may position the cursor or repaint.
Decided in [nicklisac/nib#20](https://github.com/nicklisac/nib/issues/20), `docs/adr/0001`.

**2. Nib never discards what the human has typed.**
A draft survives an interrupt, a cancelled turn, and an approval prompt. Input that has been composed
but not submitted is the human's, and no redraw is allowed to eat it.

**3. Nib never sends what you did not mean as Enter.**
A paste is a paste. Bracketed paste mode is a prerequisite for typing during a turn, not a nicety —
without it every multi-line paste is an accidental send with no undo.

**4. Nib never shows an estimate as a measurement.**
An estimated number carries a `~`. Measured and estimated are never blended into one figure, and an
estimate is never formatted to look authoritative.

**5. Nib never silently shrinks the transcript.**
Auto-compaction is announced when it fires, and its threshold is visible before it does. Losing your
place begins with the transcript changing underneath you.

**6. Nib fails loudly rather than defaulting to something wrong.**
Missing config produces an error naming the exact fix. A synthesised provider, a borrowed model name,
or a guessed endpoint is a confident wrong number with extra steps.

**7. A gesture has one meaning.**
Esc and Ctrl+C stop the turn and nothing else. Composed text is never an interrupt, and an interrupt
never double-fires through two paths.

**8. The latency you feel is time-to-first-token.**
Nothing else in a streaming CLI is perceived as speed. Optimise the first token, then the gaps
between them; everything after that is a rounding error in the felt experience.

## What doctrine cannot do

These rules catch mistakes of *class* — a row written that was not owned, a draft discarded, an
estimate presented as fact. They will not catch a table that reads badly or a spinner that flickers,
and stretching them to cover taste turns doctrine into a style guide nobody reads.

Anything that is not a class-of-failure is an itch. Capture it on the log, drain it while the hood is
already up on the same area.

## Enforcement

What can be checked mechanically rather than by reading is [nicklisac/nib#13](https://github.com/nicklisac/nib/issues/13).