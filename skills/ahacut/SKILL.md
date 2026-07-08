---
name: ahacut
description: "Generate timeline-synced motion-graphics b-roll video from subtitles (SRT), a plain script, or an audio file (mp3/wav) via the Ahacut platform. Use when the user wants b-roll, motion graphics, animated captions/typography, or to turn an SRT / script / voiceover into a downloadable video track."
license: MIT
compatibility: Requires curl. python3 or jq recommended (needed for audio uploads and `wait`). ffmpeg's ffprobe optional (auto-detects audio length). Get an API key at app.ahacut.com → API keys.
metadata:
  author: Ahacut
  version: "0.1.0"
  category: video
  website: https://ahacut.com
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/ahacut.sh *) Bash(curl *)
---

# Ahacut — AI Motion-Graphics B-Roll Engine

Turn what's being said into b-roll that's already in sync: upload subtitles, a script,
or an audio file and get back a full-length motion-graphics video track (animated text,
numbers, logos, concepts) timed to the words — rendered in the cloud, no local setup.

## Setup

Configure the API key once (get it at **app.ahacut.com → API keys**):

```bash
${CLAUDE_SKILL_DIR}/scripts/ahacut.sh login ak_xxxxxxxx
${CLAUDE_SKILL_DIR}/scripts/ahacut.sh status   # verify + show credit balance
```

(`AHACUT_API_KEY` env var also works and overrides the saved key.)

## Three input modes

| Mode | Command | Use when |
|------|---------|----------|
| **Subtitles (precise)** | `generate-srt <file.srt>` | You have an SRT — cuts land exactly on subtitle timings |
| **Script + duration** | `generate-text <file\|-> <seconds>` | Plain narration text; the AI splits it into scenes and paces them to fit the total length |
| **Audio (mp3/wav)** | `generate-audio <file> [seconds]` | A voiceover/clip — it's transcribed to subtitles, b-roll is generated, and your original audio is muxed back under the video |

Each `generate-*` returns a **job** (with an `id` and a `hold_credits` estimate). Generation runs
async in the cloud — poll it with `wait <id>` (or `job <id>`), then read the result URLs.

## All commands

```
login <key> | logout | status | limits | list
generate-srt <file.srt>
generate-text <file|-> <seconds>
generate-audio <file> [seconds]
job <id>                    # status + result download URLs
wait <id> [timeout=1800]    # poll until done/failed, prints the final job
download <id> [out.mp4]     # save finished video LOCALLY, prints the local path
```

All go through `${CLAUDE_SKILL_DIR}/scripts/ahacut.sh`. Output is JSON — read `.job.status`
(`queued → authoring → render_ready → running → done|failed`) and, when `done`,
`.job.result.with_audio` / `.job.result.broll` (signed download URLs) and `.job.charged_credits`.

## Delivering the result (important)

The result URLs are **remote signed links**. Most agent frameworks can only hand the user a
**local file**, not a URL — so after the job is `done`, **download it to a local file first**,
then deliver that path:

```bash
$S wait <job_id>
LOCAL=$($S download <job_id>)     # saves the mp4 locally, prints its absolute path
# now deliver "$LOCAL" via your normal file-delivery mechanism
```

Prefer `.with_audio` (b-roll + the original voiceover) over `.broll` (visuals only) — `download`
picks `.with_audio` automatically when present. Do **not** pass a remote URL to a delivery tool
that expects a local file (that yields an empty/failed artifact).

## Workflow patterns

### From an SRT (most precise)
```bash
S=${CLAUDE_SKILL_DIR}/scripts/ahacut.sh
$S generate-srt captions.srt            # -> note the job id
$S wait <job_id>                        # waits, prints final job with result URLs
# download the track from .job.result.with_audio (or .broll)
```

### From a script + length
```bash
$S generate-text script.txt 90          # 90-second video; or:  echo "my script" | $S generate-text - 90
$S wait <job_id>
```

### From a voiceover
```bash
$S generate-audio voiceover.mp3         # auto-detects length if ffprobe present; else: generate-audio voiceover.mp3 120
$S wait <job_id>
```

## Notes for the agent

- **Check `status` / `limits` first** if unsure — `limits` shows max file size, max video length,
  whether audio mode is enabled, and the trial cap.
- **Cost**: jobs hold credits up front (≈ seconds × rate) and settle on completion; a failed render
  is auto-refunded. Tell the user the `hold_credits` / `charged_credits` from the JSON.
- **Don't poll in a tight loop** — use `wait`, which backs off (4s) and prints progress.
- Audio mode needs the server to have object storage + the speech-to-text backend enabled; if
  `limits.audioEnabled` is false, use SRT or text mode instead.
- Never print the full API key back to the user.
