(() => {
  "use strict";

  // Renderer-only Usage surface adapted from the MIT-licensed CodexHost
  // Usage control. It contains no Host Runtime, model controls, account
  // limits, or app-server transport.
  const MARKER = "codex-island-cache-hud-v1";
  const ROOT_ATTRIBUTE = "data-codex-island-cache-hud";
  const POPOVER_ATTRIBUTE = "data-codex-island-cache-hud-popover";
  const API_KEY = "__codexIslandCacheHUDV1";
  const MESSAGE_TYPE = "codexisland:conversation-usage";
  const EVENT_TYPE = "codexisland:conversation-usage-updated";
  const ENGLISH_MESSAGES = Object.freeze({
    usage: "Usage",
    context: "Context",
    latestCacheHit: "Latest cache hit",
    cacheRead: "Cache read",
    cacheWrite: "Cache write",
    totalTokens: "Total tokens",
    inputOutput: "Input / output",
    sessionCostEstimate: "Session cost estimate",
    details: "Conversation usage details",
  });
  const CHINESE_MESSAGES = Object.freeze({
    usage: "用量",
    context: "上下文",
    latestCacheHit: "最近缓存命中率",
    cacheRead: "缓存读取",
    cacheWrite: "缓存写入",
    totalTokens: "Token 总数",
    inputOutput: "输入 / 输出",
    sessionCostEstimate: "会话费用估算",
    details: "对话用量详情",
  });

  const previous = globalThis[API_KEY];
  if (previous?.marker === MARKER) {
    try {
      previous.dispose?.();
    } catch {
      // A renderer reload can leave the previous HUD half-disposed.
    }
  }

  let enabled = false;
  let started = false;
  let observer = null;
  let applyScheduled = false;
  let applying = false;
  let boundThreadId = null;
  const snapshots = new Map();

  function isElement(value) {
    return value instanceof Element;
  }

  function isRecord(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  function nonNegativeInteger(value) {
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return value;
    if (typeof value === "string" && /^\d+$/u.test(value)) return Number(value);
    return undefined;
  }

  function nonEmptyString(value) {
    return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
  }

  function currentLocale() {
    const candidates = [
      document.documentElement?.lang,
      document.body?.lang,
      globalThis.navigator?.language,
      ...(globalThis.navigator?.languages ?? []),
    ];
    return candidates.some((value) =>
      typeof value === "string" && /^zh(?:[-_]|$)/iu.test(value),
    )
      ? "zh-CN"
      : "en-US";
  }

  function messagesForLocale(locale) {
    return locale === "zh-CN" ? CHINESE_MESSAGES : ENGLISH_MESSAGES;
  }

  function normalizeSnapshot(value) {
    if (!isRecord(value)) return null;
    const threadId = nonEmptyString(value.threadId);
    const turnId = nonEmptyString(value.turnId);
    const inputTokens = nonNegativeInteger(value.inputTokens);
    const cachedInputTokens = nonNegativeInteger(value.cachedInputTokens);
    const cacheWriteInputTokens = nonNegativeInteger(value.cacheWriteInputTokens) ?? 0;
    const providedCacheHitRate =
      typeof value.cacheHitRatePercent === "number" && Number.isFinite(value.cacheHitRatePercent)
        ? Math.min(100, Math.max(0, value.cacheHitRatePercent))
        : undefined;
    if (
      !threadId ||
      !turnId ||
      inputTokens === undefined ||
      cachedInputTokens === undefined ||
      providedCacheHitRate === undefined
    ) {
      return null;
    }
    if (inputTokens === 0 && cachedInputTokens === 0) return null;
    const outputTokens = nonNegativeInteger(value.outputTokens) ?? 0;
    const totalTokens =
      nonNegativeInteger(value.totalTokens) ?? inputTokens + outputTokens;
    const contextUsedTokens = nonNegativeInteger(value.contextUsedTokens);
    const contextWindowTokens = nonNegativeInteger(value.contextWindowTokens);
    const totalCostUsd =
      typeof value.totalCostUsd === "number" && Number.isFinite(value.totalCostUsd) && value.totalCostUsd >= 0
        ? value.totalCostUsd
        : undefined;
    const cacheHitRatePercent = providedCacheHitRate;
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
      ...(totalCostUsd === undefined ? {} : { totalCostUsd }),
      cacheHitRatePercent,
    };
  }

  function decimal(value, fractionDigits) {
    return value.toFixed(fractionDigits).replace(/\.?0+$/u, "");
  }

  function formatTokenCount(value) {
    if (value < 1000) return String(Math.round(value));
    if (value < 1000000) return `${decimal(value / 1000, 1)}k`;
    if (value < 1000000000) return `${decimal(value / 1000000, 1)}M`;
    return `${decimal(value / 1000000000, 1)}B`;
  }

  function formatCacheHitRate(value) {
    return `CH ${decimal(value, 1)}%`;
  }

  function isInsideHUD(element) {
    return isElement(element) && Boolean(element.closest(`[${ROOT_ATTRIBUTE}], [${POPOVER_ATTRIBUTE}]`));
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

  function threadIdForComposer(composer) {
    const direct = ancestorAttribute(composer, [
      "data-codex-island-thread-id",
      "data-thread-id",
      "data-conversation-id",
    ]);
    if (direct) return direct;

    // Current Codex renders the active conversation identity on the portal
    // inside the Composer root. Keep this lookup scoped to the Composer so a
    // background page cannot accidentally supply the visible thread id.
    const portalIds = [
      ...new Set(
        [...composer.querySelectorAll("[data-above-composer-conversation-id]")]
          .map((element) => nonEmptyString(element.getAttribute("data-above-composer-conversation-id")))
          .filter(Boolean),
      ),
    ];
    if (portalIds.length === 1) return portalIds[0];
    return boundThreadId;
  }

  function uniqueElements(elements) {
    return [...new Set([...elements].filter(isElement))];
  }

  function contextUsageAnchor(composer) {
    const candidates = uniqueElements(
      [...composer.querySelectorAll('span[role="img"][aria-label]')].filter((element) => {
        if (isInsideHUD(element)) return false;
        return element.querySelectorAll("svg > circle").length === 2;
      }),
    );
    if (candidates.length === 1) {
      const wrapper = candidates[0].parentElement;
      return wrapper?.parentElement ? wrapper : candidates[0];
    }

    // The native model trigger is the reviewed fallback used by CodexHost
    // when the Context ring has not mounted yet.
    const modelCandidates = uniqueElements(
      [...composer.querySelectorAll('button[aria-haspopup="menu"]')].filter((element) => {
        if (isInsideHUD(element)) return false;
        const label = `${element.getAttribute("aria-label") ?? ""} ${element.textContent ?? ""}`;
        return /model|模型/iu.test(label);
      }),
    );
    if (modelCandidates.length === 1) {
      const root = modelCandidates[0].parentElement;
      return root?.parentElement ? root : modelCandidates[0];
    }
    return null;
  }

  function composerRoots() {
    const explicit = uniqueElements(
      document.querySelectorAll("[data-codex-composer-root], [data-codex-composer]"),
    ).filter((element) => !isInsideHUD(element));
    if (explicit.length > 0) return explicit;

    const roots = [];
    const editors = document.querySelectorAll(
      'textarea, [contenteditable="true"][role="textbox"], [role="textbox"]',
    );
    for (const editor of editors) {
      if (isInsideHUD(editor)) continue;
      let current = editor.parentElement;
      for (let depth = 0; current && depth < 8; depth += 1) {
        const hasSubmit = current.querySelector('button[type="submit"], button[aria-label*="Send" i]');
        const hasFooterAnchor = contextUsageAnchor(current);
        if (hasSubmit || hasFooterAnchor || current.matches("form")) {
          roots.push(current);
          break;
        }
        current = current.parentElement;
      }
    }
    return uniqueElements(roots);
  }

  function applyPopoverChrome(popover) {
    popover.style.position = "fixed";
    popover.style.inset = "auto";
    popover.style.width = "260px";
    popover.style.maxWidth = "min(320px, calc(100vw - 24px))";
    popover.style.padding = "10px 12px";
    popover.style.border =
      "1px solid light-dark(rgba(15, 23, 42, 0.10), color-mix(in srgb, CanvasText 16%, transparent))";
    popover.style.borderRadius = "14px";
    popover.style.backgroundColor =
      "light-dark(Canvas, color-mix(in srgb, Canvas 88%, white 12%))";
    popover.style.color = "CanvasText";
    popover.style.boxShadow =
      "light-dark(0 10px 24px rgba(15, 23, 42, 0.12), 0 20px 45px rgba(0, 0, 0, 0.42)), 0 2px 8px light-dark(rgba(15, 23, 42, 0.06), rgba(0, 0, 0, 0.28))";
    popover.style.font = "13px/1.35 system-ui, sans-serif";
    popover.style.letterSpacing = "0";
    popover.style.zIndex = "2147483647";
  }

  function addDetailRow(parent, label, value) {
    const row = document.createElement("div");
    row.style.display = "grid";
    row.style.gridTemplateColumns = "minmax(0, 1fr) auto";
    row.style.gap = "20px";
    row.style.padding = "4px 0";
    const labelElement = document.createElement("span");
    labelElement.textContent = label;
    labelElement.style.color = "color-mix(in srgb, currentColor 68%, transparent)";
    const valueElement = document.createElement("span");
    valueElement.textContent = value;
    valueElement.style.fontVariantNumeric = "tabular-nums";
    valueElement.style.textAlign = "right";
    row.append(labelElement, valueElement);
    parent.append(row);
  }

  function openPopover(control) {
    const triggerRect = control.trigger.getBoundingClientRect();
    const width = Math.min(320, Math.max(260, window.innerWidth - 24));
    const left = Math.max(12, Math.min(triggerRect.left, window.innerWidth - width - 12));
    control.popover.style.width = `${width}px`;
    control.popover.style.left = `${left}px`;
    control.popover.style.right = "auto";
    control.popover.style.top = "auto";
    control.popover.style.bottom = `${Math.max(12, window.innerHeight - triggerRect.top + 8)}px`;
    control.popover.hidden = false;
    try {
      if (typeof control.popover.showPopover === "function") control.popover.showPopover();
    } catch {
      // The hidden property fallback keeps older WebViews usable.
    }
    control.trigger.setAttribute("aria-expanded", "true");
  }

  function closePopover(control) {
    try {
      if (typeof control.popover.hidePopover === "function") control.popover.hidePopover();
    } catch {
      // The hidden property fallback below is sufficient.
    }
    control.popover.hidden = true;
    control.trigger.setAttribute("aria-expanded", "false");
  }

  function renderDetails(popover, snapshot, messages) {
    popover.replaceChildren();
    const heading = document.createElement("div");
    heading.textContent = messages.usage;
    heading.style.fontWeight = "600";
    heading.style.marginBottom = "6px";
    popover.append(heading);
    if (
      snapshot.contextUsedTokens !== undefined &&
      snapshot.contextWindowTokens !== undefined &&
      snapshot.contextWindowTokens > 0
    ) {
      const contextPercent =
        (snapshot.contextUsedTokens / snapshot.contextWindowTokens) * 100;
      addDetailRow(
        popover,
        messages.context,
        `${decimal(contextPercent, 1)}% / ${formatTokenCount(snapshot.contextWindowTokens)}`,
      );
    }
    addDetailRow(popover, messages.latestCacheHit, formatCacheHitRate(snapshot.cacheHitRatePercent));
    addDetailRow(popover, messages.cacheRead, formatTokenCount(snapshot.cachedInputTokens));
    addDetailRow(popover, messages.cacheWrite, formatTokenCount(snapshot.cacheWriteInputTokens));
    addDetailRow(popover, messages.totalTokens, formatTokenCount(snapshot.totalTokens));
    addDetailRow(
      popover,
      messages.inputOutput,
      `${formatTokenCount(snapshot.inputTokens)} / ${formatTokenCount(snapshot.outputTokens)}`,
    );
    if (snapshot.totalCostUsd !== undefined) {
      addDetailRow(
        popover,
        messages.sessionCostEstimate,
        `$${snapshot.totalCostUsd.toFixed(3)}`,
      );
    }
  }

  function createHUD() {
    const root = document.createElement("div");
    root.setAttribute(ROOT_ATTRIBUTE, "true");
    root.style.display = "none";
    root.style.alignItems = "center";
    root.style.alignSelf = "center";
    root.style.height = "28px";
    root.style.flex = "0 0 auto";
    root.style.verticalAlign = "middle";

    const trigger = document.createElement("button");
    const messages = messagesForLocale(currentLocale());
    trigger.type = "button";
    trigger.setAttribute("aria-haspopup", "dialog");
    trigger.setAttribute("aria-expanded", "false");
    trigger.setAttribute("aria-label", messages.usage);
    trigger.title = messages.usage;
    trigger.style.color = "var(--color-text-tertiary, #8f8f8f)";
    trigger.style.gap = "4px";
    trigger.style.width = "fit-content";
    trigger.style.height = "28px";
    trigger.style.padding = "0 8px";
    trigger.style.verticalAlign = "middle";
    trigger.style.fontSize = "12px";
    trigger.style.lineHeight = "16px";
    trigger.style.fontVariantNumeric = "tabular-nums";
    trigger.style.letterSpacing = "0";
    trigger.style.border = "0";
    trigger.style.background = "transparent";
    trigger.style.cursor = "pointer";
    const label = document.createElement("span");
    label.style.display = "inline-block";
    label.style.whiteSpace = "nowrap";
    trigger.append(label);

    const popover = document.createElement("div");
    popover.setAttribute(POPOVER_ATTRIBUTE, "true");
    popover.setAttribute("role", "dialog");
    popover.setAttribute("aria-label", messages.details);
    popover.setAttribute("popover", "auto");
    popover.hidden = typeof popover.showPopover !== "function";
    applyPopoverChrome(popover);
    const popoverID = `codex-island-cache-hud-${Math.random().toString(36).slice(2)}`;
    popover.id = popoverID;
    trigger.setAttribute("aria-controls", popoverID);

    const control = { root, trigger, popover, label, closeTimer: null };
    const cancelClose = () => {
      if (control.closeTimer === null) return;
      window.clearTimeout(control.closeTimer);
      control.closeTimer = null;
    };
    const scheduleClose = () => {
      cancelClose();
      control.closeTimer = window.setTimeout(() => {
        control.closeTimer = null;
        if (!trigger.matches(":hover") && !popover.matches(":hover")) closePopover(control);
      }, 140);
    };
    trigger.addEventListener("click", () => {
      if (trigger.getAttribute("aria-expanded") === "true") closePopover(control);
      else openPopover(control);
    });
    trigger.addEventListener("pointerenter", () => {
      cancelClose();
      openPopover(control);
    });
    trigger.addEventListener("pointerleave", scheduleClose);
    trigger.addEventListener("focus", () => {
      cancelClose();
      openPopover(control);
    });
    trigger.addEventListener("blur", scheduleClose);
    popover.addEventListener("pointerenter", cancelClose);
    popover.addEventListener("pointerleave", scheduleClose);
    root.append(trigger);
    document.body.append(popover);
    return control;
  }

  function removeHUD(root) {
    if (!isElement(root)) return;
    const popoverID = root.querySelector("button")?.getAttribute("aria-controls");
    if (popoverID) document.getElementById(popoverID)?.remove();
    root.remove();
  }

  function existingHUD(composer) {
    return [...composer.querySelectorAll(`[${ROOT_ATTRIBUTE}="true"]`)][0] ?? null;
  }

  function renderComposer(composer) {
    const current = existingHUD(composer);
    if (!enabled) {
      if (current) removeHUD(current);
      return;
    }
    const anchor = contextUsageAnchor(composer);
    const threadId = threadIdForComposer(composer);
    const snapshot = threadId ? snapshots.get(threadId) : null;
    if (!anchor || !threadId || snapshot?.cacheHitRatePercent === undefined) {
      if (current) removeHUD(current);
      return;
    }

    const locale = currentLocale();
    const messages = messagesForLocale(locale);
    const control = current?._codexIslandControl ?? createHUD();
    control.root._codexIslandControl = control;
    control.root.dataset.codexIslandThreadId = snapshot.threadId;
    control.root.dataset.codexIslandTurnId = snapshot.turnId;
    control.popover.setAttribute("aria-label", messages.details);
    const renderKey = [
      locale,
      snapshot.threadId,
      snapshot.turnId,
      snapshot.inputTokens,
      snapshot.cachedInputTokens,
      snapshot.outputTokens,
      snapshot.totalTokens,
      snapshot.cacheHitRatePercent,
      snapshot.contextUsedTokens,
      snapshot.contextWindowTokens,
      snapshot.cacheWriteInputTokens,
      snapshot.totalCostUsd,
    ].join(":");
    if (control.renderKey !== renderKey) {
      const labelText = formatCacheHitRate(snapshot.cacheHitRatePercent);
      control.label.textContent = labelText;
      control.trigger.setAttribute("aria-label", labelText);
      control.trigger.title = labelText;
      renderDetails(control.popover, snapshot, messages);
      control.renderKey = renderKey;
    }
    control.root.style.display = "inline-flex";
    if (control.root.parentElement !== anchor.parentElement || control.root.nextElementSibling !== anchor) {
      anchor.parentElement.insertBefore(control.root, anchor);
    }
  }

  function removeAllHUDs() {
    for (const root of document.querySelectorAll(`[${ROOT_ATTRIBUTE}="true"]`)) removeHUD(root);
  }

  function apply() {
    if (applying) return;
    applying = true;
    try {
    if (!started || !enabled) {
      removeAllHUDs();
      return;
    }
    const composers = composerRoots();
    for (const composer of composers) renderComposer(composer);
    for (const root of [...document.querySelectorAll(`[${ROOT_ATTRIBUTE}="true"]`)]) {
      if (!root.isConnected || !root.closest('textarea, [contenteditable="true"], [role="textbox"], form, [data-codex-composer-root], [data-codex-composer]')) {
        removeHUD(root);
      }
    }
    } finally {
      applying = false;
    }
  }

  function scheduleApply() {
    if (applyScheduled) return;
    applyScheduled = true;
    const run = () => {
      applyScheduled = false;
      apply();
    };
    if (typeof queueMicrotask === "function") queueMicrotask(run);
    else Promise.resolve().then(run);
  }

  function relevantMutation(record) {
    if (isInsideHUD(record.target)) return false;
    if (
      record.type === "childList" &&
      [...record.addedNodes, ...record.removedNodes].some((node) => {
        if (!isElement(node)) return false;
        return node.matches(`[${ROOT_ATTRIBUTE}], [${POPOVER_ATTRIBUTE}]`) || isInsideHUD(node);
      })
    ) {
      return false;
    }
    if (record.type === "attributes") {
      return [
        "data-codex-composer-root",
        "data-codex-composer",
        "data-codex-island-thread-id",
        "data-thread-id",
        "data-conversation-id",
        "data-above-composer-conversation-id",
        "data-above-composer-portal",
        "aria-label",
        "lang",
        "hidden",
      ].includes(record.attributeName);
    }
    return record.type === "childList";
  }

  function start() {
    if (started) return api;
    started = true;
    apply();
    if (document.documentElement) {
      observer = new MutationObserver((records) => {
        if (records.some(relevantMutation)) scheduleApply();
      });
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: [
          "data-codex-composer-root",
          "data-codex-composer",
          "data-codex-island-thread-id",
          "data-thread-id",
          "data-conversation-id",
          "data-above-composer-conversation-id",
          "data-above-composer-portal",
          "aria-label",
          "lang",
          "hidden",
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
    started = false;
    applyScheduled = false;
    removeAllHUDs();
    snapshots.clear();
    boundThreadId = null;
  }

  function setEnabled(value) {
    enabled = value === true;
    if (enabled) start();
    else apply();
    return enabled;
  }

  function setSnapshot(value) {
    const snapshot = normalizeSnapshot(value);
    if (!snapshot) return false;
    snapshots.set(snapshot.threadId, snapshot);
    scheduleApply();
    return true;
  }

  function clearSnapshot(threadId) {
    const id = nonEmptyString(threadId);
    if (!id) return false;
    const changed = snapshots.delete(id);
    if (changed) scheduleApply();
    return changed;
  }

  function bindVisibleThread(threadId) {
    boundThreadId = nonEmptyString(threadId);
    scheduleApply();
    return boundThreadId;
  }

  const api = {
    marker: MARKER,
    start,
    dispose,
    setEnabled,
    setSnapshot,
    clearSnapshot,
    bindVisibleThread,
    inspect() {
      return {
        enabled,
        started,
        composerCount: composerRoots().length,
        snapshotCount: snapshots.size,
        hudCount: document.querySelectorAll(`[${ROOT_ATTRIBUTE}="true"]`).length,
      };
    },
  };

  window.addEventListener("message", (event) => {
    if (event.source !== window || !isRecord(event.data) || event.data.type !== MESSAGE_TYPE) return;
    if (event.data.enabled !== undefined) setEnabled(event.data.enabled);
    if (event.data.snapshot) setSnapshot(event.data.snapshot);
    if (event.data.clearThreadId) clearSnapshot(event.data.clearThreadId);
    if (event.data.threadId !== undefined && event.data.bindVisibleThread === true) {
      bindVisibleThread(event.data.threadId);
    }
  });

  window.addEventListener(EVENT_TYPE, (event) => {
    const detail = event.detail;
    if (!isRecord(detail)) return;
    if (detail.enabled !== undefined) setEnabled(detail.enabled);
    if (detail.snapshot) setSnapshot(detail.snapshot);
    if (detail.clearThreadId) clearSnapshot(detail.clearThreadId);
  });

  Object.defineProperty(window, API_KEY, {
    configurable: true,
    enumerable: false,
    value: api,
    writable: false,
  });

  // Keep the marker in the emitted source for patch audits.
  void MARKER;
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => start(), { once: true });
  } else start();
})();
