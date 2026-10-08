# Research: reasoning-effort, image input, model metadata across provider families

Findings for [Research: reasoning-effort, image input, model metadata across provider families](https://github.com/nicklisac/nib/issues/6).
Facts and citations only — the config shape and scope belong to
[Decide the thinking-level and image config shape](https://github.com/nicklisac/nib/issues/17).

Verified 2026-10-08 against live local servers, Anthropic and OpenAI docs, and Tau's source.

## Verdict

There is no single "thinking" parameter. Three families, three different contracts, and **each
one rejects values the others accept** — so a level list must be per-model metadata, not a global
enum. Image input has a common JSON shape but wildly different limits, and a text-only model
fails with an HTTP 500 rather than a clean rejection, so capability has to be declared. Nib
today sends **no thinking parameter at all** to either provider.

## 1. Reasoning control per family

### Anthropic (Messages API)

Two mechanisms coexist:

- **`thinking: {type: "enabled", budget_tokens: N, display: "summarized"|"omitted"}`** —
  `budget_tokens` **must be ≥ 1024 and less than `max_tokens`**; minimum 1024.
  `display: "omitted"` returns redacted thinking plus a signature for multi-turn continuity.
  ([docs.anthropic.com/en/api/messages](https://docs.anthropic.com/en/api/messages))
- **`effort: "low"|"medium"|"high"|"xhigh"|"max"`** — the newer effort parameter on the same
  request body, alongside `format` for structured outputs.

**Interaction that bites Nib**: `lib/ai/anthropic_provider.dart:110` defaults
`max_tokens` to **4096**. Tau's level→budget table
(`tau_coding/thinking.py:65-80`) is `minimal 1024, low 2048, medium 4096, high 8192,
xhigh 16384, max 32768`. With Nib's default, **every level from `medium` up would be rejected**
because the budget is not below `max_tokens`. Any budget-based design must raise `max_tokens` in
lockstep with the budget, or use `effort` instead and dodge the coupling entirely.

Nib already *parses* `thinking_delta` (`anthropic_provider.dart:232-234`) but never *sends* a
`thinking` or `effort` field — the receive path exists, the send path does not.

### OpenAI-compatible

- Chat Completions takes **`reasoning_effort`**; Responses API takes `reasoning.effort`.
  Documented values: `minimal, low, medium, high, xhigh, max`.
- **`none` is not universally accepted**: for newer models, setting `reasoning_effort`/
  `reasoning.effort` to `none` **returns HTTP 400** ("GPT-6 Astra does not support none
  reasoning effort"), and another generation rejects `none` *and* `minimal`, defaulting to
  `medium`. ([platform.openai.com/docs/guides/reasoning](https://platform.openai.com/docs/guides/reasoning))
- Tau maps its `off` level to `"none"` (`thinking.py:57-63`) — a direct 400 on those models.

### Local servers via chat template (tabbyAPI / exllama / unsloth)

Probed live against `http://localhost:5000/v1` (tabbyAPI, `Qwen3.8-Flash-Next-exl3-3.50bpw_hq_h6_ng6`):

- **`reasoning_effort` is validated by the model's chat template, per model.** This template
  accepts only **`xhigh` (the default), `medium`, `low`** and answers anything else with
  `TemplateError: Unexpected reasoning effort high. Supported types are xhigh (default),
  medium, and low.`** So `none`, `minimal`, and `high` all fail on a model whose own server is
  configured for a *subset* — while `low` and `xhigh` succeed.
- **`chat_template_kwargs: {"enable_thinking": false}` works** and is the only way to turn
  thinking fully off here: reasoning output went from 136 chars (baseline) to 0 chars.
- **The default is the *highest* level.** With no parameter sent, this model thinks at `xhigh`,
  so Nib is currently paying maximum thinking cost on every turn with no control.
- Reasoning arrives as `delta.reasoning_content` (also `delta.reasoning` on some servers), which
  `openai_provider.dart:167-172` already maps to `ThoughtDeltaEvent`.

The server advertises models with capability metadata at `GET /v1/models`:
`{"id": …, "meta": {"n_ctx_train": 262144, "n_vocab": …, "n_embd": …}}`. Nib never calls this
endpoint; `context_window` comes only from `~/.nib/config.json` (`config.dart:39,166`).

### What Tau exposes, for calibration

`tau_coding/thinking.py` (93 lines): levels `off, minimal, low, medium, high, xhigh, max` with a
human description each; three `ThinkingParameter` kinds — `reasoning_effort`, `reasoning.effort`,
`anthropic.thinking` — declared per provider in `catalog.toml`, which also carries
`thinking_levels = [...]` (a *subset* per provider, e.g. `off,low,medium,high,xhigh`) and
`thinking_default`. Levels cycle with `next_thinking_level()`. So Tau's answer to per-model
variance is: **declare the supported subset per provider in the catalog.**

## 2. Image input

### Message shapes

- **OpenAI-compatible**: `content: [{type:"text",…},{type:"image_url", image_url:{url:"data:image/png;base64,…"}}]`
  — data URI, or a hosted URL.
- **Anthropic**: `content: [{type:"image", source:{type:"base64", media_type:"image/png", data:"…"}}]`,
  or `source:{type:"file", file_id:…}` from the Files API, or a URL. Anthropic recommends
  **images before text** for best results.
  ([docs.anthropic.com/en/docs/build-with-claude/vision](https://docs.anthropic.com/en/docs/build-with-claude/vision))

### Limits (Anthropic, documented)

- Per image: **10 MB base64-encoded** direct; **5 MB** on Bedrock/Vertex.
- Dimensions: up to 8000×8000 px, but **above 20 image/document blocks in a request a stricter
  per-image limit applies and over-limit images are rejected** with `many-image…`. The documented
  safe harbour: **resize so neither dimension exceeds 2000 px, or stay at ≤ 20 blocks.**
  Note the counting includes images from earlier turns that get resent, and images nested in
  `tool_result` blocks — which matters for an agent that replays its transcript every turn.
- Up to 600 images per request, but the **32 MB request limit is usually hit first**.

### Local reality check

Posting a valid 1×1 PNG `image_url` to the live tabbyAPI text model returned
**`Internal Server Error` (HTTP 500)** — not a 400, not a structured error. A client cannot
probe-and-hope; it must know a model accepts images before attaching one, or it surfaces a
useless 500 to the model.

### What Tau does

`tau_coding/image_processing.py` (253 lines): `DEFAULT_MAX_IMAGE_BYTES = 5 MiB`,
`DEFAULT_MAX_IMAGE_DIMENSION = 2000`; **magic-byte sniffing** (`detect_image_family_mime_type`)
rather than trusting extensions, accepting jpeg/png/gif/webp; rejects animated images
("cannot be resized without losing animation"); resizes when over either bound; converts BMP.
The 2000 px / 5 MiB pair sits exactly inside Anthropic's documented safe harbour.

### Terminal delivery paths

A raw-mode CLI has no universal image paste. Practical channels: a file path or `@file` mention
(always available), drag-and-drop delivering a path (terminal-dependent), and true in-band paste
only via graphics protocols (kitty / iTerm2 / Sixel) — which is a whole capability of its own and
is tracked as fog on the map, not here.

## 3. Per-model metadata: what actually changes behaviour

Minimum set that changes Nib's behaviour, from the above:

| Metadata | Why it changes behaviour |
| --- | --- |
| context window | drives auto-compaction; today config-only, though tabbyAPI serves `meta.n_ctx_train` free |
| thinking parameter kind + supported subset | sending an unsupported value is a hard HTTP error (OpenAI `none` → 400; tabbyAPI `high` → `TemplateError`) |
| thinking default | local model defaults to `xhigh`; without knowing it, Nib cannot report the effective level |
| image support | text-only models answer with a 500, so the flag gates attachment entirely |
| max output tokens | Anthropic's `budget_tokens < max_tokens` rule couples it to the thinking level |

Tau drives all of this from `catalog.toml` + `models_dev_store` + `providers.json`. The machinery
it carries that Nib may not need: the `models.dev` sync, provider catalog loading, and fuzzy
model-pattern cycling (`--models` globs).

## Open questions for #17

1. `effort` versus `budget_tokens` for Anthropic. `effort` dodges the `max_tokens` coupling;
   `budget_tokens` is what older models and the wider ecosystem speak. Picking one decides how
   much of Nib's `max_tokens` story has to change.
2. What "off" means per family: OpenAI can't say `none` on newer models; local needs
   `chat_template_kwargs.enable_thinking`; Anthropic omits the field. Three different noops.
3. Is the supported level list per **provider** (Tau's choice) or per **model**? The live probe
   shows it is genuinely per-model-chat-template, i.e. per model.
4. Does Nib read `meta.n_ctx_train` from `/v1/models` at startup, or keep context window
   config-only? The README already tells users tabbyAPI reports it there.
5. Whether thinking is set per session (`/thinking`), per provider, per model, or per call — and
   what the status bar shows, given a local model defaults to `xhigh` silently.
6. Where an image enters (path / `@file` / paste) and what the UI shows while attached; in-band
   graphics protocols stay in map fog.
7. Whether Nib does any downscaling at all (needs image decoding, a heavier call than the web
   tools) or just enforces size limits and tells the user to resize.

## Sources

- Live probes 2026-10-08 against `http://localhost:5000/v1` (tabbyAPI/exllamaV3):
  `/v1/models` metadata; `reasoning_effort` accepted/rejected values and the `TemplateError`
  text; `chat_template_kwargs.enable_thinking`; `image_url` → HTTP 500.
- [Anthropic Messages API reference](https://docs.anthropic.com/en/api/messages) — `thinking.budget_tokens`
  (≥1024, < `max_tokens`), `display`, and the `effort` enum.
- [Anthropic — Vision](https://docs.anthropic.com/en/docs/build-with-claude/vision) — size,
  dimension, block-count and request limits; base64/URL/`file_id` source shapes.
- [OpenAI — Reasoning](https://platform.openai.com/docs/guides/reasoning) — `reasoning_effort`
  values and the HTTP 400 on `none` for newer models.
- `tau_coding/thinking.py`, `tau_coding/image_processing.py`, `~/.tau/catalog.toml` (local
  primary sources: Tau's implementation and per-provider declarations).
- Nib: `lib/ai/openai_provider.dart:167-172`, `lib/ai/anthropic_provider.dart:110,232-234`,
  `lib/agent/config.dart:39,166`.