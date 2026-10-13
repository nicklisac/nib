# ✒ Nib

A minimalist terminal CLI coding agent inspired by **Pi** (by Mario Zechner `@badlogic`) and **Tau** (Hugging Face `twotimespi.dev`), written entirely in **Dart**.

Nib is not a windowed TUI or full-screen GUI—it is a pure terminal streaming CLI with ANSI formatting, live token streaming, interactive tool execution blocks, persistent shell readline history, Tau-style context compaction, and multi-language syntax highlighting.

---

## 💭 Why Nib?

**The name.** A nib ✒ is the tip of a pen, the small part that actually touches the page. That's the idea here: a small tool that does the writing and little else.

**Why Dart.** Dart is an underrated language for command-line tools:

- **One file to install.** It compiles to a standalone binary (~11MB), so there's no Node, Python or package manager to set up first.
- **Starts instantly.** It launches in a fraction of a second, which matters for something you open and close all day.
- **Good at streaming.** Async and streams are built into the language, which suits a program whose main job is reading tokens as they arrive.
- **Hard to break quietly.** Static types and null safety catch a lot of mistakes before they ever run.
- **Runs anywhere.** Linux, macOS and Windows from the same code.

**What this is.** Nib is a personal and research project: a place to explore how a coding agent should feel to use, and what's the least it needs to be useful. It's built in the open, and anyone is welcome to use it, fork it or borrow ideas from it.

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
│   ├── config.dart         # ~/.nib/config.json & standard environment variable auto-detection
│   ├── session.dart        # Message transcript, token accounting & ~/.nib/sessions/ persistence
│   ├── skills.dart         # Skill discovery and the lazy name/description index
│   ├── builtin_skills.dart # The `nib` skill baked into the binary, so Nib can explain itself
│   ├── updater.dart        # `nib update` self-updater
│   ├── undo_manager.dart   # Snapshot tracker powering one-click /undo
│   ├── approval_manager.dart# Interactive tool confirmation checks (/confirm)
│   └── tool.dart           # AgentTool interface & schema builders
├── tools/                  # Application tools layer
│   ├── bash_tool.dart      # Shell command execution with timeout & output capture
│   ├── read_file_tool.dart # Numbered line reading with range slices
│   ├── write_file_tool.dart# File creation & overwrite (tracked in undo stack)
│   ├── edit_file_tool.dart # Surgical exact search & replace (with unified color diffs)
│   ├── list_dir_tool.dart  # Directory and file tree listing
│   ├── search_files_tool.dart# Regex & pattern search across files
│   ├── skill_tool.dart     # Load full instructions of named agent skills
│   ├── web_search_tool.dart# Web search via configurable provider (Exa API)
│   ├── search_provider.dart# Web search provider options
│   └── web_fetch_tool.dart # URL fetcher converting web pages to clean markdown
└── ui/                     # Terminal CLI UI layer
    ├── ansi.dart           # ANSI colors, banners, and formatters
    ├── theme.dart          # 24-bit TrueColor theme engine (Catppuccin, Tokyo Night, Nord, Gruvbox)
    ├── cli_ui.dart         # Pure stdout streaming UI with box-drawing tool cards & multi-line input
    ├── prompt_reader.dart  # Interactive readline with Up/Down history recall & Tab completion
    ├── provider_wizard.dart# First-run and `/setup` provider wizard
    ├── key_binding.dart    # Default key bindings
    ├── autocomplete.dart   # Prefix & fuzzy matching for slash commands and @file mentions
    ├── diff_formatter.dart # Color unified diff generator (+green / -red)
    ├── markdown_renderer.dart# TrueColor syntax highlighter for Dart, Python, Bash, JSON, SQL, etc.
    ├── spinner.dart        # Braille spinner with elapsed time & live token streaming speed (tok/s)
    ├── status_bar.dart     # Docked status line displaying provider, model, tokens, and git workspace
    └── slash_commands.dart # Slash commands (/help, /compact, /undo, /theme, /confirm, /sessions, etc.)
```

---

## ⚡ Quick Start

### Installation

**Option A: One-line install (Standalone Binary, zero dependencies)**

No Dart SDK or compiler required:
```bash
curl -fsSL https://raw.githubusercontent.com/nicklisac/nib/main/install.sh | bash
```

To update Nib at any time to the latest release:
```bash
nib update
```

To cleanly uninstall Nib:
```bash
nib uninstall
```

**Option B: Clone and run directly (from source)**
```bash
git clone https://github.com/nicklisac/nib.git
cd nib
./nib
```
`./nib` auto-compiles an optimized kernel snapshot on launch (and rebuilds when any file changes), launching in ~70ms.

**Option C: Global install via Dart**
```bash
dart pub global activate --source git https://github.com/nicklisac/nib.git
nib
```

### First Run

The first time you run `nib` with no provider configured, it walks you through setup: pick OpenAI-compatible or Anthropic, enter a base URL and key, and it looks up the models your endpoint offers. It also asks which web search provider to use, and you can skip that and set it up later (just ask Nib). Run it again any time with `nib setup` or `/setup`.

Local and self-hosted servers don't need a key, so leave it blank. Your choices are saved to `~/.nib/config.json`.

Or skip the wizard and set a standard provider environment variable. Nib detects them automatically:

```bash
# Anthropic Claude (Messages API)
export ANTHROPIC_API_KEY="sk-ant-..."
nib

# OpenAI (or compatible API)
export OPENAI_API_KEY="sk-..."
nib

# OpenRouter
export OPENROUTER_API_KEY="sk-or-..."
nib

# Google Gemini
export GEMINI_API_KEY="..."
nib

# Local Ollama
export OLLAMA_BASE_URL="http://localhost:11434/v1"
nib
```

Or resume your previous conversation where you left off:
```bash
nib --resume
```

---

## ⚙️ Configuration (`~/.nib/config.json`)

To configure multiple named providers, custom base URLs, or local endpoints, create `~/.nib/config.json` (or `.nib/config.json` in your workspace):

```json
{
  "default_provider": "[provider name]",
  "default_model": "[model name]",
  "providers": {
    "anthropic": {
      "name": "Anthropic Claude",
      "model": "[model name]",
      "base_url": "https://api.anthropic.com",
      "api_key": "sk-ant-...",
      "context_window": 200000,
      "max_tokens": 8192
    },
    "openai": {
      "name": "OpenAI",
      "model": "[model name]",
      "base_url": "https://api.openai.com/v1",
      "api_key": "sk-...",
      "context_window": 128000,
      "max_tokens": 4096
    },
    "local": {
          "name": "Local Server (Ollama / vLLM / tabbyAPI)",
          "model": "Qwen3.8-Flash-Next",
          "base_url": "http://localhost:1234/v1",
          "api_key": "optional-key",
          "context_window": 262144,
          "max_tokens": 32768,
          "supports_images": true
    }
  },
  "search_provider": "exa",
  "max_turns": 0,
  "max_stuck_iterations": 5,
  "hard_iteration_cap": 200
}
```

The agent's ceilings live in config, not in the binary, because the right value depends on the model you point Nib at. Set them per provider (inside the provider block, where they override the top-level values) or once at the top level.

| Key | Default | Meaning |
| --- | --- | --- |
| `context_window` | provider-dependent | Token budget used for auto-compaction. Set this to what your provider serves; tabbyAPI reports it as `n_ctx_train` on `/v1/models`. |
| `max_tokens` | provider default | Completion cap sent with each request. |
| `supports_images` | unset (images allowed) | Set to `false` for a text-only model and Nib will warn and skip attached images instead of sending them. Set `true` to say the model handles vision. Set per provider. |
| `max_turns` | `0` (unbounded) | Hard per-prompt tool-loop ceiling. Leave it at `0`: a fixed low cap aborts valid work mid-task. |
| `max_stuck_iterations` | `5` | A runaway guard. An iteration is its tool calls *and* their results; the loop stops when the identical pair occurs more times than this in one prompt. Raise it if you poll slow workflows that report unchanged status repeatedly. `0` disables it. |
| `hard_iteration_cap` | `200` | Backstop for a misbehaving provider emitting endless distinct calls. Far above any real task; `0` disables it. |

Repeating a command whose output changed (polling a build, watching a log) counts as progress and never trips the guard.

---

## 🧩 Skills

Nib loads skills from two places only: `<workspace>/.nib/skills/<name>/SKILL.md` and `~/.nib/skills/<name>/SKILL.md`.

One skill ships inside Nib itself: `nib`. It covers the config file, slash commands, flags, providers and search setup, so on a fresh machine you can just ask Nib how it works or to help configure itself. If you want to build or change Nib, the project's own docs ([`docs/adr/`](docs/adr), [`CONTEXT.md`](CONTEXT.md)) live in this repo.

Only a name and description index is injected into the system prompt (a few hundred tokens rather than every skill body). The model fetches a full body on demand with the `skill` tool, and reads a skill's companion files the same way via `file`, since global skills live outside the workspace where `read_file` cannot reach them.

A skill with `disable-model-invocation: true` in its frontmatter is hidden from the model entirely. Invoke those yourself with `/skills run <name> [instructions]`.

---

## 🎨 Terminal UX Upgrades

- **Persistent Shell History (`~/.nib/history`)**: Up/Down arrow key recall cycles previous prompts.
- **Tab Autocomplete**: Tab key completes `/slash` commands and `@file` workspace paths.
- **Context Compaction**: Auto-compacts conversation history above threshold or on-demand (`/compact`), generating structured goal/progress checkpoints while keeping recent turns intact.
- **Context Guardrails**: Automatically caps oversized tool outputs (e.g. huge file reads or command dumps) to prevent exhausting VRAM or model context.
- **TrueColor Themes**: Switch between Catppuccin Mocha, Tokyo Night, Nord, Gruvbox, Dracula, Rosé Pine, One Dark, Monokai, Kanagawa, Everforest, Solarized, GitHub Dark and Synthwave anytime (`/theme tokyonight`).
- **Markdown Tables**: Automatically parses GitHub-flavored markdown tables into Unicode rounded box-grid tables with column alignments (`:---:`, `---:`).
- **Multi-Language Syntax Highlighting**: Colorizes Dart, Python, Bash, JS/TS, SQL, JSON inside code block boxes (`╭─ dart ──╮`).
- **Unified Diff Highlighting**: `edit_file` renders colored diffs with red `-` deletions and green `+` additions.
- **Graceful Turn Cancellation**: Pressing `Esc` or `Ctrl+C` while a model is streaming or a tool is running aborts *only the active turn*. Anything you had typed is kept.
- **One-Click Reverts (`/undo`)**: Undo any file change made by Nib with `/undo`.
- **Interactive Tool Confirmations (`/confirm`)**: Prompts before writing files or running destructive bash commands (`rm`, `git reset`).
- **Multi-Line & Code Paste**: Pasting never sends. Wrap multi-line prompts in `"""`, end lines with `\`, or press `Ctrl+J` for a new line.
- **Session Durability**: Conversations are saved as JSONL to `~/.nib/sessions/` and can be inspected (`/sessions`) or resumed (`/resume`).

---

## ⌨ Slash Commands

- `/help` - Show all available commands
- `/undo` - Revert the last file change made by Nib
- `/compact [focus]` - Compact older conversation entries into structured checkpoint (Tau-style)
- `/theme [name]` - Switch TrueColor theme (try `/theme` for the full list)
- `/thinking [level]` - Show or set the thinking level (off to max)
- `/image [path]` - Attach an image from a path or the clipboard
- `/confirm` - Toggle interactive tool confirmation mode
- `/sessions` - List saved conversation transcripts
- `/resume [id]` - Resume a previous session
- `/config` - Show active profile, endpoints, and configured models
- `/provider [name]` - Switch active provider
- `/setup` - Run the provider setup wizard again
- `/model [name]` - Display or change active model
- `/tools` - Inspect registered tools and their parameters
- `/skills [list|show|run|enable|disable|toggle|reload] [name]` - Manage skills. `run` invokes one directly, including skills marked `disable-model-invocation`, which the model cannot load itself
- `/history` - Display session message count & token usage
- `/system [prompt]` - Inspect or append to the system prompt
- `/new` - Start a brand new session
- `/clear` - Clear conversation history for a fresh turn
- `/redraw` - Redraw the screen
- `/exit` - Exit Nib

---

## ⌨ Keys

| Key | What it does |
| --- | --- |
| `Esc` / `Ctrl+C` | Stop the current turn. Your draft is kept. |
| `Ctrl+C` twice | At an empty or idle prompt, press it twice within two seconds to exit. (`Ctrl+D` on an empty line exits too.) |
| `Enter` | Send. On an empty line, sends the message you queued. |
| `Alt+Enter` | Queue what you typed while a turn is running. |
| `Ctrl+J` | New line instead of sending. |
| `Ctrl+V` | Paste (text or an image from the clipboard). |
| `Tab` | Complete a `/command` or `@file`. |
| `↑` / `↓` | Step through previous prompts. |
| `Ctrl+A` / `Ctrl+E` | Jump to the start / end of the line. |
| `Ctrl+U` | Delete from the start of the line to the cursor. |
| `Ctrl+W` | Delete the previous word. |
| `Alt+←` / `Alt+→` | Move by word. |
| `Shift+Tab` | Cycle the thinking level. |
| `Ctrl+T` | Show or hide the thinking trace. |
| `Ctrl+O` | Switch tool output between compact and expanded. |
| `Ctrl+R` | Open the session picker. |
| `Ctrl+P` | Cycle through your configured models. |
| `Ctrl+L` | Redraw the screen. |

---

## 🧪 Testing

```bash
dart test
```
All unit tests verify tool executions, undo snapshot rollback, diff rendering, prompt history persistence, and Tau-style compaction.
