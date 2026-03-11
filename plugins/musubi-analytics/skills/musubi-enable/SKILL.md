---
name: musubi-enable
description: musubi analytics のセットアップ。API キーの設定と hook の自動配置を行います。
allowed-tools: Bash, Read, Write, Edit
---

# musubi-enable

Sets up transcript data collection for the musubi analytics dashboard from Claude Code sessions.

## SECURITY CONSTRAINT — READ THIS FIRST

**The API key MUST NEVER appear in the LLM context.** This means:

1. **NEVER use AskUserQuestion to ask the user for an API key.** Not as a question option, not as "Other" free text, not in any form.
2. **NEVER read settings files** (`~/.claude/settings.json`, `.claude/settings.local.json`) with the Read or Edit tools, because they contain the API key.
3. **ALL operations involving the API key** (status check, connection verification, key input, key storage, hook configuration) MUST go through `musubi-setup.sh` via the Bash tool.
4. The user enters the API key **only** at the shell prompt (`read -s`) inside the setup script — this input goes directly to the script process and never reaches the LLM.

If you are about to use AskUserQuestion with anything related to "API key", "paste", or "key" — **STOP. You are violating this constraint.**

## Script Path Resolution

Several steps use `musubi-setup.sh`. Resolve its path once at the start:

1. Plugin install path: look up `installPath` for key starting with `musubi-analytics@` in `~/.claude/plugins/installed_plugins.json`, then use `{installPath}/skills/musubi-enable/scripts/musubi-setup.sh`
2. Project local: `$CLAUDE_PROJECT_DIR/packages/claude-plugin/plugins/musubi-analytics/skills/musubi-enable/scripts/musubi-setup.sh` (development fallback)

Store the resolved path as `SETUP_SCRIPT` for use in subsequent steps.

## Steps

### 1. Status Check

**IMPORTANT**: Do NOT read settings files directly with the Read tool. API keys must never enter the LLM context. Use the setup script for all settings checks.

Run the setup script to check configuration status:

```bash
bash "$SETUP_SCRIPT" status
```

The script checks all items and returns JSON (API key values are never included):

```json
{
  "keySet": true,
  "hookConfigured": true,
  "hookScriptExists": true,
  "hasJq": true,
  "apiUrl": ""
}
```

`apiUrl` is a custom API URL override. Empty string means default URL is used.

Display the results as a markdown table:

```
### musubi analytics - Configuration Status

| Component              | Status                          |
|------------------------|---------------------------------|
| API Key                | ✅ Set / ❌ Not set              |
| Stop Hook (settings)   | ✅ Configured / ❌ Not configured |
| Hook script (collector)| ✅ Found / ❌ Missing            |
| jq (required)          | ✅ Found / ❌ Not found          |
```

#### Connection Verification (when API key exists)

If `keySet` is true, verify the key:

```bash
bash "$SETUP_SCRIPT" verify
```

Returns JSON (key value is never included):

- `{"ok":true,"httpCode":200,"workspaceName":"...","workspaceSlug":"...","userName":"..."}` on success
- `{"ok":false,"error":"..."}` on failure

Add the result to the status table:

- `ok: true`: `✅ Connected (Workspace: <workspaceName>, User: <userName>)`
- `ok: false`: `❌ Failed (<error>)` — indicate the key may be invalid or revoked

```
| Connection             | ✅ Connected / ❌ Failed         |
```

#### Custom API URL Display

If `apiUrl` is non-empty in the status output, add an **API URL** row to the table:

```
| API URL                | <url>                           |
```

Only add this row if a custom URL is configured.

Store the `workspaceSlug` from the verification response for use in Step 2 (dashboard URL).

**If all items are configured AND connection is verified:**

Use AskUserQuestion to ask the user:

- **Update** — "Re-run the setup process to update configuration"
- **Cancel** — "Keep current configuration and exit"

If the user selects "Cancel", display "Setup is already complete. No changes made." and exit.
If the user selects "Update", proceed to Step 2.

**If any item is missing or connection failed:** Proceed to Step 2

### 2. API Key Setup

Open the musubi dashboard and run the setup script in a **single Bash command**. All configuration is written to `~/.claude/settings.json` (user level).

Determine the dashboard URL:

- If `MUSUBI_API_URL` env var is set, derive from it (replace `api.` with `app.`, or replace port with dashboard port as appropriate). For localhost URLs like `http://localhost:3200`, use `http://localhost:3000`.
- Otherwise, default to `https://app.musubi-me.app`

Determine the dashboard path:

- If `workspaceSlug` was obtained from connection verification in Step 1: `<dashboard-url>/<workspaceSlug>/settings/api-keys`
- Otherwise: `<dashboard-url>/api-keys` (after login, the user will be redirected to their workspace's API keys page)

Run dashboard open and setup script together:

```bash
open "<dashboard-url>[/<workspaceSlug>]/api-keys" && echo "
Opening musubi dashboard in your browser...
A dialog will appear — paste your API key there.
" && bash "$SETUP_SCRIPT" setup
```

On macOS, a secure dialog appears for the user to paste the key. The key is never sent to the LLM.

The script returns JSON:

- `{"ok":true,...,"workspaceName":"...","userName":"...","written":true}` on success
- `{"ok":false,"error":"empty_key"}` on failure (user cancelled dialog) — display the error and abort
- `{"ok":false,"error":"no_tty"}` — non-macOS environment without interactive terminal. See **Fallback** below.

#### Fallback for non-macOS (Linux/WSL)

If the script returns `no_tty`, display the following instructions so the user can run the script directly from a separate terminal:

```
This environment does not support secure key input dialogs.
Please run the following command in a separate terminal:

  bash <SETUP_SCRIPT_ABSOLUTE_PATH> setup

After running it, use /musubi-enable again to continue setup.
```

Then **stop** — do NOT proceed to Step 3. The user will re-run the skill after manually executing the script.

On success, display:

```
Connection verified!
Workspace: <workspaceName>
User: <userName>
```

### 3. Automatic Configuration

#### Deploy Hook Launcher

Copy the **launcher script** to `~/.claude/hooks/`:

- `musubi-hook-launcher.sh` → `~/.claude/hooks/musubi-stop-transcript-collect.sh`

The launcher dynamically resolves the plugin's install path from `~/.claude/plugins/installed_plugins.json` and delegates to the actual `musubi-stop-transcript-collect.sh` inside the plugin directory. This way, when the plugin is updated via `/plugin update`, the hook script is automatically upgraded without re-running setup.

Source path search order:

1. Plugin install path: look up `installPath` for key starting with `musubi-analytics@` in `~/.claude/plugins/installed_plugins.json`, then use `{installPath}/skills/musubi-enable/scripts/musubi-hook-launcher.sh`
2. Project local: `$CLAUDE_PROJECT_DIR/.claude/hooks/musubi-hook-launcher.sh` (development fallback)

After copying, run `chmod +x ~/.claude/hooks/musubi-stop-transcript-collect.sh`.

#### Update Settings File

**IMPORTANT**: Do NOT read or edit settings files directly with Read/Edit tools, as this would expose the API key in the LLM context. Use the setup script instead.

The API key was already written by the setup script in Step 2. Add the hook configuration using:

```bash
bash "$SETUP_SCRIPT" add-hook
```

The script returns JSON:

- `{"ok":true,"added":true}` — hook was added
- `{"ok":true,"skipped":true,"reason":"hook already configured"}` — hook already exists

### 4. Completion

Display the following celebration message:

```
🎉🎉🎉 Setup Complete! 🎉🎉🎉

✅ API Key        → Configured
✅ Connection      → Workspace: <workspaceName> / User: <userName>
✅ Hook Script     → Deployed
✅ Hook Settings   → Registered

musubi analytics is now active!
Usage data will be sent automatically each time a Claude Code session ends.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚡ Next step: End this session with /exit.
   The Stop hook fires on session end, so data collection
   will begin from your next session termination.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If `jq` was not found in Step 1, display the following instead and **abort setup**:

```
❌ jq is required for transcript collection.
   macOS:         brew install jq
   Ubuntu/Debian: sudo apt install jq
   Windows (WSL): sudo apt install jq
   After installing jq, run /musubi-enable again.
```
