# Tau usage evidence

Measured, not remembered. The keep-list and cut-list ([#2](https://github.com/nicklisac/nib/issues/2)) and the
workflow set ([#3](https://github.com/nicklisac/nib/issues/3)) are decisions about what Nick *actually does*, and
memory about tool usage is unreliable — people report the feature they last configured, not the one they use
daily. So this doc counts the real thing.

**Sources.** Tau 0.4.7 installed at `~/.local/share/uv/tools/tau-ai/.../site-packages/{tau_coding,tau_agent,tau_ai}`;
`~/.tau/sessions/` (28 project dirs, 296 session files); `~/.tau/{extensions,skills,agy-jobs,subagent-jobs,mcp.json}`;
Nib's `~/.nib/sessions/` (217 files).

**One correction worth stating up front.** 57 of Nib's 217 saved sessions are not real usage — they are `dart test`
runs leaking into `~/.nib/sessions/` via the `poll_file` fixture in `test/agent_test.dart:362`. They account for
1400 of 2434 recorded tool calls. Every Nib number below excludes them. Logged as an itch.

## Surface size

| | LOC |
|---|---|
| `tau_coding` | 50,010 |
| `tau_ai` | 5,422 |
| `tau_agent` | 2,367 |
| **Tau total** | **57,799** |
| **Nib total** | **7,188** (`ui` 3,209 · `agent` 1,867 · `ai` 927 · `tools` 874 · `bin` 311) |

Nib is 12% of Tau's size. Parity is not "rebuild Tau" — it is choosing ~7k lines' worth of the 58k.

## Tools actually called, all 296 Tau sessions

| tool | calls | sessions | note |
|---|---|---|---|
| `bash` | 9,059 | — | Nib has it |
| `read` | 2,297 | — | Nib has it |
| `edit` | 2,132 | — | Nib has it |
| `write` | 541 | — | Nib has it |
| `web_search` | 343 | 45 | Exa. **Nib has no web tool.** |
| `web_fetch` | 173 | 34 | **Nib has none.** |
| `subagent_status` | 78 | 21 | Gemini workers |
| `subagent_spawn` | 43 | 21 | |
| `subagent_jobs` | 8 | — | |
| `graft_grep` | 26 | 10 | code-intelligence extension |
| `graft_map` | 10 | — | |
| `graft_skeleton` | 9 | — | |
| `graft_callers` | 3 | — | |
| `graft_ask` | 1 | — | |

**Nothing else was ever called.** The four core tools are 96% of all activity.

## What was configured and never used

- **MCP: zero calls in 296 sessions.** `~/.tau/mcp.json` holds one server (`blender`, `autostart: false`). "Blender"
  appears in 9 session files as prose, never as a tool call. The map's Out-of-scope entry says MCP covers the need —
  the evidence says the need has not appeared. Relevant to [#16](https://github.com/nicklisac/nib/issues/16).
- **`remote-tau`: zero** `remote` tool calls.
- **graft: 49 calls across 10 sessions**, all in one experiment. A prompt in `notecaster-js` reads *"I just installed
  and then ran graft build. Take a spin of the graft tools and compare them to the traditional tools"* — that is a
  trial, and the trial concluded in favour of the traditional tools (`grep` outnumbers every graft tool combined).
- **Native subagents are dead; call-out is alive.** `~/.tau/subagent-jobs/` has 43 job sets, all dated **Aug 23**.
  `~/.tau/agy-jobs/` has **110** job files, newest **Oct 6**. The `subagent_spawn` calls above are from the older
  period. The surviving delegation shape is the one that calls out to another CLI — which is the shape the map
  already kept in [#8](https://github.com/nicklisac/nib/issues/8) and cut native subagents for.

## Thinking levels

Tau's ladder is `off · minimal · low · medium · high · xhigh · max`, default `medium`.

Changes recorded across all sessions: **xhigh 114 · medium 99 · high 30 · low 16 · off 10** — 238 changes, so this
is a control Nick reaches for constantly, not a set-and-forget. Confirms the [#6](https://github.com/nicklisac/nib/issues/6)
finding that the level list must be per-model metadata. Nib currently sends **no** thinking parameter at all.

## Images

94 `type: image` content blocks and 122 screenshot paths across real sessions — a screenshot is a routine way to
start a turn (`~/Pictures/Screenshots/...png`). Nib accepts no image input. Relevant to
[#17](https://github.com/nicklisac/nib/issues/17).

## Models used

`Qwen3.8-27B-GGUF:UD-Q8_K_L` (97) · `gemini-3-flash-preview` (34) · `gemini-flash-latest` (22) ·
`gemini-flash-lite-latest` (22) · `Qwen3.8-Flash-Next-exl3-...` (21) · plus 8 more. Local GGUF/exl3 and Gemini
side by side; no OAuth-subscription provider appears, consistent with the map's OAuth cut.

## Real projects, by sustained use

Ranked by last activity; prompt counts exclude test dirs.

| project | prompts | last |
|---|---|---|
| notecaster-js (SvelteKit) | 1,085 | Sep 13 |
| web-sql-agent "Tables" | 181 | Oct 7 |
| embed-predict (GPU/eGPU embeddings) | 109 | Sep 16 |
| remote-tau | 44 | Aug 23 |
| kid-games / dino-frenzy (→ APK, tablet) | 31 | Aug 23 |
| rocket-builder (three.js/WASM) | 29 | Oct 3 |
| scream-snake | 9 | Oct 8 |
| learn-your-code | 7 | Sep 28 |

Active within the last week: **scream-snake, web-sql-agent, rocket-builder**. These are the projects a
daily-driver Nib has to win.

## The workflows those prompts describe

Reading prompt text rather than counting it, five shapes recur:

1. **Wayfinder planning in a real repo** — `web-sql-agent` ("Wayfind us into T36… no close this one up. merge to
   main. push to GH. clean up branches. update wayfinder and other docs. prepare us for 37"), `learn-your-code`,
   `notecaster-js` ("We're working on our Wayfinder ticket #50"). Planning, then merge-and-clean-up, then update the
   docs. Needs: gh, git, long sessions, doc edits.
2. **Interactive physical debugging** — `embed-predict` ("I see you killed GPU2… it is the smaller packets at a rapid
   rate it does not handle"), `rocket-builder` ("the fins need to stick to the rocket no matter what. When I put a
   twist on with a longer length they twist off"). Nick interrupts mid-task, points at hardware or geometry, and
   expects the agent to adjust. Needs: interruption that does not lose his place, and long tool loops.
3. **Package-and-ship to a device** — `dino-frenzy` ("look at how we exported my ring-fly game to apk… side load
   this to a Lenovo tablet… try the tablet again it is plugged in and unlocked"). Needs: adb, long-running builds,
   **polling a device**, and a skill capturing the path afterwards.
4. **Research then implement** — `rocket-builder` ("Research the `manifold-3d` npm package… for"). Needs the web
   tools, which Nib lacks entirely.
5. **Fix the agent harness itself** — `home-c3c818`, 125 prompts in one day, almost entirely about Nib/Tau input
   behaviour. Directly relevant to [#20](https://github.com/nicklisac/nib/issues/20): Nick asked Tau to bind
   **newline → `alt+enter`** and **queue follow-up → `ctrl+j`**, and confirmed "ctrl j works". He has already
   chosen the keys for the model #20 designed.

## Where that leaves the open questions

- **Web tools are the biggest real gap** — 516 calls, 45 sessions, nothing in Nib.
- **Thinking levels are second** — 238 changes, nothing in Nib.
- **Images are third** — 94 blocks, nothing in Nib.
- **Delegation is call-out, not native** — the native jobs have been dead since Aug 23.
- **MCP has no evidence behind it in either direction** — configured once, never used. [#16](https://github.com/nicklisac/nib/issues/16)
  should decide on the strength of the spec work in `docs/research/mcp-spec.md`, not on assumed need.
- **graft-style code intelligence is not wanted** — trialled and abandoned in favour of `grep`.
- **`alt+enter` / `ctrl+j`** are Nick's own answer to the input question #20 settled.