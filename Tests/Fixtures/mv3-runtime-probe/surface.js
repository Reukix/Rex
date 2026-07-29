const surface = document.body.dataset.probeSurface;
const status = document.querySelector("#probe-status");

function queryTabsWithCallback(queryInfo) {
  return new Promise((resolve, reject) => {
    chrome.tabs.query(queryInfo, (tabs) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message));
        return;
      }
      resolve(tabs);
    });
  });
}

function isProbeTab(tab) {
  try {
    const url = new URL(tab?.url ?? "");
    return (
      url.protocol === "http:" &&
      url.hostname === "127.0.0.1" &&
      url.pathname === "/probe-page.html"
    );
  } catch {
    return false;
  }
}

function hasChromeTabIdentity(tab) {
  return (
    Number.isInteger(tab?.id) &&
    tab.id >= 0 &&
    Number.isInteger(tab?.windowId) &&
    tab.windowId >= 0
  );
}

async function inspectPopupTabContext() {
  if (surface !== "popup") {
    return null;
  }

  try {
    const [currentWindowTabs, lastFocusedWindowTabs, currentTab] =
      await Promise.all([
        chrome.tabs.query({
          active: true,
          currentWindow: true
        }),
        queryTabsWithCallback({
          active: true,
          lastFocusedWindow: true
        }),
        chrome.tabs.getCurrent()
      ]);
    const currentWindowTab = currentWindowTabs[0];
    const lastFocusedWindowTab = lastFocusedWindowTabs[0];
    const sameIdentity =
      hasChromeTabIdentity(currentWindowTab) &&
      hasChromeTabIdentity(lastFocusedWindowTab) &&
      currentWindowTab.id === lastFocusedWindowTab.id &&
      currentWindowTab.windowId === lastFocusedWindowTab.windowId;
    const ready =
      isProbeTab(currentWindowTab) &&
      isProbeTab(lastFocusedWindowTab) &&
      currentTab == null &&
      sameIdentity;
    const tabContext = {
      ready,
      sameIdentity,
      currentWindow: {
        id: currentWindowTab?.id ?? null,
        windowId: currentWindowTab?.windowId ?? null,
        url: currentWindowTab?.url ?? "",
        title: currentWindowTab?.title ?? ""
      },
      lastFocusedWindow: {
        id: lastFocusedWindowTab?.id ?? null,
        windowId: lastFocusedWindowTab?.windowId ?? null,
        url: lastFocusedWindowTab?.url ?? "",
        title: lastFocusedWindowTab?.title ?? ""
      },
      getCurrentTabId: currentTab?.id ?? null
    };

    document.documentElement.dataset.rexProbeActiveTabId =
      Number.isInteger(currentWindowTab?.id) ? String(currentWindowTab.id) : "";
    document.documentElement.dataset.rexProbeActiveTabUrl =
      currentWindowTab?.url ?? "";
    document.documentElement.dataset.rexProbeActiveWindowId =
      Number.isInteger(currentWindowTab?.windowId)
        ? String(currentWindowTab.windowId)
        : "";
    document.documentElement.dataset.rexProbeLastFocusedTabId =
      Number.isInteger(lastFocusedWindowTab?.id)
        ? String(lastFocusedWindowTab.id)
        : "";
    document.documentElement.dataset.rexProbeLastFocusedTabUrl =
      lastFocusedWindowTab?.url ?? "";
    document.documentElement.dataset.rexProbeLastFocusedWindowId =
      Number.isInteger(lastFocusedWindowTab?.windowId)
        ? String(lastFocusedWindowTab.windowId)
        : "";
    document.documentElement.dataset.rexProbeCurrentTabId =
      Number.isInteger(currentTab?.id) ? String(currentTab.id) : "";
    document.documentElement.dataset.rexProbeActionContext =
      ready ? "ready" : "invalid";

    await chrome.storage.local.set({
      popupActiveTabId: currentWindowTab?.id ?? null,
      popupActiveTabURL: currentWindowTab?.url ?? "",
      popupActiveWindowId: currentWindowTab?.windowId ?? null,
      popupLastFocusedTabId: lastFocusedWindowTab?.id ?? null,
      popupLastFocusedTabURL: lastFocusedWindowTab?.url ?? "",
      popupLastFocusedWindowId: lastFocusedWindowTab?.windowId ?? null,
      popupCurrentTabId: currentTab?.id ?? null,
      popupActionContextReady: ready
    });

    if (!ready) {
      return tabContext;
    }

    const createdURL = new URL(
      "/popup-created.html",
      currentWindowTab.url
    );
    createdURL.searchParams.set("source", "rex-mv3-runtime-probe");
    const createdTab = await chrome.tabs.create({
      url: createdURL.href,
      active: false
    });
    document.documentElement.dataset.rexProbeCreatedTabId =
      Number.isInteger(createdTab?.id) ? String(createdTab.id) : "";
    const createdTabURL =
      createdTab?.url || createdTab?.pendingUrl || createdURL.href;
    document.documentElement.dataset.rexProbeCreatedTabUrl = createdTabURL;
    await chrome.storage.local.set({
      popupCreatedTabId: createdTab?.id ?? null,
      popupCreatedTabURL: createdTabURL
    });
    return tabContext;
  } catch (error) {
    document.documentElement.dataset.rexProbeActionContext = "error";
    document.documentElement.dataset.rexProbeTabsError = String(error);
    return {
      ready: false,
      error: String(error)
    };
  }
}

(async () => {
  const tabContext = await inspectPopupTabContext();
  const response = await chrome.runtime.sendMessage({
    type: "probe-surface-ping",
    surface
  });
  await chrome.storage.local.set({
    [`${surface}OpenedAt`]: Date.now()
  });

  if (
    response?.ok !== true ||
    response.source !== "service-worker" ||
    response.extensionId !== chrome.runtime.id
  ) {
    throw new Error("Service worker returned an invalid response");
  }

  status.textContent = "Ready";
  document.documentElement.dataset.rexProbeReady = "true";
  document.documentElement.dataset.rexProbeExtensionId = chrome.runtime.id;
  document.documentElement.dataset.rexProbeMessageSource = response.source;
  document.documentElement.dataset.rexProbeMessageExtensionId =
    response.extensionId;

  const context = response.probeContext;
  if (context?.reportURL && context.phaseToken && context.documentId) {
    await fetch(context.reportURL, {
      method: "POST",
      cache: "no-store",
      credentials: "omit",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        event: "surface-ready",
        source: surface,
        phase: context.phase,
        phaseToken: context.phaseToken,
        documentId: context.documentId,
        runtimeId: chrome.runtime.id,
        version: chrome.runtime.getManifest().version,
        workerAck: true,
        surface,
        tabContext,
        workerTabContext: response.workerTabContext ?? null,
        reportedAt: Date.now()
      })
    });
  }
})().catch((error) => {
  status.textContent = "Failed";
  document.documentElement.dataset.rexProbeReady = "false";
  document.documentElement.dataset.rexProbeError = String(error);
});
