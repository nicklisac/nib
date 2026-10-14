# Streams compose, buffers don't

**Status:** accepted (implementation pending; decision unifies #23 single-input-owner and #25 KeyDecoder corruption)

Manual byte and line buffering across asynchronous boundaries — escape-sequence decoding in
`terminal_manager.dart`/`prompt_reader.dart`, SSE chunk assembly in `event_stream.dart`, subprocess
stdio framing — forces imperative state machines into UI and provider classes, and corrupts state
when chunks split mid-sequence or multiple listeners contend for one raw stream (#23, #25). We
decided: **every byte-to-frame and frame-to-event boundary in Nib is a composable, single-owner
`StreamTransformer<S, T>` stage, never an ad-hoc accumulator.**

1. **Terminal input:** one subscription owns raw `stdin`, piped through a stateful
   `KeySequenceTransformer` (escape-code timeouts, bracketed-paste framing) emitting typed
   `KeyEvent`s.
2. **LLM SSE:** `utf8.decoder` → `LineSplitter` → `SseFrameTransformer` → provider delta assembler.
3. **Sidecar/subprocess stdio:** newline-delimited JSON transformer pipelines.

## Consequences

Framing logic becomes pure `StreamTransformer` classes, unit-testable with synthetic chunk splits —
no TTY or HTTP mocks, which is exactly the infrastructure the feel-doctrine tests (#13) were missing.
Speculative `Isolate.run` and `dart:ffi` offloads are explicitly **not** part of this decision; they
remain gated behind demonstrated need in the itch log.