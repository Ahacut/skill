# Ahacut Agent Skill

Drive [Ahacut](https://ahacut.com) — timeline-synced motion-graphics **b-roll** generation —
from your AI coding agent (Claude Code, Codex, Cursor, or anything that can run a shell command).

Give your agent an SRT, a script, or an audio file; it creates a render job through the Ahacut
**Open API** and hands back a downloadable video track that's already in sync with the words.

## Install

### With the `skills` CLI (recommended)

```bash
npx skills add ahacut/skill
```

This installs the `ahacut` skill (`SKILL.md` + `scripts/`) into `~/.claude/skills/ahacut`,
where Claude Code (and other agents) pick it up automatically.

```bash
npx skills list              # see installed skills
npx skills remove ahacut     # uninstall
```

### Manual

Copy the skill folder into wherever your agent looks for skills:

- **Claude Code** — user-level `~/.claude/skills/ahacut`, or project-level `<repo>/.claude/skills/ahacut`
  ```bash
  git clone https://github.com/ahacut/skill ahacut-skill
  mkdir -p ~/.claude/skills
  cp -R ahacut-skill/skills/ahacut ~/.claude/skills/ahacut
  ```
- **Codex / Cursor / other** — copy the same `skills/ahacut` folder into that tool's skills/commands
  directory, or point it at `skills/ahacut/scripts/ahacut.sh` as a shell tool.

## Set up

1. **Get an API key** at **app.ahacut.com → API keys** (one-time; starts with `ak_`).
2. **Log in** (saves the key to `~/.config/ahacut/config`):
   ```bash
   ~/.claude/skills/ahacut/scripts/ahacut.sh login ak_xxxxxxxx
   ~/.claude/skills/ahacut/scripts/ahacut.sh status
   ```

Then just ask your agent things like *"make b-roll for captions.srt"* or
*"turn voiceover.mp3 into a b-roll track"* — it'll call the CLI, wait for the render, and give you the link.

## What's here

```
skills/ahacut/
  SKILL.md            # the skill manifest (name, description, usage) agents load
  scripts/ahacut.sh   # zero-dep curl CLI hitting the Ahacut Open API (/open/*)
```

## Requirements

- `curl` (required)
- `python3` **or** `jq` (recommended — needed for audio uploads and `wait`)
- `ffprobe` (optional — auto-detects audio length for `generate-audio`)

## Config

- `AHACUT_API_KEY` — overrides the saved key
- `AHACUT_API_BASE` — defaults to `https://api.ahacut.com`

See [`skills/ahacut/SKILL.md`](skills/ahacut/SKILL.md) for the full command reference and workflows.

MIT licensed.
