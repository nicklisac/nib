/// Built-in skills embedded into the Nib binary.
///
/// These skills are automatically provisioned to `~/.nib/skills/` on first launch
/// (or updated if newer), ensuring Nib is always self-referential on any machine
/// even when running as a standalone compiled binary.
class BuiltInSkills {
  static const Map<String, String> skills = {
    'nib': r'''---
name: nib
description: Understand and configure Nib itself — config schema (~/.nib/config.json), slash commands, CLI flags, providers, and search setup.
---

# Nib Reference Guide

Nib is a minimalist terminal CLI coding agent written in Dart.
Home repository: https://github.com/nicklisac/nib

## Configuration (~/.nib/config.json)

Nib loads configuration from `.nib/config.json` in the current workspace, or `~/.nib/config.json` globally.

### JSON Schema & Example

```json
{
  "default_provider": "openai",
  "search_provider": "exa",
  "search_api_key": "your-key-here",
  "context_window": 128000,
  "max_tokens": 4096,
  "thinking_level": "medium",
  "experiments": {
    "rewind_reads": false
  },
  "providers": {
    "openai": {
      "name": "openai",
      "model": "gpt-4o",
      "base_url": "https://api.openai.com/v1",
      "api_key": "sk-...",
      "protocol": "openai",
      "context_window": 128000,
      "max_tokens": 4096,
      "supports_images": true
    },
    "anthropic": {
      "name": "anthropic",
      "model": "claude-3-7-sonnet-20250219",
      "base_url": "https://api.anthropic.com",
      "api_key": "sk-ant-...",
      "protocol": "anthropic"
    },
    "openrouter": {
      "name": "openrouter",
      "model": "anthropic/claude-3.7-sonnet",
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "sk-or-...",
      "protocol": "openai"
    },
    "ollama": {
      "name": "ollama",
      "model": "llama3.1",
      "base_url": "http://localhost:11434/v1",
      "api_key": "ollama",
      "protocol": "openai"
    }
  }
}
```

### Supported Web Search Providers
Every key field (`api_key` on a provider and `search_api_key`) accepts either the key itself or the NAME of an environment variable, such as `"api_key": "OPENAI_API_KEY"`. A variable name is looked up at launch, so the secret never has to sit in the file. If the named variable is not set, Nib says so and sends no key.

- **Exa**: `"search_provider": "exa"`, requires `search_api_key` or `EXA_API_KEY`.
- **Tavily**: `"search_provider": "tavily"`, requires `search_api_key` or `TAVILY_API_KEY`.
- **Brave**: `"search_provider": "brave"`, requires `search_api_key` or `BRAVE_API_KEY`.

### Thinking Levels
- Values: `off`, `minimal`, `low`, `medium`, `high`, `extreme`.
- Configured via `"thinking_level"` in `~/.nib/config.json` or interactively with `/thinking <level>`.

## Interactive Slash Commands

Inside Nib's interactive prompt:
- `/help`: Show command help.
- `/config`: Show current configuration and active provider details.
- `/setup`: Launch the interactive provider & search configuration wizard.
- `/provider [name]`: Switch the active provider profile.
- `/model [name]`: Switch the active model for the current provider.
- `/thinking [level]`: View or change reasoning level (`off` to `extreme`).
- `/compact [tokens]`: Manually trigger transcript compaction to summarize earlier context.
- `/clear`: Clear conversation history and start a clean transcript.
- `/undo`: Revert the last file change made by Nib.
- `/skills`: List all active and workspace skills (`/skills show <name>`, `/skills toggle <name>`).
- `/sessions`: Browse and pick previous conversation sessions to resume.
- `/resume [id]`: Resume a previous session by ID.
- `/theme [name]`: Switch TrueColor terminal theme (`catppuccin`, `tokyonight`, `dracula`, etc.).
- `/image <path>`: Attach an image to the next turn (supports vision models).
- `/confirm`: Toggle safety confirmation before executing destructive commands or writing files.
- `/exit` or `/quit`: Exit Nib.

## CLI Flags & Commands

- `nib`: Start interactive session.
- `nib "prompt"`: Run a one-shot prompt and exit.
- `nib -r`, `nib --resume`: Resume the most recent session.
- `nib --setup`: Run the provider setup wizard.
- `nib update`: Update Nib standalone binary to the latest release from GitHub.
- `nib --mock`: Run in offline demo mode without calling external APIs.
- `nib -p <provider>`: Launch with a specific provider profile.
- `nib -m <model>`: Launch with a specific model.
- `nib -t <theme>`: Launch with a specific theme.
- `nib --confirm`: Require human approval before running tools.
- `nib --version`: Print current version.

## Tools Overview

Nib operates with modular tools guarded to the active workspace:
- `read_file`: Inspect file contents.
- `edit_file`: Make precise, exact replacements in files.
- `write_file`: Create new files or full rewrites.
- `bash`: Run shell commands with progress descriptions.
- `list_dir`: Directory listing (respects gitignore).
- `search_files`: Fast code search across files.
- `web_search`: Query Exa, Tavily, or Brave for web results.
- `web_fetch`: Fetch web page contents.
- `skill`: Lazy-load instructions for named agent skills.
''',
  };
}
