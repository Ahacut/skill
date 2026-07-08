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

# generate-text <file|-> <seconds>   (script + total length -> AI segments + paces)
cmd_generate_text() {
  local file="${1:-}" secs="${2:-}"
  { [ -z "$file" ] || [ -z "$secs" ]; } && { echo "Usage: ahacut.sh generate-text <file|-> <seconds>"; exit 1; }
  local text; if [ "$file" = "-" ]; then text=$(cat); else text=$(cat "$file"); fi
  local tjson; tjson=$(printf '%s' "$text" | json_str)
  api POST /jobs -d "{\"input_kind\":\"text\",\"text\":${tjson},\"duration_seconds\":${secs}}"
}

# generate-srt <file>   (precise: cuts land on subtitle timings)
cmd_generate_srt() {
  local file="${1:-}"; [ -z "$file" ] && { echo "Usage: ahacut.sh generate-srt <file.srt>"; exit 1; }
  local sjson; sjson=$(cat "$file" | json_str)
  api POST /jobs -d "{\"input_kind\":\"srt\",\"srt\":${sjson}}"
}

# generate-audio <file> [seconds]   (mp3/wav -> speech-to-text -> b-roll, original audio muxed back)
cmd_generate_audio() {
  local file="${1:-}" secs="${2:-}"
  [ -z "$file" ] && { echo "Usage: ahacut.sh generate-audio <file> [seconds]"; exit 1; }
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
  api POST /jobs -d "{\"input_kind\":\"audio\",\"audio_key\":\"${key}\",\"duration_seconds\":${secs}}"
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

# download <job_id> [out.mp4]  — save the finished video to a LOCAL file (for delivery)
# Many agent frameworks can only deliver a local file path, not a remote URL — use this
# after the job is done, then hand the printed local path to your delivery step.
cmd_download() {
  local id="${1:-}" out="${2:-}"
  [ -z "$id" ] && { echo "Usage: ahacut.sh download <job_id> [out.mp4]"; exit 1; }
  local res status; res=$(api GET "/jobs/${id}")
  status=$(printf '%s' "$res" | jget '.job.status')
  [ "$status" != "done" ] && { echo "ERROR: job $id not done (status=${status:-?}); run: ahacut.sh wait $id" >&2; exit 1; }
  # prefer the final video with original audio; fall back to the b-roll-only track
  local url; url=$(printf '%s' "$res" | jget '.job.result.with_audio')
  [ -z "$url" ] && url=$(printf '%s' "$res" | jget '.job.result.broll')
  [ -z "$url" ] && { echo "ERROR: no video URL in result: $res" >&2; exit 1; }
  [ -z "$out" ] && out="./ahacut-${id}.mp4"
  echo "Downloading video → ${out}…" >&2
  curl -sSL -o "$out" "$url"
  # print the ABSOLUTE local path (stdout) so the caller can deliver it directly
  ( cd "$(dirname "$out")" && printf '%s/%s\n' "$(pwd)" "$(basename "$out")" )
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

Track & deliver:
  job <id>                         Job status + result URLs
  wait <id> [timeout]              Poll until done/failed (default 1800s)
  download <id> [out.mp4]          Save finished video LOCALLY, prints local path (for delivery)
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
  help|--help|-h) cmd_help ;;
  *)              echo "Unknown command: $command"; cmd_help; exit 1 ;;
esac
