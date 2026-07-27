const surface = document.body.dataset.probeSurface;
const status = document.querySelector("#probe-status");

async function inspectPopupTabContext() {
  if (surface !== "popup") {
    return;
  }

  try {
    const [activeTabs, currentTab] = await Promise.all([
      chrome.tabs.query({
        active: true,
        currentWindow: true
      }),
      chrome.tabs.getCurrent()
    ]);
    const activeTab = activeTabs[0];
    const activeTabURL = activeTab?.url ?? "";
    const activeURL = new URL(activeTabURL);
    const isProbePage =
      activeURL.protocol === "http:" &&
      activeURL.hostname === "127.0.0.1" &&
      activeURL.pathname === "/probe-page.html";

    document.documentElement.dataset.rexProbeActiveTabId =
      Number.isInteger(activeTab?.id) ? String(activeTab.id) : "";
    document.documentElement.dataset.rexProbeActiveTabUrl = activeTabURL;
    document.documentElement.dataset.rexProbeCurrentTabId =
      Number.isInteger(currentTab?.id) ? String(currentTab.id) : "";
    document.documentElement.dataset.rexProbeActionContext =
      isProbePage && currentTab == null ? "ready" : "invalid";

    await chrome.storage.local.set({
      popupActiveTabId: activeTab?.id ?? null,
      popupActiveTabURL: activeTabURL,
      popupCurrentTabId: currentTab?.id ?? null
    });

    if (!isProbePage || currentTab != null) {
      return;
    }

    const createdURL = new URL("/popup-created.html", activeURL);
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
  } catch (error) {
    document.documentElement.dataset.rexProbeActionContext = "error";
    document.documentElement.dataset.rexProbeTabsError = String(error);
  }
}

(async () => {
  await inspectPopupTabContext();
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
        reportedAt: Date.now()
      })
    });
  }
})().catch((error) => {
  status.textContent = "Failed";
  document.documentElement.dataset.rexProbeReady = "false";
  document.documentElement.dataset.rexProbeError = String(error);
});
