# musubi-analytics Plugin

A Claude Code plugin that parses transcript data and sends it to the musubi dashboard.
Tracks skill, subagent, and MCP usage per session.

## Publishing (for maintainers)

1. Push the contents of `packages/claude-plugin/` to a standalone GitHub repository

   ```bash
   # e.g., github.com/yourorg/musubi-analytics-plugin
   cd packages/claude-plugin
   git init && git remote add origin git@github.com:yourorg/musubi-analytics-plugin.git
   git add . && git commit -m "Initial release" && git push -u origin main
   ```

2. The repository can be either public or private (private limits access to organization members only)

## Installation (for users)

### 1. Add marketplace (first time only)

```
/plugin marketplace add yourorg/musubi-analytics-plugin
```

### 2. Install the plugin

```
/plugin install musubi-analytics@musubi-analytics
```

### 3. Run setup

```
/musubi-setup
```

- Generate an API key from the dashboard
- Enter the API key
- Connection verification and hook deployment are handled automatically

### 4. Verify

End a Claude Code session and confirm that data appears on the dashboard.

## Updating

```
/plugin update musubi-analytics@musubi-analytics
```

Push to the GitHub repository, and users can pull the latest version with the update command.

## Architecture

```
Session End → Stop hook (jq + curl) → POST cc-usage-collector/api/transcript → server-side parse → DB
```

- **Stop hook**: Runs automatically when a Claude Code session ends, extracts usage metadata via jq and sends NDJSON
- **cc-usage-collector**: Standalone Cloudflare Worker that parses NDJSON and upserts into cc_sessions / cc_session_models / cc_session_tools

## Collected Data

- Token usage per session
- Breakdown by model (Opus / Sonnet / Haiku)
- Tool call counts
- MCP server, Skill, and subagent usage
