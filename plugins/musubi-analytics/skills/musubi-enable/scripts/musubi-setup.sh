#!/bin/bash
# API key setup script for musubi analytics.
# Handles key input, verification, and settings.json writing
# so that API keys never enter the LLM context window.
set -euo pipefail
umask 077

USER_SETTINGS="${HOME}/.claude/settings.json"
DIR_SETTINGS=".claude/settings.local.json"
API_URL="${MUSUBI_API_URL:-https://cc-usage-collector.musubi-me.app}"
HEALTH_ENDPOINT="${API_URL}/api/transcript/health"

# --- helpers ---

json_ok() { printf '{"ok":true,%s}\n' "$1"; }
json_err() { printf '{"ok":false,"error":"%s"}\n' "$1"; }

resolve_settings_file() {
  local level="$1" cmd="$2"
  if [ -z "$level" ]; then
    echo "Usage: musubi-setup.sh ${cmd} <user|directory>" >&2
    exit 1
  fi
  case "$level" in
    user) echo "$USER_SETTINGS" ;;
    directory) echo "$DIR_SETTINGS" ;;
    *) echo "Invalid level: $level" >&2; exit 1 ;;
  esac
}

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
    local workspace_name workspace_slug user_name
    workspace_name=$(echo "$body" | jq -r '.workspaceName // empty' 2>/dev/null)
    workspace_slug=$(echo "$body" | jq -r '.workspaceSlug // empty' 2>/dev/null)
    user_name=$(echo "$body" | jq -r '.userName // empty' 2>/dev/null)
    json_ok "\"httpCode\":200,\"workspaceName\":\"${workspace_name}\",\"workspaceSlug\":\"${workspace_slug}\",\"userName\":\"${user_name}\""
  else
    json_err "HTTP ${http_code}"
  fi
}

# --- subcommands ---

cmd_status() {
  local hook_script="${HOME}/.claude/hooks/musubi-stop-transcript-collect.sh"
  local has_jq="false"
  command -v jq >/dev/null 2>&1 && has_jq="true"

  local user_key_set="false" dir_key_set="false"
  local uk
  uk=$(read_key_from_settings "$USER_SETTINGS") || true
  [ -n "$uk" ] && user_key_set="true"
  local dk
  dk=$(read_key_from_settings "$DIR_SETTINGS") || true
  [ -n "$dk" ] && dir_key_set="true"

  local user_hook_configured="false" dir_hook_configured="false"
  [ "$(has_musubi_hook "$USER_SETTINGS")" -gt 0 ] 2>/dev/null && user_hook_configured="true"
  [ "$(has_musubi_hook "$DIR_SETTINGS")" -gt 0 ] 2>/dev/null && dir_hook_configured="true"

  local hook_script_exists="false"
  [ -x "$hook_script" ] && hook_script_exists="true"

  # Check for custom API URL in settings
  local user_api_url="" dir_api_url=""
  if [ "$has_jq" = "true" ]; then
    [ -f "$USER_SETTINGS" ] && user_api_url=$(jq -r '.env.MUSUBI_API_URL // empty' "$USER_SETTINGS" 2>/dev/null) || true
    [ -f "$DIR_SETTINGS" ] && dir_api_url=$(jq -r '.env.MUSUBI_API_URL // empty' "$DIR_SETTINGS" 2>/dev/null) || true
  fi

  # Build JSON with jq to handle proper escaping
  if [ "$has_jq" = "true" ]; then
    jq -n -c \
      --argjson userKeySet "$user_key_set" \
      --argjson dirKeySet "$dir_key_set" \
      --argjson userHookConfigured "$user_hook_configured" \
      --argjson dirHookConfigured "$dir_hook_configured" \
      --argjson hookScriptExists "$hook_script_exists" \
      --argjson hasJq "$has_jq" \
      --arg userApiUrl "$user_api_url" \
      --arg dirApiUrl "$dir_api_url" \
      '{userKeySet: $userKeySet, dirKeySet: $dirKeySet, userHookConfigured: $userHookConfigured, dirHookConfigured: $dirHookConfigured, hookScriptExists: $hookScriptExists, hasJq: $hasJq, userApiUrl: $userApiUrl, dirApiUrl: $dirApiUrl}'
  else
    cat <<EOJSON
{"userKeySet":${user_key_set},"dirKeySet":${dir_key_set},"userHookConfigured":${user_hook_configured},"dirHookConfigured":${dir_hook_configured},"hookScriptExists":${hook_script_exists},"hasJq":${has_jq},"userApiUrl":"","dirApiUrl":""}
EOJSON
  fi
}

cmd_verify() {
  local level="${1:-}"
  local key="" source=""

  if [ -n "$level" ]; then
    case "$level" in
      user) source="user"; key=$(read_key_from_settings "$USER_SETTINGS") || true ;;
      directory) source="directory"; key=$(read_key_from_settings "$DIR_SETTINGS") || true ;;
      *) json_err "invalid_level"; return ;;
    esac
  else
    # No level specified: try user first, fallback to directory (backward compat)
    key=$(read_key_from_settings "$USER_SETTINGS") || true
    source="user"
    if [ -z "$key" ]; then
      key=$(read_key_from_settings "$DIR_SETTINGS") || true
      source="directory"
    fi
  fi

  if [ -z "$key" ]; then
    json_err "no_key"
    return
  fi

  # Use custom API URL from the resolved level's settings if available
  local settings_for_url=""
  case "$source" in
    user) settings_for_url="$USER_SETTINGS" ;;
    directory) settings_for_url="$DIR_SETTINGS" ;;
  esac
  local custom_url=""
  custom_url=$(jq -r '.env.MUSUBI_API_URL // empty' "$settings_for_url" 2>/dev/null) || true
  if [ -n "$custom_url" ]; then
    HEALTH_ENDPOINT="${custom_url}/api/transcript/health"
  fi

  local result
  result=$(verify_key "$key")
  echo "$result" | jq -c --arg src "$source" '. + {source: $src}'
}

cmd_add_hook() {
  local settings_file
  settings_file=$(resolve_settings_file "${1:-}" "add-hook")
  ensure_settings_file "$settings_file"

  if [ "$(has_musubi_hook "$settings_file")" -gt 0 ] 2>/dev/null; then
    json_ok '"skipped":true,"reason":"hook already configured"'
    return
  fi

  write_json "$settings_file" jq '.hooks.Stop = ((.hooks.Stop // []) + [{
    "matcher": "",
    "hooks": [{
      "type": "command",
      "command": "~/.claude/hooks/musubi-stop-transcript-collect.sh",
      "timeout": 30
    }]
  }])' "$settings_file"

  json_ok '"added":true'
}

cmd_setup() {
  local settings_file
  settings_file=$(resolve_settings_file "${1:-}" "setup")

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

  # Write to settings
  ensure_settings_file "$settings_file"
  write_json "$settings_file" jq --arg k "$key" '.env.MUSUBI_API_KEY = $k' "$settings_file"

  echo "$result" | jq -c --arg lvl "${1:-}" '. + {level: $lvl, written: true}'
}

cmd_remove() {
  local settings_file
  settings_file=$(resolve_settings_file "${1:-}" "remove")

  local removed_key="false" removed_hook="false" removed_script="false"

  # Remove API key from settings
  if [ -f "$settings_file" ]; then
    local has_key
    has_key=$(jq -r '.env.MUSUBI_API_KEY // empty' "$settings_file" 2>/dev/null)
    if [ -n "$has_key" ]; then
      write_json "$settings_file" jq \
        'del(.env.MUSUBI_API_KEY)
         | if .env == {} then del(.env) else . end' \
        "$settings_file"
      removed_key="true"
    fi
  fi

  # Remove Stop hook entry from settings
  if [ -f "$settings_file" ] && [ "$(has_musubi_hook "$settings_file")" -gt 0 ] 2>/dev/null; then
    write_json "$settings_file" jq \
      '.hooks.Stop = [
         .hooks.Stop // [] | .[]
         | select((.hooks // [])
             | all(.command | test("musubi-stop-transcript-collect") | not))
       ]
       | if .hooks.Stop == [] then del(.hooks.Stop) else . end
       | if .hooks == {} then del(.hooks) else . end' \
      "$settings_file"
    removed_hook="true"
  fi

  # Remove hook script
  local hook_script="${HOME}/.claude/hooks/musubi-stop-transcript-collect.sh"
  if [ -f "$hook_script" ]; then
    rm "$hook_script"
    removed_script="true"
  fi

  cat <<EOJSON
{"ok":true,"removedKey":${removed_key},"removedHook":${removed_hook},"removedScript":${removed_script},"level":"${1:-}"}
EOJSON
}

# --- main ---

case "${1:-}" in
  status)   cmd_status ;;
  verify)   cmd_verify "${2:-}" ;;
  setup)    cmd_setup "${2:-}" ;;
  add-hook) cmd_add_hook "${2:-}" ;;
  remove)   cmd_remove "${2:-}" ;;
  *)
    echo "Usage: musubi-setup.sh <status|verify|setup|add-hook|remove> [args...]" >&2
    exit 1
    ;;
esac
