(() => {
  "use strict";

  // Main-world companion for the isolated DOM HUD. It only discovers the
  // renderer's existing notification manager and observes token updates; it
  // never sends a request or mutates React state.
  const MARKER = "codex-island-cache-bridge-v1";
  const API_KEY = "__codexIslandCacheHUDBridgeV1";
  const MESSAGE_TYPE = "codexisland:conversation-usage";
  const TOKEN_USAGE_METHOD = "thread/tokenUsage/updated";
  const FIBER_PREFIX = "__reactFiber$";
  const MAX_FIBER_DEPTH = 120;
  const MAX_FIBER_NODES = 600;
  const MAX_FIBER_STARTS = 24;

  const previous = globalThis[API_KEY];
  if (previous?.marker === MARKER) {
    try {
      previous.dispose?.();
    } catch {
      // A renderer reload can leave the previous bridge half-disposed.
    }
  }

  let enabled = false;
  let started = false;
  let observer = null;
  let syncScheduled = false;
  let syncTimer = null;
  let lastManagerCount = 0;
  const subscriptions = new Map();

  function isElement(value) {
    return value instanceof Element;
  }

  function isObjectLike(value) {
    return (typeof value === "object" && value !== null) || typeof value === "function";
  }

  function isRecord(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  function nonEmptyString(value) {
    return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
  }

  function nonNegativeInteger(value) {
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return value;
    if (typeof value === "string" && /^\d+$/u.test(value)) return Number(value);
    return undefined;
  }

  function read(value, key) {
    try {
      return value?.[key];
    } catch {
      return undefined;
    }
  }

  function uniqueElements(elements) {
    return [...new Set([...elements].filter(isElement))];
  }

  function ancestorAttribute(element, names) {
    let current = element;
    for (let depth = 0; current && depth < 10; depth += 1) {
      for (const name of names) {
        const value = nonEmptyString(current.getAttribute?.(name));
        if (value) return value;
      }
      current = current.parentElement;
    }
    return null;
  }

  function composerRoots() {
    const explicit = uniqueElements(
      document.querySelectorAll("[data-codex-composer-root], [data-codex-composer]"),
    );
    if (explicit.length > 0) return explicit;

    const roots = [];
    for (const editor of document.querySelectorAll(
      'textarea, [contenteditable="true"][role="textbox"], [role="textbox"]',
    )) {
      let current = editor.parentElement;
      for (let depth = 0; current && depth < 8; depth += 1) {
        if (current.matches("form") || current.querySelector('button[type="submit"]')) {
          roots.push(current);
          break;
        }
        current = current.parentElement;
      }
    }
    return uniqueElements(roots);
  }

  function threadIdForComposer(composer) {
    const direct = ancestorAttribute(composer, [
      "data-codex-island-thread-id",
      "data-thread-id",
      "data-conversation-id",
    ]);
    if (direct) return direct;
    const portalIds = [
      ...new Set(
        [...composer.querySelectorAll("[data-above-composer-conversation-id]")]
          .map((element) => nonEmptyString(element.getAttribute("data-above-composer-conversation-id")))
          .filter(Boolean),
      ),
    ];
    return portalIds.length === 1 ? portalIds[0] : null;
  }

  function fiberStarts(composer) {
    const starts = [];
    const seen = new Set();
    for (const element of [composer, ...composer.querySelectorAll("*")]) {
      const names = Object.getOwnPropertyNames(element).filter((name) =>
        name.startsWith(FIBER_PREFIX),
      );
      if (names.length !== 1) continue;
      const fiber = Object.getOwnPropertyDescriptor(element, names[0])?.value;
      if (!isObjectLike(fiber) || seen.has(fiber)) continue;
      seen.add(fiber);
      starts.push(fiber);
      if (starts.length >= MAX_FIBER_STARTS) break;
    }
    return starts;
  }

  function inspectCandidate(value, managers) {
    if (!isObjectLike(value)) return;
    if (typeof read(value, "addNotificationCallback") === "function") managers.add(value);
    const requestClient = read(value, "requestClient");
    if (isObjectLike(requestClient) && typeof read(requestClient, "addNotificationCallback") === "function") {
      managers.add(requestClient);
    }
  }

  function inspectFiber(fiber, managers) {
    for (const key of ["memoizedProps", "pendingProps"]) inspectCandidate(read(fiber, key), managers);

    let hook = read(fiber, "memoizedState");
    for (let index = 0; isObjectLike(hook) && index < 100; index += 1) {
      inspectCandidate(hook, managers);
      inspectCandidate(read(hook, "memoizedState"), managers);
      hook = read(hook, "next");
    }
  }

  function discoverNotificationManagers() {
    const managers = new Set();
    for (const composer of composerRoots()) {
      for (const start of fiberStarts(composer)) {
        const queue = [{ fiber: start, depth: 0 }];
        const visited = new Set();
        for (let index = 0; index < queue.length && visited.size < MAX_FIBER_NODES; index += 1) {
          const current = queue[index];
          const fiber = current?.fiber;
          if (!isObjectLike(fiber) || visited.has(fiber) || current.depth > MAX_FIBER_DEPTH) continue;
          visited.add(fiber);
          inspectFiber(fiber, managers);
          for (const key of ["return", "child", "sibling"]) {
            const next = read(fiber, key);
            if (isObjectLike(next) && !visited.has(next)) {
              queue.push({ fiber: next, depth: current.depth + 1 });
            }
          }
        }
      }
    }
    return managers;
  }

  function tokenValue(record, camelName, snakeName) {
    return nonNegativeInteger(read(record, camelName)) ?? nonNegativeInteger(read(record, snakeName));
  }

  function parseNotification(value) {
    if (!isRecord(value) || value.method !== TOKEN_USAGE_METHOD || !isRecord(value.params)) return null;
    const threadId = nonEmptyString(value.params.threadId);
    const turnId = nonEmptyString(value.params.turnId);
    const tokenUsage = value.params.tokenUsage;
    const total = isRecord(tokenUsage) && isRecord(tokenUsage.total) ? tokenUsage.total : null;
    const last = isRecord(tokenUsage) && isRecord(tokenUsage.last) ? tokenUsage.last : null;
    if (!threadId || !turnId || !total) return null;

    const inputTokens = tokenValue(total, "inputTokens", "input_tokens");
    const cachedInputTokens = tokenValue(total, "cachedInputTokens", "cached_input_tokens");
    if (inputTokens === undefined || cachedInputTokens === undefined) return null;

    const outputTokens = tokenValue(total, "outputTokens", "output_tokens") ?? 0;
    const totalTokens =
      tokenValue(total, "totalTokens", "total_tokens") ?? inputTokens + outputTokens;
    const cacheWriteInputTokens =
      tokenValue(total, "cacheWriteInputTokens", "cache_write_input_tokens") ?? 0;
    const contextUsedTokens = last ? tokenValue(last, "totalTokens", "total_tokens") : undefined;
    const contextWindowTokens = tokenValue(tokenUsage, "modelContextWindow", "model_context_window");
    const lastInputTokens = last ? tokenValue(last, "inputTokens", "input_tokens") : undefined;
    const lastCachedInputTokens = last
      ? tokenValue(last, "cachedInputTokens", "cached_input_tokens")
      : undefined;
    const cacheHitRatePercent =
      lastInputTokens !== undefined &&
      lastCachedInputTokens !== undefined &&
      lastInputTokens > 0
        ? Math.min(100, (lastCachedInputTokens / lastInputTokens) * 100)
        : undefined;
    // CH is defined from the latest request, not the cumulative total. Do
    // not overwrite a valid local snapshot with an incomplete notification.
    if (cacheHitRatePercent === undefined) return null;

    return {
      threadId,
      turnId,
      inputTokens,
      cachedInputTokens,
      cacheWriteInputTokens,
      outputTokens,
      totalTokens,
      ...(contextUsedTokens === undefined ? {} : { contextUsedTokens }),
      ...(contextWindowTokens === undefined ? {} : { contextWindowTokens }),
      ...(cacheHitRatePercent === undefined ? {} : { cacheHitRatePercent }),
    };
  }

  function publish(payload) {
    try {
      window.postMessage({ type: MESSAGE_TYPE, ...payload }, "*");
    } catch {
      // A renderer teardown can race a notification. The next attach will
      // install a fresh bridge, so the failed post can be ignored.
    }
  }

  function removeSubscriptions() {
    for (const unsubscribe of subscriptions.values()) {
      try {
        unsubscribe();
      } catch {
        // The owner may already have disposed the request manager.
      }
    }
    subscriptions.clear();
    lastManagerCount = 0;
  }

  function syncSubscriptions() {
    if (!started || !enabled) {
      removeSubscriptions();
      return;
    }

    const managers = discoverNotificationManagers();
    lastManagerCount = managers.size;
    for (const manager of managers) {
      if (subscriptions.has(manager)) continue;
      try {
        const unsubscribe = manager.addNotificationCallback(TOKEN_USAGE_METHOD, (notification) => {
          const snapshot = parseNotification(notification);
          if (snapshot) publish({ snapshot });
        });
        if (typeof unsubscribe === "function") subscriptions.set(manager, unsubscribe);
      } catch {
        // A changing renderer can invalidate a fiber candidate between scan
        // and subscription. Waiting for the next mutation is sufficient.
      }
    }

    for (const [manager, unsubscribe] of subscriptions) {
      if (managers.has(manager)) continue;
      try {
        unsubscribe();
      } catch {
        // Ignore an already-disposed manager.
      }
      subscriptions.delete(manager);
    }
  }

  function scheduleSync() {
    if (syncScheduled) return;
    syncScheduled = true;
    const run = () => {
      syncScheduled = false;
      syncTimer = null;
      syncSubscriptions();
    };
    syncTimer = window.setTimeout(run, 250);
  }

  function start() {
    if (started) return api;
    started = true;
    syncSubscriptions();
    if (document.documentElement) {
      observer = new MutationObserver((records) => {
        if (records.some((record) => record.type === "childList" || record.type === "attributes")) {
          scheduleSync();
        }
      });
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: [
          "data-codex-composer-root",
          "data-codex-composer",
          "data-above-composer-conversation-id",
          "data-above-composer-portal",
        ],
        childList: true,
        subtree: true,
      });
    }
    return api;
  }

  function dispose() {
    observer?.disconnect();
    observer = null;
    if (syncTimer !== null) window.clearTimeout(syncTimer);
    syncTimer = null;
    started = false;
    syncScheduled = false;
    removeSubscriptions();
  }

  function setEnabled(value) {
    enabled = value === true;
    if (enabled) start();
    else removeSubscriptions();
    publish({ enabled });
    return enabled;
  }

  const api = {
    marker: MARKER,
    start,
    dispose,
    setEnabled,
    inspect() {
      return {
        enabled,
        started,
        composerCount: composerRoots().length,
        notificationManagerCount: lastManagerCount,
        subscriptionCount: subscriptions.size,
      };
    },
  };

  Object.defineProperty(window, API_KEY, {
    configurable: true,
    enumerable: false,
    value: api,
    writable: false,
  });

  void MARKER;
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => start(), { once: true });
  } else start();
})();
