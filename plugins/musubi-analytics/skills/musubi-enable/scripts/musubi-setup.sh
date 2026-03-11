#!/bin/bash
# API key setup script for musubi analytics.
# Handles key input, verification, and settings.json writing
# so that API keys never enter the LLM context window.
# All configuration is stored at user level (~/.claude/settings.json).
set -euo pipefail
umask 077

USER_SETTINGS="${HOME}/.claude/settings.json"
API_URL="${MUSUBI_API_URL:-https://cc-usage-collector.musubi-me.app}"
HEALTH_ENDPOINT="${API_URL}/api/transcript/health"

# --- helpers ---

json_ok() { printf '{"ok":true,%s}\n' "$1"; }
json_err() { printf '{"ok":false,"error":"%s"}\n' "$1"; }

ensure_settings_file() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || echo '{}' > "$file"
}

# Write JSON to a settings file atomically via temp file + trap
write_json() {
  local file="$1"
  shift
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  "$@" > "$tmp" && mv "$tmp" "$file"
  trap - EXIT
}

read_key_from_settings() {
  local file="$1"
  [ -f "$file" ] || return 1
  jq -r '.env.MUSUBI_API_KEY // empty' "$file" 2>/dev/null
}

has_musubi_hook() {
  local file="$1"
  [ -f "$file" ] || { echo 0; return; }
  local count
  count=$(jq -r '
    .hooks.Stop // [] | .[].hooks // [] | .[].command // empty
  ' "$file" 2>/dev/null | grep -c "musubi-stop-transcript-collect" || true)
  echo "$count"
}

verify_key() {
  local key="$1"
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${key}" \
    "${HEALTH_ENDPOINT}" 2>/dev/null) || { json_err "curl failed"; return 1; }

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "200" ]; then
    echo "$body" | jq -c '{ok:true, httpCode:200} + {workspaceName: .workspaceName, workspaceSlug: .workspaceSlug, userName: .userName}'
  else
    json_err "HTTP ${http_code}"
  fi
}

# --- subcommands ---

cmd_status() {
  local hook_script="${HOME}/.claude/hooks/musubi-stop-transcript-collect.sh"
  local has_jq="false"
  command -v jq >/dev/null 2>&1 && has_jq="true"

  local key_set="false"
  local uk
  uk=$(read_key_from_settings "$USER_SETTINGS") || true
  [ -n "$uk" ] && key_set="true"

  local hook_configured="false"
  [ "$(has_musubi_hook "$USER_SETTINGS")" -gt 0 ] 2>/dev/null && hook_configured="true"

  local hook_script_exists="false"
  [ -x "$hook_script" ] && hook_script_exists="true"

  local api_url=""
  if [ "$has_jq" = "true" ] && [ -f "$USER_SETTINGS" ]; then
    api_url=$(jq -r '.env.MUSUBI_API_URL // empty' "$USER_SETTINGS" 2>/dev/null) || true
  fi

  if [ "$has_jq" = "true" ]; then
    jq -n -c \
      --argjson keySet "$key_set" \
      --argjson hookConfigured "$hook_configured" \
      --argjson hookScriptExists "$hook_script_exists" \
      --argjson hasJq "$has_jq" \
      --arg apiUrl "$api_url" \
      '{keySet: $keySet, hookConfigured: $hookConfigured, hookScriptExists: $hookScriptExists, hasJq: $hasJq, apiUrl: $apiUrl}'
  else
    cat <<EOJSON
{"keySet":${key_set},"hookConfigured":${hook_configured},"hookScriptExists":${hook_script_exists},"hasJq":${has_jq},"apiUrl":""}
EOJSON
  fi
}

cmd_verify() {
  local key=""
  key=$(read_key_from_settings "$USER_SETTINGS") || true

  if [ -z "$key" ]; then
    json_err "no_key"
    return
  fi

  # Use custom API URL from settings if available
  local custom_url=""
  custom_url=$(jq -r '.env.MUSUBI_API_URL // empty' "$USER_SETTINGS" 2>/dev/null) || true
  if [ -n "$custom_url" ]; then
    HEALTH_ENDPOINT="${custom_url}/api/transcript/health"
  fi

  verify_key "$key"
}

cmd_add_hook() {
  ensure_settings_file "$USER_SETTINGS"

  if [ "$(has_musubi_hook "$USER_SETTINGS")" -gt 0 ] 2>/dev/null; then
    json_ok '"skipped":true,"reason":"hook already configured"'
    return
  fi

  write_json "$USER_SETTINGS" jq '.hooks.Stop = ((.hooks.Stop // []) + [{
    "matcher": "",
    "hooks": [{
      "type": "command",
      "command": "~/.claude/hooks/musubi-stop-transcript-collect.sh",
      "timeout": 30
    }]
  }])' "$USER_SETTINGS"

  json_ok '"added":true'
}

cmd_setup() {
  # Silent key input (never exposed to LLM context)
  local key=""
  if command -v osascript >/dev/null 2>&1; then
    key=$(osascript -e 'display dialog "musubi analytics のセットアップ\n\n1. ブラウザで開いた Dashboard の API キー画面へ\n2. 新しい API キーを作成（例: \"my-macbook\"）\n3. コピーして下のフィールドに貼り付け" default answer "" with hidden answer with title "musubi analytics setup"' -e 'text returned of result' 2>/dev/null) || true
  else
    json_err "no_tty"
    return
  fi

  if [ -z "$key" ]; then
    json_err "empty_key"
    return
  fi

  # Verify connection
  local result
  result=$(verify_key "$key")
  local ok
  ok=$(echo "$result" | jq -r '.ok')

  if [ "$ok" != "true" ]; then
    echo "$result"
    return
  fi

  # Write to user-level settings
  ensure_settings_file "$USER_SETTINGS"
  write_json "$USER_SETTINGS" jq --arg k "$key" '.env.MUSUBI_API_KEY = $k' "$USER_SETTINGS"

  echo "$result" | jq -c '. + {written: true}'
}

cmd_remove() {
  local removed_key="false" removed_hook="false" removed_script="false"

  # Remove API key from settings
  if [ -f "$USER_SETTINGS" ]; then
    local has_key
    has_key=$(jq -r '.env.MUSUBI_API_KEY // empty' "$USER_SETTINGS" 2>/dev/null)
    if [ -n "$has_key" ]; then
      write_json "$USER_SETTINGS" jq \
        'del(.env.MUSUBI_API_KEY)
         | if .env == {} then del(.env) else . end' \
        "$USER_SETTINGS"
      removed_key="true"
    fi
  fi

  # Remove Stop hook entry from settings
  if [ -f "$USER_SETTINGS" ] && [ "$(has_musubi_hook "$USER_SETTINGS")" -gt 0 ] 2>/dev/null; then
    write_json "$USER_SETTINGS" jq \
      '.hooks.Stop = [
         .hooks.Stop // [] | .[]
         | select((.hooks // [])
             | all(.command | test("musubi-stop-transcript-collect") | not))
       ]
       | if .hooks.Stop == [] then del(.hooks.Stop) else . end
       | if .hooks == {} then del(.hooks) else . end' \
      "$USER_SETTINGS"
    removed_hook="true"
  fi

  # Remove hook script
  local hook_script="${HOME}/.claude/hooks/musubi-stop-transcript-collect.sh"
  if [ -f "$hook_script" ]; then
    rm "$hook_script"
    removed_script="true"
  fi

  cat <<EOJSON
{"ok":true,"removedKey":${removed_key},"removedHook":${removed_hook},"removedScript":${removed_script}}
EOJSON
}

# --- main ---

case "${1:-}" in
  status)   cmd_status ;;
  verify)   cmd_verify ;;
  setup)    cmd_setup ;;
  add-hook) cmd_add_hook ;;
  remove)   cmd_remove ;;
  *)
    echo "Usage: musubi-setup.sh <status|verify|setup|add-hook|remove>" >&2
    exit 1
    ;;
esac
