import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const source = await readFile(new URL("Resources/CodexCacheHUD.js", root), "utf8");
const bridgeSource = await readFile(
  new URL("Resources/CodexCacheHUDBridge.js", root),
  "utf8",
);
const inspectorSource = await readFile(
  new URL("Sources/Model/CodexInspectorClient.swift", root),
  "utf8",
);
const manifest = JSON.parse(
  await readFile(new URL("docs/cache-hud-patch-manifest.json", root), "utf8"),
);

assert.equal(manifest.schemaVersion, 1);
assert.equal(manifest.productBundleId, "com.openai.codex");
assert.equal(manifest.injectionMarker, "codex-island-cache-hud-v1");
assert.ok(source.includes(manifest.injectionMarker));
assert.ok(source.includes('const API_KEY = "__codexIslandCacheHUDV1"'));
assert.ok(source.includes("Object.defineProperty(window, API_KEY"));
assert.ok(source.includes("CH ${decimal(value, 1)}%"));
assert.ok(source.includes('usage: "Usage"'));
assert.ok(source.includes('context: "Context"'));
assert.ok(source.includes('latestCacheHit: "Latest cache hit"'));
assert.ok(source.includes('cacheRead: "Cache read"'));
assert.ok(source.includes('cacheWrite: "Cache write"'));
assert.ok(source.includes('inputOutput: "Input / output"'));
assert.ok(source.includes('sessionCostEstimate: "Session cost estimate"'));
assert.ok(source.includes('totalTokens: "Total tokens"'));
assert.ok(source.includes('context: "上下文"'));
assert.ok(source.includes('"用量"'));
assert.ok(source.includes('"最近缓存命中率"'));
assert.ok(source.includes('"缓存读取"'));
assert.ok(source.includes('"缓存写入"'));
assert.ok(source.includes('"输入 / 输出"'));
assert.ok(source.includes('"会话费用估算"'));
assert.ok(source.includes('"Token 总数"'));
assert.equal(source.includes('"输入 Token"'), false);
assert.equal(source.includes('"输出 Token"'), false);
assert.equal(source.includes('"推理 Token"'), false);
assert.ok(source.includes("snapshot.contextUsedTokens"));
assert.ok(source.includes("snapshot.contextWindowTokens"));
assert.ok(source.includes("snapshot.cacheWriteInputTokens"));
assert.ok(source.includes('document.documentElement?.lang'));
assert.ok(source.includes("providedCacheHitRate"));
assert.ok(source.includes("snapshot.cacheHitRatePercent"));
assert.ok(bridgeSource.includes('const TOKEN_USAGE_METHOD = "thread/tokenUsage/updated"'));
assert.ok(bridgeSource.includes('const API_KEY = "__codexIslandCacheHUDBridgeV1"'));
assert.ok(bridgeSource.includes("addNotificationCallback"));
assert.ok(bridgeSource.includes("tokenUsage.last"));
assert.ok(bridgeSource.includes("cacheWriteInputTokens"));
assert.ok(bridgeSource.includes("contextUsedTokens"));
assert.ok(bridgeSource.includes("contextWindowTokens"));
assert.ok(bridgeSource.includes("cacheHitRatePercent"));
assert.ok(bridgeSource.includes("if (cacheHitRatePercent === undefined) return null;"));
assert.ok(bridgeSource.includes("window.postMessage"));
assert.ok(inspectorSource.includes("static func rendererPort(in commandLine: String)"));
assert.ok(inspectorSource.includes("--remote-debugging-port="));
assert.equal(inspectorSource.includes("process.mainModule"), false);
assert.equal(inspectorSource.includes("webContents"), false);
assert.equal(inspectorSource.includes("--inspect="), false);
assert.equal(inspectorSource.includes("SIGUSR1"), false);
assert.equal(inspectorSource.includes("node:inspector"), false);

for (const marker of [
  ...manifest.rendererTarget.requiredMarkers,
  ...manifest.rendererTarget.supportingMarkers,
]) {
  assert.ok(typeof marker === "string" && marker.length > 0);
}

// The renderer artifact is deliberately a passive DOM surface. It must not
// create a transport, launch a process, or make a request through the host.
for (const artifact of [source, bridgeSource]) {
  for (const forbidden of [
  "fetch(",
  "XMLHttpRequest",
  "WebSocket",
  "remote-debugging",
  "AppleScript",
    "CGWindowList",
  ]) {
    assert.equal(artifact.includes(forbidden), false, `forbidden renderer API: ${forbidden}`);
  }
}

console.log("CodexCacheHUD static contract tests passed");
