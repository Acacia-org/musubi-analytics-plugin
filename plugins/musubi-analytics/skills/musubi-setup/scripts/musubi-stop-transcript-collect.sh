#!/bin/bash
# Stop hook: parse Claude Code transcript and send to musubi analytics API
# Runs in background to avoid blocking Claude Code exit
#
# Claude Code provides transcript_path via stdin JSON.
#
# Required env vars (set via Claude Code settings.json env):
#   MUSUBI_API_KEY - API key for authentication
# Optional:
#   MUSUBI_API_URL - Override API endpoint (default: https://api.musubi-me.app)

API_URL="${MUSUBI_API_URL:-https://api.musubi-me.app}"
API_KEY="${MUSUBI_API_KEY:-}"

if [ -z "$API_KEY" ]; then
  exit 0
fi

# Claude Code passes transcript_path in stdin JSON
INPUT=$(cat)
JSONL_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

if [ -z "$JSONL_PATH" ] || [ ! -f "$JSONL_PATH" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSER="${SCRIPT_DIR}/musubi-parse-transcript.mjs"

if [ ! -f "$PARSER" ]; then
  exit 0
fi

LOG_DIR="${HOME}/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/musubi-transcript-collect.log"

# Log rotation: keep log under 1MB
MAX_LOG_SIZE=1048576
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)" -gt "$MAX_LOG_SIZE" ]; then
  mv "$LOG_FILE" "${LOG_FILE}.old"
fi

MUSUBI_API_KEY="$API_KEY" MUSUBI_API_URL="$API_URL" \
  nohup node "$PARSER" --transcript "$JSONL_PATH" \
  >> "$LOG_FILE" 2>&1 &

exit 0
