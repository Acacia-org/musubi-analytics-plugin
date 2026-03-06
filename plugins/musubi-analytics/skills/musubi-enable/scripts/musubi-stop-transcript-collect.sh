#!/bin/bash
# Send Claude Code transcript to musubi analytics API
API_URL="${MUSUBI_API_URL:-https://cc-usage-collector.musubi-me.app}"
API_KEY="${MUSUBI_API_KEY:-}"
[ -z "$API_KEY" ] && exit 0

INPUT=$(cat)
JSONL_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$JSONL_PATH" ] || [ ! -f "$JSONL_PATH" ] && exit 0

# Resolve git repo identifier (org/repo) from cwd
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(head -1 "$JSONL_PATH" | jq -r '.cwd // empty' 2>/dev/null)
REPO=""
if [ -n "$CWD" ]; then
  REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null)
  if [ -n "$REMOTE_URL" ]; then
    REPO=$(echo "$REMOTE_URL" | sed 's/\.git$//' | sed -E 's#^.+[:/]([^/]+/[^/]+)$#\1#')
  fi
fi

# Resolve plugin version from installed_plugins.json
PLUGINS_JSON="${HOME}/.claude/plugins/installed_plugins.json"
PLUGIN_VERSION=""
if [ -f "$PLUGINS_JSON" ]; then
  PLUGIN_VERSION=$(jq -r '
    .plugins | to_entries[]
    | select(.key | startswith("musubi-analytics@"))
    | .value[0].version // empty
  ' "$PLUGINS_JSON" 2>/dev/null)
fi

LOG_DIR="${HOME}/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/musubi-transcript-collect.log"

# Rotate log
MAX_LOG_SIZE=1048576
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)" -gt "$MAX_LOG_SIZE" ]; then
  mv "$LOG_FILE" "${LOG_FILE}.old"
fi

# Count lines added/deleted from Write/Edit tool results before stripping content
LINE_COUNTS=$(jq -s '
  [.[] | select(.type == "result" and .tool_use_id) |
    if .tool_name == "Write" then
      { added: (.result // "" | split("\n") | length), deleted: 0 }
    elif .tool_name == "Edit" then
      {
        added: (.input.new_string // "" | split("\n") | length),
        deleted: (.input.old_string // "" | split("\n") | length)
      }
    else empty end
  ] | { linesAdded: (map(.added) | add // 0), linesDeleted: (map(.deleted) | add // 0) }
' "$JSONL_PATH" 2>/dev/null || echo '{"linesAdded":0,"linesDeleted":0}')
LINES_ADDED=$(echo "$LINE_COUNTS" | jq -r '.linesAdded // 0')
LINES_DELETED=$(echo "$LINE_COUNTS" | jq -r '.linesDeleted // 0')

# Extract only usage + tool_use metadata from JSONL (reduces 10-27MB → ~50KB)
# Replace cwd with repo identifier and inject pluginVersion
nohup jq -c --arg repo "$REPO" --arg pv "$PLUGIN_VERSION" '
  if .type == "assistant" and .message then
    {
      type, sessionId, repo: $repo, pluginVersion: $pv, version, timestamp, isoTimestamp,
      message: {
        model: .message.model,
        usage: .message.usage,
        content: [.message.content[]? | select(.type == "tool_use") | {type, name, input: {skill: .input.skill, subagent_type: .input.subagent_type}}]
      }
    }
  elif .sessionId or .cwd or .version then
    {type, sessionId, repo: $repo, pluginVersion: $pv, version, timestamp, isoTimestamp}
  else empty end
' "$JSONL_PATH" | curl -s -X POST "$API_URL/api/transcript?linesAdded=${LINES_ADDED}&linesDeleted=${LINES_DELETED}" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @- \
  >> "$LOG_FILE" 2>&1 &

# Auto-update plugin in background (applies from next session)
claude plugin update "musubi-analytics@musubi-analytics" --scope user >> "$LOG_FILE" 2>&1 &

exit 0
