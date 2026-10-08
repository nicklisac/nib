# Research: MCP spec surface and Dart implementation cost

Findings for [Research: MCP spec surface and Dart implementation cost](https://github.com/nicklisac/nib/issues/7).
Facts and citations only — whether Nib speaks MCP, and the tool shape, belong to
[Decide whether Nib speaks MCP](https://github.com/nicklisac/nib/issues/16).

Verified 2026-10-08 against the specification site and pub.dev.

## Verdict

Two findings reframe this ticket.

1. **The spec changed shape under everyone.** The current revision is **`2026-07-28`**, and it
   *removed the `initialize` handshake* — MCP is now stateless. Tau's bridge pins
   `PROTOCOL_VERSION = "2024-11-05"`, two revisions behind, and works only because servers stay
   backward compatible. Any Nib client must handle **both eras**, and the spec explicitly names
   that a "dual-era" implementation.
2. **The hand-roll assumption in this ticket is probably wrong.** `mcp_dart` (v2.4.2, MIT, 3
   dependencies, published 2026-09-03) already implements the 2026-07-28 spec *and* negotiates
   the older initialization-based specs, with stdio transport included. That is a lighter cost
   than the "hand-roll JSON-RPC like Tau did with Python's stdlib" plan.

## 1. Current spec shape (2026-07-28)

Latest revision: `2026-07-28`, previous `2025-11-25`.
([Specification](https://modelcontextprotocol.io/specification/2026-07-28/index.md),
[Key Changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog.md))

### Stateless: no handshake

- `initialize` / `notifications/initialized` are **removed**. Every request carries its protocol
  version and client capabilities in `_meta`
  (`io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientCapabilities`), and
  clients SHOULD identify themselves per request (`clientInfo`).
- **`server/discover` is new and MUST be implemented by servers**, advertising supported protocol
  versions, capabilities, and identity. Clients may call it up front, or use it as a
  backward-compatibility probe on stdio.
- Version mismatch returns error code **`-32022`** `UnsupportedProtocolVersion` with
  `data.supported` listing what the server takes — so a client can read the list and retry.
- Spec terminology: **"legacy"** = versions that establish a session with an `initialize`
  handshake (`2025-11-25` and earlier); **"dual-era"** = supporting both. Expect to be dual-era.

### Also removed / changed in this revision

- Protocol-level sessions and the `Mcp-Session-Id` header are gone; cross-call state uses
  server-minted handles passed as ordinary tool arguments.
- `ping`, `logging/setLevel`, `notifications/roots/list_changed` removed.
- HTTP GET endpoint and `resources/subscribe`/`unsubscribe` replaced by **`subscriptions/listen`**,
  one long-lived POST stream, notifications tagged with a `subscriptionId`.
- Server-initiated JSON-RPC **requests** are gone on stdio ("The server MUST NOT write JSON-RPC
  *requests* to `stdout`"); server-to-client interaction is now an **`InputRequiredResult`**
  inside a tool reply ("Multi Round-Trip Requests"). An older client that expects
  server→client requests will simply never receive them.

### Tool discovery and invocation

`tools/list` returns `resultType`, `tools[]`, `nextCursor` (pagination), plus `ttlMs` and
`cacheScope` caching hints. Each tool is `{name, title, description, inputSchema, icons[]}` where
**`inputSchema` is ordinary JSON Schema** (`type: "object"`, `properties`, `required`) — the same
shape Nib's `AgentTool.parameters` already builds, so discovery maps almost directly onto Nib's
registry.

`tools/call` → `{resultType, content: [{type: "text", text: …}], isError: false}`. Content blocks
are typed; `isError` distinguishes tool failure from transport failure. Servers MAY instead return
`InputRequiredResult` to ask for more input mid-call.

### Cancellation and progress

Cancellation is `notifications/cancelled` with `{requestId, reason?}` — a *notification*, so
fire-and-forget; a server that already answered will just have its response discarded.
Request-scoped notifications (`notifications/progress`, `notifications/message`) ride the response
stream of the request they belong to.

### Transports

- **stdio**: newline-delimited JSON-RPC 2.0, one message per line, over a reliable bidirectional
  byte stream. Strict rules: the server MUST NOT write anything to `stdout` that isn't a valid MCP
  message, and vice versa for the client's `stdin`. Client MUST NOT write responses; server MUST
  NOT write requests. Client **MAY** capture, forward, or ignore `stderr` and **SHOULD NOT** assume
  stderr means error. Shutdown by closing the stream; the same framing works over UDS/TCP.
- **Streamable HTTP** also specified, with an `MCP-Protocol-Version` header.

### Authorization

**OPTIONAL**, and defined for **HTTP-based transports**: "Implementations using an STDIO transport
SHOULD NOT…" (i.e. stdio servers take credentials through their own env/config, not MCP OAuth).
So a local `~/.nib/mcp.json` stdio setup — Nick's `blender` case — needs **no OAuth work at all**.

## 2. Cost in Dart

### Packages (pub.dev API, verified today)

| Package | Version | Published | Deps | Notes |
| --- | --- | --- | --- | --- |
| **`mcp_dart`** | 2.4.2 | 2026-09-03 | `crypto`, `http`, `meta` | MIT, 160 pub points, 216k downloads. Client **and** server/host. Claims the **2026-07-28** spec, retains the 2025-11-25 feature set, "negotiates supported earlier initialization-based specifications". Transports: **stdio**, Streamable HTTP, IO stream, custom. OAuth PKCE hooks, DNS-rebinding protection. |
| `mcp_client` | 2.2.1 | 2026-08-13 | `http`, `json_annotation`, `uuid`, `meta`, `logging`, `crypto` | 6 deps, client-only |
| `json_rpc_2` | 4.1.0 | 2026-02-18 | `stack_trace`, `stream_channel` | Generic JSON-RPC, no MCP semantics |

`mcp_dart` pulls only **`crypto`** as a genuinely new transitive dep (`http` and `meta` Nib
effectively has already). That is within the dependency bar Nib has set for itself, and it is
strictly less code than writing, testing, and maintaining a dual-era JSON-RPC framing layer.

### Hand-rolling, for comparison

Tau's bridge is **576 lines of Python** for stdio + one dispatcher tool, with a dedicated reader
thread per server, a stderr tail buffer, timeouts, and restart. It pins `2024-11-05` and so
predates: `outputSchema`, `icons`, `resultType`, caching hints, `server/discover`, stateless
`_meta` versioning, `subscriptions/listen`, and MRTR `InputRequiredResult`. A Dart hand-roll
aiming at the *current* spec would be larger than 576 lines, not comparable.

### Dart's own machinery

- Subprocesses: `dart:io` `Process.start` gives stdin/stdout as byte streams;
  `systemEncoding.decoder.bind(stdout)` then a line-splitting transformer gives the
  newline-delimited framing directly. `kill()` handles a wedged server; a `stopper`/timeout on the
  response `Future` handles a slow one.
- Concurrency: a single-subscription `Stream` reader with an id→`Completer` map is the idiomatic
  JSON-RPC demultiplexer — no isolates needed, and no equivalent of Tau's per-server reader
  thread. Dart's event loop makes the "one reader per server" concern cheaper than in Python.
- `ProcessStartMode.inheritStdio` is wrong here; Nib needs piped stdio and must keep its own
  stdout clean — a real but small concern for a CLI that streams ANSI to the same terminal.

## 3. What Nick's one server exercises

`~/.tau/mcp.json` declares exactly one server: `blender` → `uvx blender-mcp`, env
`BLENDER_HOST`/`BLENDER_PORT`, **`autostart: false`**, with a note that it needs Blender running
with its addon socket server on :9876.

Minimum viable path, therefore: **lazy start on first use** (a missing/broken server must never
slow startup), stdio only, one server at a time in practice, env-var configuration, and a visible
stderr tail for debugging a server that won't come up. Nothing in the current spec's HTTP, OAuth,
subscription, or sampling surface is exercised by it. The unknown is whether `blender-mcp` is
dual-era: if it only speaks the legacy handshake, Nib must implement the legacy path anyway.

## Open questions for #16

1. `mcp_dart` versus hand-rolling — now a real question rather than a formality, given the
   package's currency and dep count. If `mcp_dart`, verify its spec compliance independently
   before trusting the README claim.
2. One dispatcher tool versus registering discovered tools individually. Sharpened by the spec:
   `inputSchema` is plain JSON Schema, so individual registration is nearly free to implement —
   the cost is prompt tokens and tool-list size, not code.
3. Dual-era support: does Nib implement legacy `initialize` too, or require `2026-07-28` servers
   and fail with a clear message? Depends on what `blender-mcp` actually speaks.
4. Transport scope: stdio only to start, almost certainly.
5. Where config lives and its schema; how `autostart: false` lazy-start, restart, and failure
   isolation are expressed.
6. Name-mangling discovered tools into Nib's registry (collisions, prefixing, `/tools` output).
7. How MCP results are capped against `Agent.maxToolOutputChars`, given `content[]` can carry
   several blocks and non-text types.
8. Whether cancellation is wired to Nib's `Esc`/`Ctrl+C` turn abort (`notifications/cancelled`).

## Sources

- [MCP Specification 2026-07-28 — index](https://modelcontextprotocol.io/specification/2026-07-28/index.md),
  [Key Changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog.md),
  [Versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning.md),
  [Transports: stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.md),
  [Server: Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools.md),
  [Cancellation](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation.md),
  [Authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization.md)
- [pub.dev/packages/mcp_dart](https://pub.dev/packages/mcp_dart),
  [pub.dev/packages/mcp_client](https://pub.dev/packages/mcp_client),
  [pub.dev/packages/json_rpc_2](https://pub.dev/packages/json_rpc_2) (versions/deps via the pub.dev API)
- `~/.tau/extensions/mcp/extension.py` (576 lines, local primary source; pins
  `PROTOCOL_VERSION = "2024-11-05"`), `~/.tau/mcp.json`
- Nib: `lib/agent/tool.dart` (`AgentTool.parameters` JSON Schema builders)