# ✒ Nib

A minimalist terminal CLI coding agent inspired by **Pi** (by Mario Zechner `@badlogic`) and **Tau** (Hugging Face `twotimespi.dev`), written entirely in **Dart**.

Nib is not a windowed TUI or full-screen GUI—it is a pure terminal streaming CLI with ANSI formatting, live token streaming, interactive tool execution blocks, persistent shell readline history, Tau-style context compaction, and multi-language syntax highlighting.

---

## 🏛 Architecture

```
lib/
├── ai/                     # Provider layer (provider-neutral streaming)
│   ├── chat_message.dart   # Chat messages and tool call schemas
│   ├── event_stream.dart   # Streaming events (TextDelta, ThoughtDelta, ToolCallComplete)
│   ├── provider.dart       # LLMProvider abstract interface
│   ├── openai_provider.dart# OpenAI / OpenRouter / Groq / Ollama / DeepSeek / tabbyAPI
│   ├── anthropic_provider.dart# Anthropic Claude (Messages API streaming)
│   └── mock_provider.dart  # Zero-key offline simulation & test provider
├── agent/                  # Agent harness layer (independent of UI)
│   ├── agent.dart          # Core loop: stream -> parse calls -> run tools -> repeat (with cancellation)
│   ├── compaction.dart     # Tau-style context compaction & summarization checkpoint engine
│   ├── config.dart         # ~/.nib/config.json with ~/.tart / ~/.tau fallback matching
│   ├── session.dart        # Message transcript, token accounting & ~/.nib/sessions/ persistence
│   ├── undo_manager.dart   # Snapshot tracker powering one-click /undo
│   ├── approval_manager.dart# Interactive tool confirmation checks (/confirm)
│   └── tool.dart           # AgentTool interface & schema builders
├── tools/                  # Application tools layer
│   ├── bash_tool.dart      # Shell command execution with timeout & output capture
│   ├── read_file_tool.dart # Numbered line reading with range slices
│   ├── write_file_tool.dart# File creation & overwrite (tracked in undo stack)
│   ├── edit_file_tool.dart # Surgical exact search & replace (with unified color diffs)
│   ├── list_dir_tool.dart  # Directory and file tree listing
│   └── search_files_tool.dart# Regex & pattern search across files
└── ui/                     # Terminal CLI UI layer
    ├── ansi.dart           # ANSI colors, banners, and formatters
    ├── theme.dart          # 24-bit TrueColor theme engine (Catppuccin, Tokyo Night, Nord, Gruvbox)
    ├── cli_ui.dart         # Pure stdout streaming UI with box-drawing tool cards & multi-line input
    ├── prompt_reader.dart  # Interactive readline with Up/Down history recall & Tab completion
    ├── autocomplete.dart   # Prefix & fuzzy matching for slash commands and @file mentions
    ├── diff_formatter.dart # Color unified diff generator (+green / -red)
    ├── markdown_renderer.dart# TrueColor syntax highlighter for Dart, Python, Bash, JSON, SQL, etc.
    ├── spinner.dart        # Braille spinner with elapsed time & live token streaming speed (tok/s)
    ├── status_bar.dart     # Docked status line displaying provider, model, tokens, and git workspace
    └── slash_commands.dart # Slash commands (/help, /compact, /undo, /theme, /confirm, /sessions, etc.)
```

---

## ⚡ Quick Start

### 1. Default (Matches your local ExLlama / tabbyAPI model)
Nib automatically reads `~/.nib/config.json` (or falls back to `~/.tart/` and `~/.tau/`):
```bash
./nib
```
Or resume your previous conversation where you left off:
```bash
./nib --resume
```

### 2. Offline Demo Mode (No API keys required)
```bash
./nib --mock
```
Or run one-shot commands directly from the shell:
```bash
./nib --mock "list files in this directory"
./nib --mock "read pubspec.yaml"
./nib --mock "check git status"
```

### 3. Cloud LLM Providers
Set your API key and run:

```bash
# OpenAI (or DeepSeek / Groq)
export OPENAI_API_KEY="sk-..."
./nib -m gpt-4o

# Anthropic Claude
export ANTHROPIC_API_KEY="sk-ant-..."
./nib -p anthropic -m claude-3-5-sonnet-20241022

# OpenRouter
export OPENROUTER_API_KEY="sk-or-..."
./nib -p openrouter -m anthropic/claude-3.5-sonnet

# Local Ollama
./nib -p ollama -m llama3 --base-url http://localhost:11434/v1
```

---

## ⚙️ Configuration (`~/.nib/config.json`)

```json
{
  "default_provider": "exllama",
  "default_model": "Qwen3.8-Flash-Next-exl3-3.50bpw_hq_h6_ng6",
  "providers": {
    "exllama": {
      "name": "ExLlamaV3 (tabbyAPI)",
      "model": "Qwen3.8-Flash-Next-exl3-3.50bpw_hq_h6_ng6",
      "base_url": "http://localhost:5000/v1",
      "api_key": "exl3-key",
      "context_window": 262144,
      "max_tokens": 16384
    }
  },
  "max_turns": 0,
  "max_stuck_iterations": 5,
  "hard_iteration_cap": 200
}
```

The agent's ceilings live in config, not in the binary, because the right value depends on the model you point Nib at. Set them per provider (inside the provider block, where they override the top-level values) or once at the top level.

| Key | Default | Meaning |
| --- | --- | --- |
| `context_window` | provider-dependent | Token budget used for auto-compaction. Set this to what your server actually serves; tabbyAPI reports it as `n_ctx_train` on `/v1/models`. |
| `max_tokens` | provider default | Completion cap sent with each request. |
| `max_turns` | `0` (unbounded) | Hard per-prompt tool-loop ceiling. Leave it at `0`: a fixed low cap aborts valid work mid-task. |
| `max_stuck_iterations` | `5` | The real runaway guard. An iteration is its tool calls *and* their results; the loop stops when the identical pair occurs more times than this in one prompt. Raise it if you poll slow workflows that report unchanged status repeatedly. `0` disables it. |
| `hard_iteration_cap` | `200` | Backstop for a misbehaving provider emitting endless distinct calls. Far above any real task; `0` disables it. |

Repeating a command whose output changed (polling a build, watching a log) counts as progress and never trips the guard.

---

## 🧩 Skills

Nib loads skills from two places only: `<workspace>/.nib/skills/<name>/SKILL.md` and `~/.nib/skills/<name>/SKILL.md`. Skills belonging to other agent harnesses are deliberately not imported.

Only a name and description index is injected into the system prompt (a few hundred tokens rather than every skill body). The model fetches a full body on demand with the `skill` tool, and reads a skill's companion files the same way via `file`, since global skills live outside the workspace where `read_file` cannot reach them.

A skill with `disable-model-invocation: true` in its frontmatter is hidden from the model entirely. Invoke those yourself with `/skills run <name> [instructions]`.

---

## 🎨 Terminal UX Upgrades

- **Persistent Shell History (`~/.nib/history`)**: Up/Down arrow key recall cycles previous prompts.
- **Tab Autocomplete**: Tab key completes `/slash` commands and `@file` workspace paths.
- **Tau-Style Context Compaction**: Auto-compacts conversation history above threshold or on-demand (`/compact`), generating structured goal/progress checkpoints while keeping recent turns intact.
- **Context Guardrails**: Automatically caps oversized tool outputs (e.g. huge file reads or command dumps) to prevent exhausting VRAM or model context.
- **TrueColor Themes**: Switch between Catppuccin Mocha, Tokyo Night, Nord, and Gruvbox Dark anytime (`/theme tokyonight`).
- **Markdown Tables**: Automatically parses GitHub-flavored markdown tables into Unicode rounded box-grid tables with column alignments (`:---:`, `---:`).
- **Multi-Language Syntax Highlighting**: Colorizes Dart, Python, Bash, JS/TS, SQL, JSON inside code block boxes (`╭─ dart ──╮`).
- **Unified Diff Highlighting**: `edit_file` renders colored diffs with red `-` deletions and green `+` additions.
- **Graceful Turn Cancellation**: Pressing `Ctrl+C` while a model is streaming or a tool is running aborts *only the active turn* and returns to `nib ❯ `.
- **One-Click Reverts (`/undo`)**: Undo any file change made by Nib with `/undo`.
- **Interactive Tool Confirmations (`/confirm`)**: Prompts before writing files or running destructive bash commands (`rm`, `git reset`).
- **Multi-Line & Code Paste**: Wrap multi-line prompts in `"""` or end lines with `\` for prompt continuation.
- **Session Durability**: Conversations are saved as JSONL to `~/.nib/sessions/` and can be inspected (`/sessions`) or resumed (`/resume`).

---

## ⌨ Slash Commands

- `/help` - Show all available commands
- `/undo` - Revert the last file change made by Nib
- `/compact [focus]` - Compact older conversation entries into structured checkpoint (Tau-style)
- `/theme [name]` - Switch TrueColor theme (`catppuccin`, `tokyonight`, `nord`, `gruvbox`)
- `/confirm` - Toggle interactive tool confirmation mode
- `/sessions` - List saved conversation transcripts
- `/resume [id]` - Resume a previous session
- `/config` - Show active profile, endpoints, and configured models
- `/provider [name]` - Switch active provider
- `/model [name]` - Display or change active model
- `/tools` - Inspect registered tools and their parameters
- `/skills [list|show|run|enable|disable|toggle|reload] [name]` - Manage skills. `run` invokes one directly, including skills marked `disable-model-invocation`, which the model cannot load itself
- `/history` - Display session message count & token usage
- `/system [prompt]` - Inspect or append to the system prompt
- `/clear` - Clear conversation history for a fresh turn
- `/mock` - Switch to offline mock simulation mode
- `/exit` - Exit Nib

---

## 🧪 Testing

```bash
dart test
```
All unit tests verify tool executions, undo snapshot rollback, diff rendering, prompt history persistence, and Tau-style compaction.
