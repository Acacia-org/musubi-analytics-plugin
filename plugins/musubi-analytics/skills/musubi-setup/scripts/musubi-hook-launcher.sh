#!/bin/bash
# Launcher that delegates to the actual hook script from the installed plugin.
# This file is placed in ~/.claude/hooks/ and stays unchanged across plugin updates.
PLUGINS_JSON="${HOME}/.claude/plugins/installed_plugins.json"
[ -f "$PLUGINS_JSON" ] || exit 0

INSTALL_PATH=$(jq -r '
  .plugins
  | to_entries[]
  | select(.key | startswith("musubi-analytics@"))
  | .value[0].installPath
' "$PLUGINS_JSON" 2>/dev/null)
[ -z "$INSTALL_PATH" ] && exit 0

SCRIPT="${INSTALL_PATH}/skills/musubi-setup/scripts/musubi-stop-transcript-collect.sh"
[ -x "$SCRIPT" ] || exit 0

exec "$SCRIPT"
