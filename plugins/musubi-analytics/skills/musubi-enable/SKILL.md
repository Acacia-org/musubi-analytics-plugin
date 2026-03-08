---
name: musubi-enable
description: musubi analytics のセットアップ。API キーの設定と hook の自動配置を行います。
allowed-tools: Bash, Read, Write, Edit
---

# musubi-enable

Sets up transcript data collection for the musubi analytics dashboard from Claude Code sessions.

## Steps

### 1. Status Check

Read `~/.claude/settings.json` (user-level) and `.claude/settings.local.json` (directory-level) to check the following:

| Item                                                | Check                                              |
| --------------------------------------------------- | -------------------------------------------------- |
| `env.MUSUBI_API_KEY`                                | Present in user-level or directory-level settings? |
| `hooks.Stop`                                        | Contains `musubi-stop-transcript-collect.sh`?      |
| `~/.claude/hooks/musubi-stop-transcript-collect.sh` | File exists?                                       |
| `jq` command                                        | Available in PATH? (`command -v jq`)               |

Display the results as a markdown table with separate columns for user-level and directory-level:

```
### musubi analytics - Configuration Status

| Component              | User level (~/.claude/)  | Directory level (.claude/) |
|------------------------|--------------------------|----------------------------|
| API Key                | ✅ Set / ❌ Not set       | ✅ Set / — (not set)        |
| Stop Hook (settings)   | ✅ Configured / ❌ Not configured | ✅ Configured / — (not set) |
| Hook script (collector)| ✅ Found / ❌ Missing     | —                          |
| jq (required)          | ✅ Found / ❌ Not found   | —                          |
```

For the directory-level column, use "—" (em dash) when the item is not set. Only use ❌ for user-level items that are missing, since user-level is the recommended default. Hook scripts are always deployed to `~/.claude/hooks/` regardless of configuration level, so the directory-level column shows "—" for those rows.

#### Connection Verification (when API key exists)

If an API key is found in either user-level or directory-level settings, perform a connection verification:

Determine the API URL:

- Use `MUSUBI_API_URL` env var if set, otherwise default to `https://cc-usage-collector.musubi-me.app`

```bash
curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer <API_KEY>" \
  "<api-url>/api/transcript/health"
```

Add the result to the status table:

- HTTP 200: `✅ Connected (Workspace: <workspaceName>, User: <userName>)`
- Non-200: `❌ Failed (HTTP <status>)` — indicate the key may be invalid or revoked

```
| Connection             | ✅ Connected / ❌ Failed  | — or ✅ Connected / ❌ Failed |
```

Store the `workspaceSlug` from the health response for use in Step 2 (dashboard URL).

**If all items are configured AND connection is verified:**

Use AskUserQuestion to ask the user:

- **Update** — "Re-run the setup process to update configuration"
- **Cancel** — "Keep current configuration and exit"

If the user selects "Cancel", display "Setup is already complete. No changes made." and exit.
If the user selects "Update", proceed to Step 2.

**If any item is missing or connection failed:** Proceed to Step 2

### 2. Configuration Level Selection

Use AskUserQuestion to let the user choose:

- **User level (Recommended)** — Writes to `~/.claude/settings.json`. Applies to all projects.
- **Directory level** — Writes to `.claude/settings.local.json` in the current project. Applies only to this project. This file is automatically excluded from git by Claude Code, preventing accidental commit of API keys and personal settings.

After the user selects a level, open the musubi dashboard in the browser for API key retrieval:

Determine the dashboard URL:

- If `MUSUBI_API_URL` env var is set, derive from it (replace `api.` with `app.`, or replace port with dashboard port as appropriate). For localhost URLs like `http://localhost:3200`, use `http://localhost:3000`.
- Otherwise, default to `https://app.musubi-me.app`

If `workspaceSlug` was obtained from connection verification in Step 1, use it to construct the URL:

```bash
open "<dashboard-url>/<workspaceSlug>/settings/api-keys"
```

If `workspaceSlug` is not available (no existing key or connection failed), open the dashboard root:

```bash
open "<dashboard-url>"
```

Then display:

```
Opening musubi dashboard in your browser...

1. Go to Settings > API キー
2. Create a new API key (e.g., "my-macbook")
3. Copy the API key and paste it below
```

Use AskUserQuestion to wait for the API key input. The question should have a single option "Paste your API key" with description "Select 'Other' and paste your API key", so the user is guided to use the Other input.

### 3. Connection Verification

Determine the API URL:

- Use `MUSUBI_API_URL` env var if set, otherwise default to `https://cc-usage-collector.musubi-me.app`

```bash
curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer <API_KEY>" \
  "<api-url>/api/transcript/health"
```

- Non-200 response: Display error message and abort
- HTTP 200: Extract `workspaceName`, `workspaceSlug`, and `userName` from the response JSON and display:

```
Connection verified!
Workspace: <workspaceName>
User: <userName>
```

### 4. Automatic Configuration

#### Deploy Hook Launcher

Copy the **launcher script** to `~/.claude/hooks/`:

- `musubi-hook-launcher.sh` → `~/.claude/hooks/musubi-stop-transcript-collect.sh`

The launcher dynamically resolves the plugin's install path from `~/.claude/plugins/installed_plugins.json` and delegates to the actual `musubi-stop-transcript-collect.sh` inside the plugin directory. This way, when the plugin is updated via `/plugin update`, the hook script is automatically upgraded without re-running setup.

Source path search order:

1. Plugin install path: look up `installPath` for key starting with `musubi-analytics@` in `~/.claude/plugins/installed_plugins.json`, then use `{installPath}/skills/musubi-enable/scripts/musubi-hook-launcher.sh`
2. Project local: `$CLAUDE_PROJECT_DIR/.claude/hooks/musubi-hook-launcher.sh` (development fallback)

After copying, run `chmod +x ~/.claude/hooks/musubi-stop-transcript-collect.sh`.

#### Update Settings File

Write to the settings file chosen in Step 2 (user-level `~/.claude/settings.json` or directory-level `.claude/settings.local.json`).

Add to `env`:

- `MUSUBI_API_KEY`: The API key entered by the user

Add Stop hook (merge with existing hooks, skip if already present):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/musubi-stop-transcript-collect.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### 5. Completion

```
Setup complete!
Transcript data will be automatically sent when Claude Code sessions end.

⚠️ To start sending data, please end this session.
   The Stop hook runs when a session ends, so use /exit to close
   the current session. Data will be collected automatically
   starting from the next session termination.
```

If `jq` was not found in Step 1, display the following instead and **abort setup**:

```
❌ jq is required for transcript collection.
   macOS:         brew install jq
   Ubuntu/Debian: sudo apt install jq
   Windows (WSL): sudo apt install jq
   After installing jq, run /musubi-enable again.
```
