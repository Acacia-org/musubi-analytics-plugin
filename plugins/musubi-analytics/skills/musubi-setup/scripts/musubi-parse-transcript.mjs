#!/usr/bin/env node

// Claude Code JSONL トランスクリプトパーサー
// 外部依存なし: node:fs, node:readline, node:path のみ使用
// Usage:
//   node parse-transcript.mjs --transcript <path> [--api-url <url>]
//   Environment variables MUSUBI_API_KEY (required) / MUSUBI_API_URL (optional) are also supported
//   API key is read from MUSUBI_API_KEY env var only (never passed as CLI argument)

import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { parseArgs } from "node:util";

// ─── Pricing Table (per 1M tokens) ───
// https://docs.anthropic.com/en/docs/about-claude/models

const PRICING = {
  "claude-opus-4-6": { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 },
  "claude-opus-4-5-20250220": { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 },
  "claude-sonnet-4-6": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  "claude-sonnet-4-5-20250514": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  "claude-sonnet-4-20250514": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  "claude-haiku-4-5-20251001": { input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1 },
};

const DEFAULT_PRICING = { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 };

function getPricing(model) {
  return PRICING[model] || DEFAULT_PRICING;
}

function calcCost(pricing, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens) {
  return (
    (inputTokens * pricing.input +
      outputTokens * pricing.output +
      cacheReadTokens * pricing.cacheRead +
      cacheCreationTokens * pricing.cacheWrite) /
    1_000_000
  );
}

// ─── Tool Classification ───

function classifyTool(toolUse) {
  // JSONL にまれに XML フラグメントが混入するため、改行・タグを含む名前は除外
  const rawName = toolUse.name || "";
  if (rawName.includes("\n") || rawName.includes("<") || rawName.includes(">")) {
    return null;
  }
  const name = rawName;
  const input = toolUse.input || {};

  if (name === "Skill") {
    return { toolName: "Skill", toolDetail: input.skill || "" };
  }
  if (name === "Task") {
    return { toolName: "Task", toolDetail: input.subagent_type || "" };
  }
  if (name.startsWith("mcp__")) {
    const parts = name.split("__");
    const serverName = parts[1] || "";
    return { toolName: name, toolDetail: serverName };
  }
  return { toolName: name, toolDetail: "" };
}

// ─── Parse JSONL ───

async function parseTranscript(transcriptPath) {
  const models = new Map();
  const tools = new Map();
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let totalCacheReadTokens = 0;
  let totalCacheCreationTokens = 0;
  let totalToolCalls = 0;
  let totalApiRequests = 0;
  let mcpCallCount = 0;
  let skillCallCount = 0;
  let subagentCount = 0;
  let firstTimestamp = null;
  let lastTimestamp = null;
  let sessionId = null;
  let cwd = null;
  let gitBranch = null;
  let version = null;

  const rl = createInterface({
    input: createReadStream(transcriptPath, "utf-8"),
    crlfDelay: Infinity,
  });

  for await (const line of rl) {
    if (!line.trim()) continue;

    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }

    // セッション情報の抽出（summary や system メッセージから）
    if (entry.sessionId && !sessionId) {
      sessionId = entry.sessionId;
    }
    if (entry.cwd && !cwd) {
      cwd = entry.cwd;
    }
    if (entry.version && !version) {
      version = entry.version;
    }

    // タイムスタンプ追跡
    const ts = entry.timestamp || entry.isoTimestamp;
    if (ts) {
      if (!firstTimestamp || ts < firstTimestamp) firstTimestamp = ts;
      if (!lastTimestamp || ts > lastTimestamp) lastTimestamp = ts;
    }

    if (entry.type !== "assistant") continue;

    const message = entry.message;
    if (!message) continue;

    totalApiRequests++;

    // モデル別トークン集計
    const model = message.model || "unknown";
    const usage = message.usage || {};
    const inputTokens = usage.input_tokens || 0;
    const outputTokens = usage.output_tokens || 0;
    const cacheReadTokens = usage.cache_read_input_tokens || 0;
    const cacheCreationTokens = usage.cache_creation_input_tokens || 0;

    totalInputTokens += inputTokens;
    totalOutputTokens += outputTokens;
    totalCacheReadTokens += cacheReadTokens;
    totalCacheCreationTokens += cacheCreationTokens;

    if (!models.has(model)) {
      models.set(model, {
        model,
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        costUsd: 0,
        apiRequestCount: 0,
      });
    }
    const m = models.get(model);
    m.inputTokens += inputTokens;
    m.outputTokens += outputTokens;
    m.cacheReadTokens += cacheReadTokens;
    m.cacheCreationTokens += cacheCreationTokens;
    m.apiRequestCount++;

    // ツール集計
    const content = message.content || [];
    for (const block of content) {
      if (block.type !== "tool_use") continue;

      const classified = classifyTool(block);
      if (!classified) continue;
      totalToolCalls++;
      const { toolName, toolDetail } = classified;

      if (toolName === "Skill") skillCallCount++;
      else if (toolName === "Task") subagentCount++;
      else if (toolName.startsWith("mcp__")) mcpCallCount++;

      const key = `${toolName}|||${toolDetail}`;
      if (!tools.has(key)) {
        tools.set(key, { toolName, toolDetail, callCount: 0 });
      }
      tools.get(key).callCount++;
    }
  }

  // モデル別コスト計算
  let totalCost = 0;
  for (const m of models.values()) {
    const pricing = getPricing(m.model);
    m.costUsd = calcCost(pricing, m.inputTokens, m.outputTokens, m.cacheReadTokens, m.cacheCreationTokens);
    totalCost += m.costUsd;
  }

  // git branch の抽出を試みる（cwd ベースのフォールバック）
  if (!gitBranch && cwd && typeof cwd === "string") {
    try {
      const { resolve } = await import("node:path");
      const { statSync } = await import("node:fs");
      const resolvedCwd = resolve(cwd);
      const stat = statSync(resolvedCwd);
      if (stat.isDirectory()) {
        const { execSync } = await import("node:child_process");
        gitBranch = execSync("git rev-parse --abbrev-ref HEAD", {
          cwd: resolvedCwd,
          encoding: "utf-8",
          timeout: 5000,
        }).trim();
      }
    } catch {
      // git が使えない環境では無視
    }
  }

  return {
    sessionId: sessionId || transcriptPath.split("/").pop()?.replace(".jsonl", "") || "unknown",
    version: version || "unknown",
    cwd: cwd || "",
    gitBranch: gitBranch || null,
    startedAt: firstTimestamp || new Date().toISOString(),
    endedAt: lastTimestamp || new Date().toISOString(),
    totalInputTokens,
    totalOutputTokens,
    totalCacheReadTokens,
    totalCacheCreationTokens,
    costUsd: totalCost,
    totalToolCalls,
    totalApiRequests,
    mcpCallCount,
    skillCallCount,
    subagentCount,
    models: Array.from(models.values()),
    tools: Array.from(tools.values()),
  };
}

// ─── Send to API ───

function validateApiUrl(raw) {
  let parsed;
  try { parsed = new URL(raw); } catch { throw new Error(`Invalid MUSUBI_API_URL: ${raw}`); }
  if (!["https:", "http:"].includes(parsed.protocol)) {
    throw new Error(`MUSUBI_API_URL must use http or https: ${raw}`);
  }
  return parsed.origin;
}

async function sendToApi(data, apiUrl, apiKey, retries = 3) {
  const origin = validateApiUrl(apiUrl);
  const url = `${origin}/api/transcript`;

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify(data),
        signal: AbortSignal.timeout(30_000),
      });
      if (!res.ok) throw new Error(`API returned ${res.status}`);
      return res.json();
    } catch (err) {
      if (attempt === retries) throw err;
      const delay = Math.min(1000 * 2 ** (attempt - 1), 10_000);
      await new Promise((r) => setTimeout(r, delay));
    }
  }
}

// ─── Main ───

async function main() {
  const { values } = parseArgs({
    options: {
      transcript: { type: "string" },
      "api-url": { type: "string" },
    },
  });

  const transcriptPath = values.transcript;
  if (!transcriptPath) {
    console.error("Usage: node parse-transcript.mjs --transcript <path> [--api-url <url>]");
    process.exit(1);
  }

  const apiUrl = values["api-url"] || process.env.MUSUBI_API_URL || "https://api.musubi-me.app";
  const apiKey = process.env.MUSUBI_API_KEY;

  if (!apiKey) {
    console.error("API key is required (set MUSUBI_API_KEY env var)");
    process.exit(1);
  }

  const data = await parseTranscript(transcriptPath);
  console.error(`Parsed session ${data.sessionId}: ${data.totalApiRequests} API requests, ${data.totalToolCalls} tool calls, $${data.costUsd.toFixed(4)}`);

  await sendToApi(data, apiUrl, apiKey);
  console.error(`Sent to ${apiUrl}: ok`);
}

main().catch((err) => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
