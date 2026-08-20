#!/usr/bin/env bash
# Ahacut API helper — turn subtitles / a script / audio into timeline-synced
# motion-graphics b-roll video. Zero hard deps beyond curl (python3 OR jq
# recommended for audio uploads and `wait`).
set -euo pipefail

# ─── Config ───────────────────────────────────────────────
CONFIG_DIR="${HOME}/.config/ahacut"
CONFIG_FILE="${CONFIG_DIR}/config"
API_BASE="${AHACUT_API_BASE:-https://api.ahacut.com}"

load_key() {
  if [ -n "${AHACUT_API_KEY:-}" ]; then echo "$AHACUT_API_KEY"; return; fi
  if [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; return; fi
  echo "ERROR: No API key. Run: ahacut.sh login <API_KEY>  (get one at app.ahacut.com -> API keys)" >&2
  exit 1
}

# JSON-encode stdin into a JSON string literal (handles quotes/newlines/unicode).
json_str() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
  elif command -v jq >/dev/null 2>&1; then
    jq -Rs .
  else
    # minimal fallback: escape \  "  newline  tab  CR
    local s; s=$(cat); s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}
    s=${s//$'\r'/}; s=${s//$'\n'/\\n}; printf '"%s"' "$s"
  fi
}

# Extract a top-level/nested field from a JSON object on stdin. Usage: jget '.job.id'
jget() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].strip(".").split("."):
    if k=="": continue
    d = (d or {}).get(k) if isinstance(d,dict) else None
print("" if d is None else d)
' "$1"
  elif command -v jq >/dev/null 2>&1; then
    jq -r "$1 // \"\""
  else
    echo ""
  fi
}

api() {
  local method="$1" path="$2"; shift 2
  local key; key=$(load_key)
  curl -sS -X "$method" \
    -H "Content-Type: application/json" \
    -H "X-Ahacut-Key: $key" \
    "${API_BASE}/open${path}" "$@"
}

# ─── Commands ─────────────────────────────────────────────

cmd_login() {
  local key="${1:-}"
  [ -z "$key" ] && { echo "Usage: ahacut.sh login <API_KEY>"; exit 1; }
  [[ "$key" == ak_* ]] || { echo "ERROR: API key must start with ak_"; exit 1; }
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  printf '%s' "$key" > "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
  echo "API key saved to $CONFIG_FILE"
}

cmd_logout() { rm -f "$CONFIG_FILE"; echo "API key removed."; }

cmd_status() {
  local key; key=$(load_key)
  echo "API base: $API_BASE"
  echo "API key:  ${key:0:12}..."
  api GET /me
}

cmd_limits() { api GET /limits; }
cmd_list()   { api GET /jobs; }

cmd_job() {
  local id="${1:-}"; [ -z "$id" ] && { echo "Usage: ahacut.sh job <job_id>"; exit 1; }
  api GET "/jobs/${id}"
}

# --overlay on generate commands: render a TRANSPARENT overlay track (ProRes 4444 .mov
# with alpha) meant to sit ON TOP of talking-head footage, instead of full-screen b-roll.
# --vertical on generate commands: render 9:16 (1080x1920) instead of the 16:9 default.
# There is no source video to infer the frame from, so vertical footage MUST say so here.
# Flags may appear anywhere after the command; positional args keep their order.

# generate-text <file|-> <seconds> [--overlay]   (script + total length -> AI segments + paces)
cmd_generate_text() {
  local file="" secs="" overlay="" aspect=""
  local palette="" brief_txt="" want_palette=0 want_brief=0
  local ctx_txt=""
  local a
  for a in "$@"; do
    case "$a" in
      --overlay) overlay=',"overlay":true' ;;
      --vertical|--portrait) aspect=',"aspect":"9:16"' ;;
      --palette=*) palette=",\"palette\":\"${a#--palette=}\"" ;;
      --palette) want_palette=1 ;;
      --style-brief=*) brief_txt="${a#--style-brief=}" ;;
      --context=*) ctx_txt="${a#--context=}" ;;
      --context-file=*) ctx_txt=$(cat "${a#--context-file=}") ;;
      --style-brief) want_brief=1 ;;
      *) if [ "$want_palette" = 1 ]; then palette=",\"palette\":\"$a\""; want_palette=0;
         elif [ "$want_brief" = 1 ]; then brief_txt="$a"; want_brief=0;
         elif [ -z "$file" ]; then file="$a"; elif [ -z "$secs" ]; then secs="$a"; fi ;;
    esac
  done
  { [ -z "$file" ] || [ -z "$secs" ]; } && { echo "Usage: ahacut.sh generate-text <file|-> <seconds> [--overlay] [--vertical] [--context=<text>|--context-file=<path>]"; exit 1; }
  local text; if [ "$file" = "-" ]; then text=$(cat); else text=$(cat "$file"); fi
  local tjson; tjson=$(printf '%s' "$text" | json_str)
  local brief=""
  [ -n "$brief_txt" ] && brief=",\"style_brief\":$(printf '%s' "$brief_txt" | json_str)"
  # 调用方上下文:agent 分批调用时,上游掌握整片而分幕器只看得见这一单 —— 把宏观视角带上去。
  local cctx=""
  [ -n "$ctx_txt" ] && cctx=",\"caller_context\":$(printf '%s' "$ctx_txt" | json_str)"
  api POST /jobs -d "{\"input_kind\":\"text\",\"text\":${tjson},\"duration_seconds\":${secs}${overlay}${aspect}${palette}${brief}${cctx}}"
}

# generate-srt <file> [--overlay] [--vertical]   (precise: cuts land on subtitle timings)
cmd_generate_srt() {
  local file="" overlay="" aspect=""
  local palette="" brief_txt="" want_palette=0 want_brief=0
  local ctx_txt=""
  local a
  for a in "$@"; do
    case "$a" in
      --overlay) overlay=',"overlay":true' ;;
      --vertical|--portrait) aspect=',"aspect":"9:16"' ;;
      --palette=*) palette=",\"palette\":\"${a#--palette=}\"" ;;
      --palette) want_palette=1 ;;
      --style-brief=*) brief_txt="${a#--style-brief=}" ;;
      --context=*) ctx_txt="${a#--context=}" ;;
      --context-file=*) ctx_txt=$(cat "${a#--context-file=}") ;;
      --style-brief) want_brief=1 ;;
      *) if [ "$want_palette" = 1 ]; then palette=",\"palette\":\"$a\""; want_palette=0;
         elif [ "$want_brief" = 1 ]; then brief_txt="$a"; want_brief=0;
         elif [ -z "$file" ]; then file="$a"; fi ;;
    esac
  done
  [ -z "$file" ] && { echo "Usage: ahacut.sh generate-srt <file.srt> [--overlay] [--vertical] [--context=<text>|--context-file=<path>]"; exit 1; }
  local sjson; sjson=$(cat "$file" | json_str)
  local brief=""
  [ -n "$brief_txt" ] && brief=",\"style_brief\":$(printf '%s' "$brief_txt" | json_str)"
  # 调用方上下文:agent 分批调用时,上游掌握整片而分幕器只看得见这一单 —— 把宏观视角带上去。
  local cctx=""
  [ -n "$ctx_txt" ] && cctx=",\"caller_context\":$(printf '%s' "$ctx_txt" | json_str)"
  api POST /jobs -d "{\"input_kind\":\"srt\",\"srt\":${sjson}${overlay}${aspect}${palette}${brief}${cctx}}"
}

# generate-audio <file> [seconds] [--overlay] [--vertical]   (mp3/wav -> speech-to-text -> b-roll, original audio muxed back)
cmd_generate_audio() {
  local file="" secs="" overlay="" aspect=""
  local palette="" brief_txt="" want_palette=0 want_brief=0
  local ctx_txt=""
  local a
  for a in "$@"; do
    case "$a" in
      --overlay) overlay=',"overlay":true' ;;
      --vertical|--portrait) aspect=',"aspect":"9:16"' ;;
      --palette=*) palette=",\"palette\":\"${a#--palette=}\"" ;;
      --palette) want_palette=1 ;;
      --style-brief=*) brief_txt="${a#--style-brief=}" ;;
      --context=*) ctx_txt="${a#--context=}" ;;
      --context-file=*) ctx_txt=$(cat "${a#--context-file=}") ;;
      --style-brief) want_brief=1 ;;
      *) if [ "$want_palette" = 1 ]; then palette=",\"palette\":\"$a\""; want_palette=0;
         elif [ "$want_brief" = 1 ]; then brief_txt="$a"; want_brief=0;
         elif [ -z "$file" ]; then file="$a"; elif [ -z "$secs" ]; then secs="$a"; fi ;;
    esac
  done
  [ -z "$file" ] && { echo "Usage: ahacut.sh generate-audio <file> [seconds] [--overlay] [--vertical] [--context=<text>|--context-file=<path>]"; exit 1; }
  [ -f "$file" ] || { echo "ERROR: file not found: $file"; exit 1; }
  local ext bytes; ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
  bytes=$(wc -c < "$file" | tr -d ' ')
  # duration: arg > ffprobe
  if [ -z "$secs" ]; then
    if command -v ffprobe >/dev/null 2>&1; then
      secs=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | cut -d. -f1 || true)
    fi
  fi
  [ -z "$secs" ] && { echo "ERROR: pass duration in seconds (ffprobe not found to auto-detect)"; exit 1; }
  echo "Requesting upload URL (${ext}, $((bytes/1024)) KB)…" >&2
  local up key url
  up=$(api POST /jobs/upload-url -d "{\"ext\":\"${ext}\",\"bytes\":${bytes}}")
  key=$(printf '%s' "$up" | jget '.key'); url=$(printf '%s' "$up" | jget '.url')
  [ -z "$key" ] || [ -z "$url" ] && { echo "Upload-url failed: $up"; exit 1; }
  echo "Uploading audio to storage…" >&2
  curl -sS -X PUT -H "Content-Type: application/octet-stream" --upload-file "$file" "$url" >/dev/null
  local brief=""
  [ -n "$brief_txt" ] && brief=",\"style_brief\":$(printf '%s' "$brief_txt" | json_str)"
  local cctx=""
  [ -n "$ctx_txt" ] && cctx=",\"caller_context\":$(printf '%s' "$ctx_txt" | json_str)"
  api POST /jobs -d "{\"input_kind\":\"audio\",\"audio_key\":\"${key}\",\"duration_seconds\":${secs}${overlay}${aspect}${palette}${brief}${cctx}}"
}

# wait <job_id> [timeout_sec]   — poll until done/failed, then print the job
cmd_wait() {
  local id="${1:-}" timeout="${2:-1800}"
  [ -z "$id" ] && { echo "Usage: ahacut.sh wait <job_id> [timeout_sec]"; exit 1; }
  local waited=0 status="" last=""
  while [ "$waited" -lt "$timeout" ]; do
    local res; res=$(api GET "/jobs/${id}")
    status=$(printf '%s' "$res" | jget '.job.status')
    local prog; prog=$(printf '%s' "$res" | jget '.job.progress')
    if [ "$status" != "$last" ] || [ -n "$prog" ]; then
      echo "  [${waited}s] status=${status:-?} progress=${prog:-0}%" >&2; last="$status"
    fi
    case "$status" in
      done|failed) printf '%s\n' "$res"; [ "$status" = "done" ] && return 0 || return 1 ;;
      "") echo "  (could not read status — need python3 or jq for wait)" >&2; printf '%s\n' "$res"; return 0 ;;
    esac
    sleep 4; waited=$((waited+4))
  done
  echo "Timed out after ${timeout}s (job may still be running)." >&2; return 1
}

# download <job_id> [out] [--artifact=<name>]  — save a finished artifact to a LOCAL file
# Many agent frameworks can only deliver a local file path, not a remote URL — use this
# after the job is done, then hand the printed local path to your delivery step.
# Default artifact: the final video (with_audio -> broll -> overlay). Other artifact
# names: jy_draft (JianYing draft zip), scenes_zip, sfx_wav, sfx_cues, sfx_jianying.
cmd_download() {
  local id="" out="" artifact="" a
  for a in "$@"; do
    case "$a" in
      --artifact=*) artifact="${a#--artifact=}" ;;
      *) if [ -z "$id" ]; then id="$a"; elif [ -z "$out" ]; then out="$a"; fi ;;
    esac
  done
  [ -z "$id" ] && { echo "Usage: ahacut.sh download <job_id> [out] [--artifact=<name>]"; exit 1; }
  local res status; res=$(api GET "/jobs/${id}")
  status=$(printf '%s' "$res" | jget '.job.status')
  [ "$status" != "done" ] && { echo "ERROR: job $id not done (status=${status:-?}); run: ahacut.sh wait $id" >&2; exit 1; }
  local url ext="mp4"
  if [ -n "$artifact" ]; then
    url=$(printf '%s' "$res" | jget ".job.result.${artifact}")
    case "$artifact" in
      jy_draft|scenes_zip) ext="zip" ;;
      overlay) ext="mov" ;;
      sfx_wav) ext="wav" ;;
      sfx_cues) ext="txt" ;;
      sfx_jianying) ext="json" ;;
    esac
    [ -z "$url" ] && { echo "ERROR: artifact '${artifact}' not present on job $id" >&2; exit 1; }
  else
    # prefer the final video with original audio; fall back to the b-roll track;
    # overlay jobs only have the transparent .mov track
    url=$(printf '%s' "$res" | jget '.job.result.with_audio')
    [ -z "$url" ] && url=$(printf '%s' "$res" | jget '.job.result.broll')
    if [ -z "$url" ]; then
      url=$(printf '%s' "$res" | jget '.job.result.overlay'); ext="mov"
    fi
    [ -z "$url" ] && { echo "ERROR: no video URL in result: $res" >&2; exit 1; }
  fi
  [ -z "$out" ] && out="./ahacut-${id}${artifact:+-$artifact}.${ext}"
  echo "Downloading ${artifact:-video} → ${out}…" >&2
  curl -sSL -o "$out" "$url"
  # print the ABSOLUTE local path (stdout) so the caller can deliver it directly
  ( cd "$(dirname "$out")" && printf '%s/%s\n' "$(pwd)" "$(basename "$out")" )
}

# ─── JianYing (剪映) draft install ────────────────────────
# The jy_draft artifact IS a JianYing draft folder: every scene clip already placed
# at its exact timecode. `draft <id>` downloads it and installs it straight into the
# local JianYing drafts directory — reopen JianYing and the draft is in the list.

# Locate the JianYing drafts directory (macOS / Git-Bash on Windows / WSL). Empty if not found.
jy_drafts_dir() {
  local d
  d="${HOME}/Movies/JianyingPro/User Data/Projects/com.lveditor.draft"
  [ -d "$d" ] && { printf '%s' "$d"; return; }
  if [ -n "${LOCALAPPDATA:-}" ]; then
    local la="$LOCALAPPDATA"
    command -v cygpath >/dev/null 2>&1 && la=$(cygpath -u "$la")
    d="${la}/JianyingPro/User Data/Projects/com.lveditor.draft"
    [ -d "$d" ] && { printf '%s' "$d"; return; }
  fi
  for d in /mnt/c/Users/*/AppData/Local/JianyingPro/"User Data"/Projects/com.lveditor.draft; do
    [ -d "$d" ] && { printf '%s' "$d"; return; }
  done
  printf ''
}

# JianYing running? Writing a draft while it runs makes it flag the draft as corrupted.
jy_running() {
  pgrep -f "VideoFusion-macOS.app/Contents/MacOS" >/dev/null 2>&1 && return 0
  command -v tasklist >/dev/null 2>&1 && tasklist 2>/dev/null | grep -qi "JianyingPro.exe" && return 0
  return 1
}

# Unzip with whatever this machine has (the zip is plain store: unzip / bsdtar / python3 all work).
extract_zip() {
  local zip="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then unzip -q "$zip" -d "$dest"
  elif command -v tar >/dev/null 2>&1 && tar -tf "$zip" >/dev/null 2>&1; then tar -xf "$zip" -C "$dest"
  elif command -v python3 >/dev/null 2>&1; then python3 -m zipfile -e "$zip" "$dest"
  else echo "ERROR: need unzip, bsdtar or python3 to extract the draft zip" >&2; return 1; fi
}

# draft <job_id> [target_dir] [--force]
# No target_dir: install into the local JianYing drafts directory (the whole point).
# With target_dir: just extract there (e.g. to hand the folder to another machine).
cmd_draft() {
  local id="" target="" force=0 a
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      *) if [ -z "$id" ]; then id="$a"; elif [ -z "$target" ]; then target="$a"; fi ;;
    esac
  done
  [ -z "$id" ] && { echo "Usage: ahacut.sh draft <job_id> [target_dir] [--force]"; exit 1; }

  local res status url
  res=$(api GET "/jobs/${id}")
  status=$(printf '%s' "$res" | jget '.job.status')
  [ "$status" != "done" ] && { echo "ERROR: job $id not done (status=${status:-?}); run: ahacut.sh wait $id" >&2; exit 1; }
  url=$(printf '%s' "$res" | jget '.job.result.jy_draft')
  [ -z "$url" ] && { echo "ERROR: this job has no JianYing draft (jy_draft) artifact — jobs rendered before 2026-08-19 predate it" >&2; exit 1; }

  local install=1
  if [ -n "$target" ]; then
    install=0
  else
    target=$(jy_drafts_dir)
    if [ -z "$target" ]; then
      echo "JianYing drafts directory not found on this machine — extracting to the current directory instead." >&2
      echo "If JianYing isn't installed: get it at https://lv.ulikecam.com/ , open it once (first launch" >&2
      echo "creates the drafts directory), then re-run this command." >&2
      echo "Or move the ahacut_* folder into JianYing's drafts directory yourself:" >&2
      echo "  macOS:   ~/Movies/JianyingPro/User Data/Projects/com.lveditor.draft/" >&2
      echo "  Windows: %LOCALAPPDATA%\\JianyingPro\\User Data\\Projects\\com.lveditor.draft\\" >&2
      echo "(The extracted folder also ships human-friendly installers: Install-Mac.command /" >&2
      echo " Install-Windows.bat — double-click, for when a person finishes this by hand.)" >&2
      target="."; install=0
    fi
  fi

  if [ "$install" = 1 ] && jy_running; then
    if [ "$force" = 1 ]; then
      echo "WARNING: JianYing looks running; --force given, installing anyway (it may flag the draft as corrupted — if so, quit JianYing and re-run)." >&2
    else
      echo "ERROR: JianYing (剪映) is running. Quit it completely first — drafts written while it runs get" >&2
      echo "       mistaken for corrupted ones. Then re-run this command (or pass --force)." >&2
      exit 1
    fi
  fi

  local tmp zip
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ahacut-draft.XXXXXX")
  zip="${tmp}/jy_draft.zip"
  echo "Downloading JianYing draft package…" >&2
  curl -sSL -o "$zip" "$url"
  extract_zip "$zip" "$tmp/x" || { rm -rf "$tmp"; exit 1; }

  local folder name
  folder=$(find "$tmp/x" -maxdepth 1 -type d -name 'ahacut_*' | head -1)
  [ -z "$folder" ] && { echo "ERROR: no ahacut_* draft folder inside the zip" >&2; rm -rf "$tmp"; exit 1; }
  name=$(basename "$folder")

  # name collision in the drafts list: keep both, suffix the new one
  local dest="${target}/${name}" n=2
  while [ -e "$dest" ]; do dest="${target}/${name}-${n}"; n=$((n+1)); done
  mkdir -p "$target"
  mv "$folder" "$dest"
  rm -rf "$tmp"

  if [ "$install" = 1 ]; then
    echo "Draft installed. Open JianYing (剪映) — look for \"$(basename "$dest")\" in the draft list;" >&2
    echo "every clip is already placed at its exact timecode." >&2
  fi
  # print the ABSOLUTE draft folder path (stdout) for the caller
  ( cd "$dest" && pwd )
}

cmd_help() {
  cat <<'HELP'
Ahacut CLI — timeline-synced motion-graphics b-roll from subtitles / script / audio

Setup:
  login <key>                      Save API key (get at app.ahacut.com -> API keys)
  logout                           Remove saved key
  status                           Show account + credit balance
  limits                           Show input limits (max size/length, audio support)

Generate (returns a job; poll with `wait`):
  generate-srt <file.srt>          Precise: b-roll cut to your subtitle timings
  generate-text <file|-> <secs>    Script + total length: AI segments & paces it
  generate-audio <file> [secs]     mp3/wav -> speech-to-text -> b-roll, original audio kept
  --overlay (any generate cmd)     Transparent overlay track instead of full-screen b-roll:
                                   ProRes 4444 .mov with alpha, drop it ON TOP of your
                                   talking-head footage in any editor (silent by design)
  --palette <id> (any generate cmd)  Pin the colour scheme so every job in one film matches:
                                   editorial-slate / red-alert / deep-teal / violet-night /
                                   amber-doc / cyan-steel. Omit = server picks by hashing the
                                   script — which means SPLITTING ONE FILM INTO SEVERAL JOBS
                                   GIVES EACH JOB A DIFFERENT PALETTE. Always pin it when you
                                   submit a film as multiple jobs. `limits` lists the hex values.
  --style-brief <text>             Style preference passed to the scene designer (<=500 chars).
                                   It is a preference, not narration — it never gets rendered
                                   as on-screen copy.
  --vertical (any generate cmd)    9:16 vertical (1080x1920) instead of the 16:9 default.
                                   Nothing infers this from your footage — say it here or
                                   you get a landscape track that won't fit your timeline

Track & deliver:
  job <id>                         Job status + result URLs
  wait <id> [timeout]              Poll until done/failed (default 1800s)
  download <id> [out]              Save finished video LOCALLY, prints local path (for delivery)
    [--artifact=<name>]            Other deliverables: jy_draft / scenes_zip / sfx_wav / sfx_cues / sfx_jianying
  draft <id> [dir] [--force]       Install the JianYing (剪映) draft into the LOCAL JianYing
                                   drafts folder — reopen JianYing and every clip is already
                                   on the timeline at its exact timecode. Quit JianYing first.
                                   With [dir]: just extract there instead of installing.
  list                             Recent jobs

Env: AHACUT_API_KEY, AHACUT_API_BASE (default https://api.ahacut.com)
HELP
}

# ─── Dispatch ─────────────────────────────────────────────
command="${1:-help}"; shift || true
case "$command" in
  login)          cmd_login "$@" ;;
  logout)         cmd_logout ;;
  status)         cmd_status ;;
  limits)         cmd_limits ;;
  list)           cmd_list ;;
  job)            cmd_job "$@" ;;
  generate-text)  cmd_generate_text "$@" ;;
  generate-srt)   cmd_generate_srt "$@" ;;
  generate-audio) cmd_generate_audio "$@" ;;
  wait)           cmd_wait "$@" ;;
  download)       cmd_download "$@" ;;
  draft)          cmd_draft "$@" ;;
  help|--help|-h) cmd_help ;;
  *)              echo "Unknown command: $command"; cmd_help; exit 1 ;;
esac
