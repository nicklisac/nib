# Research: hook-surface precedent and reverse-request channels

Resolves: [nicklisac/nib#37](https://github.com/nicklisac/nib/issues/37). Feeds the
[Wayfinder Map 2](https://github.com/nicklisac/nib/issues/36) hook-contract, sub-LM bridge,
and telemetry tickets.

## 1. Hook-surface precedent (Claude Code, the most mature CLI harness)

Source: <https://code.claude.com/docs/en/hooks> (fetched 2026-10-13).

**Event cadence, not event count.** ~30 events exist, but they cluster on three cadences:
per-session (`SessionStart`/`SessionEnd`), per-turn (`UserPromptSubmit`, `Stop`), per-tool-call
(`PreToolUse`/`PostToolUse`). The candidate Nib surface (`before_turn`, `after_tool`,
`before_compact`, `after_turn`) maps 1:1 onto the load-bearing ones
(`UserPromptSubmit`, `PostToolUse`, `PreCompact`, `Stop`); the other ~26 are reactive extras
(model switches, file watches, permissions UI) that no named Nib experiment needs. The
precedent says: a harness needs the four, not thirty.

**Wire contract.** Input arrives as JSON on stdin; the handler replies with a JSON decision on
stdout; exit code is the coarse control (exit 2 = block on blocking events; exit 0 with no
output = "no decision", which does *not* approve — silence keeps the normal flow). Post-events
(`PostToolUse`) observe and feed back but cannot block; pre-events (`PreToolUse`,
`UserPromptSubmit`, `PreCompact`, `Stop`) can. That asymmetry — **pre-hooks veto/rewrite,
post-hooks observe/augment** — is the minimal symmetric vocabulary and arrives free by borrowing.

**Mutation rights are per-event, declared by the event, not negotiated.** Each event documents
exactly which output fields it honours (e.g. `permissionDecision: deny` only on `PreToolUse`).
No hook gets "rewrite anything"; the event type is the capability grant. Cheapest possible
security model, and it composes with Nib's existing `approval_manager` (a deny from a hook and
a deny from Nick land in the same place).

**Matcher/filtering lives in config, not in the sidecar.** `matcher` (tool name, regex) and an
optional `if` condition decide *whether the handler spawns at all*, so an idle hook costs zero
process spawns. For Nib's 0.07s/zero-overhead rule this is the shape to copy: subscription
filters evaluated harness-side.

**Multiple handlers per event run and merge**; managed/user/project scopes add hooks rather
than replace them. Ordering is declaration order — precedent does not offer richer arbitration.

## 2. Reverse-request channel (sub-LM / sampling)

**`mcp_dart` 2.4.2 has host-side sampling built in.** Source:
`leehack/mcp_dart` `doc/client-guide.md` + pub.dev README (fetched 2026-10-13). The client
(host) role declares `ClientCapabilitiesSampling` and sets `client.onSamplingRequest`; the
server then sends `sampling/createMessage` *backwards over the same stdio pipe*, and the host
answers with `CreateMessageResult(role, content, model, stopReason)`. Request carries
`messages`, `systemPrompt`, `modelPreferences`, `maxTokens`, `temperature`, `stopSequences`,
`includeContext`. So a Stage-1 sidecar that is a real MCP server gets sub-LM **for free**
through the doorway #16 already opened — no new wire format.

**But a hooks-only pipe is not MCP, and should not pretend to be.** A hook sidecar needs no
tools/resources/prompts, only Nib's own events; wrapping it in an MCP server means dragging
`mcp_dart`'s discovery/handshake machinery (5s stateless probe on stdio, `server/discover`)
into a private two-process pipe. For Nib-defined hooks, a hand-rolled newline-delimited
JSON-RPC responder over ADR-0002's `StreamTransformer` framing is ~100 lines and keeps the
#16 boundary clean: MCP for foreign tools, Nib protocol for Nib events.

**The seam worth stealing:** MCP's sampling request shape itself (messages + constraints in,
one role/content/model out) is a reasonable, already-understood payload for `sub_lm` — Nib can
reuse the *message shape* without adopting the transport.

**Token attribution precedent: none in the protocol.** `CreateMessageResult` carries no usage
field — the host knows what it spent, the server never sees it. So attribution is host-side by
construction: every served `sub_lm` is metered by the host against the requesting sidecar's
identity. Nib's `context_meter` just needs a per-caller bucket; no external convention to match.

## 3. Condensed answers for the tickets

1. **Hook vocabulary:** four events cover the experiments; adopt the pre/post asymmetry
   (pre vetoes/rewrites, post observes/augments), per-event mutation rights declared by the
   event, exit-code coarse control + JSON fine control, harness-side matcher filters so idle
   hooks cost nothing. Don't invent a negotiation layer.
2. **Two transports, one interface:** real MCP servers (Stage-1 *tools*) may use `mcp_dart`
   sampling; Nib *hooks* ride a private newline-JSON pipe per ADR-0002. Both implement the
   same in-process Dart interface so Stage-3 promotion is a move, not a rewrite.
3. **Attribution:** per-requesting-sidecar token buckets, host-side, no wire changes; the
   sampling result shape is reusable, usage reporting is Nib's own telemetry job (#40's input).