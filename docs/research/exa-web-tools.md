# Research: Exa API, fetch-in-Dart options, key status

Findings for [Research: Exa API, fetch-in-Dart options, key status](https://github.com/nicklisac/nib/issues/4).
Facts and citations only — the tool surface, result caps, and dependency call belong to
[Decide the web tool surface and dependency](https://github.com/nicklisac/nib/issues/15).

Verified 2026-10-08 against the live API and vendor docs.

## Verdict

Exa is a single JSON POST with no SDK requirement, and `EXA_API_KEY` is already set on this
machine. A fetch tool needs no dependency at all: `dart:io` `HttpClient` plus a ~60-line
tag-skipping text extractor reproduces what Tau's extension does. Nothing here forces a new
pub dependency.

## 1. Exa search API

### Endpoint and auth

- `POST https://api.exa.ai/search`, JSON body, JSON response.
- Two accepted auth headers, both verified live: `Authorization: Bearer <key>` and
  `x-api-key: <key>`. A rejected key returns `401` with a JSON body
  `{"requestId":…, "error":"Invalid API key. Provide a valid key using 'Authorization: Bearer <key>' or 'x-api-key: <key>'…"}` —
  i.e. errors are structured, not bare status codes. ([docs.exa.ai/reference/search](https://docs.exa.ai/reference/search), live probe)
- Key comes from the dashboard at `dashboard.exa.ai/api-keys`. `EXA_API_KEY` is present in
  this machine's environment, so the capability is already paid for and working.

### Request shape

Verified parameters: `query`, `numResults`, `type`, and a nested `contents` object.

- `numResults`: 1–100. Docs note the base price covers up to 10 results; more cost extra.
- `type`: `"auto"` (default), `"fast"`, `"instant"`, `"deep"`, `"deep-reasoning"` — all five
  accepted live. `instant` is the cheapest, `deep*` the priciest.
- `contents.text.maxCharacters`: caps per-result page text inline, avoiding a second round
  trip. Tau uses `{"text": {"maxCharacters": 1200}}`.
- Also available per docs: `contents.highlights` (+ `highlightScores`), `contents.summary`,
  `contents.subpages`, `entities`, `favicon`, `image`, `publishedDate`, `author`.

### Response shape

Top level: `requestId`, `resolvedSearchType`, `results`, `searchTime`, `costDollars`.

Each result with `contents.text` requested: `id`, `title`, `url`, `text`. Optional fields
(`publishedDate`, `author`, `score`, `favicon`, `highlights`, `summary`) came back absent in
probes, so a client must treat them as optional and never assume them.

`text` is **already clean text**, not HTML — page body with markup removed, whitespace
normalized by the vendor. Tau still collapses whitespace defensively
(`re.sub(r"\s+", " ", text)`), which is cheap insurance and worth copying.

`costDollars` is a structured object, e.g. `{"total": 0.007, "search": {"neural": 0.007}}`,
returned on every response. Surfacing it per call is free.

### Measured cost and latency

| Configuration | cost | notes |
| --- | --- | --- |
| `numResults: 3`, no `contents` | $0.007 | titles + URLs only |
| `numResults: 5`, `text.maxCharacters: 1200` | $0.007 | 7.8 KB response, 1200 chars/result |
| `type: "instant"` | $0.004 | cheapest verified |
| `type: "deep"` | $0.012 | |
| `type: "deep-reasoning"` | $0.015 | |

End-to-end latency 0.82 s (vendor `searchTime` 635 ms) for a 5-result search with contents —
comfortably inside the "quick tool" class, so it can run synchronously from the model's point
of view.

Pricing model: pay-as-you-go, no subscription, no minimum. Search from **$4/1k requests**;
Contents $1/1k pages; Answer $5/1k; Deep Search $12–15/1k. Free tier gives **$10 in credits
(up to 2,500 Instant searches) on signup, resetting to $10 on the first of each month**, with
no payment method required.
([docs.exa.ai/reference/pricing](https://docs.exa.ai/reference/pricing))

A coding agent doing a handful of searches per session is orders of magnitude inside the free
monthly credit. Rate limits exist per plan tier; the billing page
([exa.ai/docs/admin/billing](https://exa.ai/docs/admin/billing#rate-limits)) is JS-rendered and
would need the dashboard to read exact per-tier numbers. Tau maps `429` to "wait a moment and
retry", which is the only handling a client needs to start with.

### Alternatives worth weighing

- **Exa `/answer`** ($5/1k) returns a synthesized answer plus citations — one call replaces
  search-then-read, but costs ~3× and gives the model a conclusion instead of sources.
- **`/contents`** ($1/1k pages) fetches full text for *known* URLs, which overlaps the fetch
  tool. It is server-side HTML stripping, so it would remove the Dart HTML-to-text work for
  $0.001/page — but adds a key dependency to the fetch path and no longer works for non-HTML
  or local-network targets.
- **Zero-key options** (DuckDuckGo HTML endpoint, Wikipedia API) avoid cost and a key, but are
  unofficial/unreliable for search and the vendor explicitly prices the reliable path cheaply.
  Not recommended as the primary route.

## 2. What Tau's web extension actually does

Source: `~/.tau/extensions/web/extension.py` (~300 lines, Python stdlib + `httpx`).

- **`web_search`** — `POST /search` with `numResults` and `contents.text.maxCharacters`.
  Renders markdown to the model: `# Web Search Results: "<query>"`, then per result
  `## <n>. <title>`, `**URL:** <url>`, snippet, `---` separator. Defaults: 5 results,
  1200 chars each, 25 s timeout.
- **Error contract is textual and actionable**, returned as tool output rather than raised:
  missing key → `"ERROR: EXA_API_KEY is not set. Set it in the environment to use web_search."`;
  `401/403` → key rejected; `429` → rate limited, retry later; other `>= 400` → status plus
  first 300 chars of body; empty results → `No results found for query: "…"`. This is the
  pattern worth keeping: the model reads these and self-corrects.
- **`web_fetch`** — direct HTTP with redirects followed, 25 s timeout, custom UA, 20 000-char
  cap with an explicit truncation notice stating shown vs total characters. Content-type aware:
  strips HTML only when `content-type` contains `html` or the body starts with `<`; otherwise
  collapses horizontal whitespace and returns the body (so JSON/plain text pass through).
- **`_TextExtractor`** — a stdlib `HTMLParser` subclass with two tag sets: `SKIP`
  (`script style noscript svg head nav footer header aside form iframe template button`,
  depth-counted) and `BLOCK` (`p div br li ul ol h1-h6 tr table section article blockquote pre
  hr figure figcaption dd dt`, emitted as newlines). Roughly 60 lines. No readability library.
- **Guardrails** — scheme allowlist (`http`/`https` only, explicit error otherwise);
  `_host_is_blocked()` rejects `localhost`, suffixes `.local`/`.internal`/`.localhost`, and any
  IP that is private, loopback, link-local, or reserved via `ipaddress`. Self-described in the
  docstring as a "safety nudge", not a sandbox.

## 3. Cost in Dart

- **HTTP**: `http` is already a direct dependency (`^1.6.0`, used by both providers), and
  `dart:io` `HttpClient` gives redirect control and timeouts. Exa is one POST plus
  `jsonDecode`. **No new dependency for search.**
- **HTML to text**: pub has no obvious maintained readability-grade package. `html` 0.15.7 is
  maintained (published 2026-08-28) and gives a real parser; the search results for "html to
  text" / "readability" return Flutter-coupled or unrelated packages
  (`simple_html_css`, `web_scraper`, `readability`, `chaleno`) that are poor fits for a
  terminal CLI. Tau's approach — walk tags, skip non-content, insert newlines at block tags —
  is ~60 lines against either `html` or a small hand-rolled scanner.
  **Recommendation input for #15: hand-roll it; the dep does not earn its weight.**
- **IP guard**: `InternetAddress.tryParse(...)` exposes `isLoopback`, `isLinkLocal`,
  `isSiteLocal`; `InternetAddress.lookup` resolves a hostname first so a public name cannot
  redirect to a private literal. Suffix rules match Tau's.
- **Concurrency**: Dart's event loop plus `Future` is sufficient. Tau pushes blocking HTTP off
  the event loop with `asyncio.to_thread`; Dart has no equivalent problem — `http` is already
  non-blocking, so no isolate is needed for a tool that takes under a second.

## Open questions for #15

1. Two tools or one — Tau's split mirrors the two distinct network paths and keeps fetch's
   20 000-char cap separate from search's per-result cap.
2. Which key source: `EXA_API_KEY` env only (Tau's behaviour, zero config), or a `web` block in
   `~/.nib/config.json`. Note the harness rule: a provider-specific key must not be hardcoded
   into the tool in a way that assumes Exa is the only vendor.
3. Caps against `Agent.maxToolOutputChars`: Tau's defaults (5 × 1200 = 6000 chars search,
   20 000 fetch) straddle Nib's cap, so truncation behaviour needs an explicit decision rather
   than being inherited silently.
4. Whether to surface `costDollars` in the tool card or status bar, since the API returns it
   free on every response.
5. Whether `type: "instant"` is the right default for a coding agent — 2× cheaper and faster
   than `auto`, and search quality versus `auto` was not measured here.

## Sources

- Live probes against `https://api.exa.ai/search` (valid key, `numResults` 1–5, `type` variants,
  bad-key 401) — 2026-10-08.
- [Exa API reference — Search](https://docs.exa.ai/reference/search)
- [Exa — Pricing](https://docs.exa.ai/reference/pricing)
- [Exa — Billing and Rate Limits](https://exa.ai/docs/admin/billing#rate-limits)
- `~/.tau/extensions/web/extension.py` (local primary source: Tau's implementation)
- [pub.dev/packages/html](https://pub.dev/packages/html), [pub.dev/packages/http](https://pub.dev/packages/http)