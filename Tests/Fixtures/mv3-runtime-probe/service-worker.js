importScripts("probe-config.js");

const probeConfig = globalThis.REX_MV3_PROBE_CONFIG ?? {};
const workerBootId = crypto.randomUUID();
const startupReady = (async () => {
  const current = await chrome.storage.local.get({
    serviceWorkerStartCount: 0,
    persistentStorageSentinel: ""
  });
  const persistentStorageSentinel =
    current.persistentStorageSentinel || crypto.randomUUID();
  await chrome.storage.local.set({
    serviceWorkerStartCount: current.serviceWorkerStartCount + 1,
    serviceWorkerStartedAt: Date.now(),
    workerBootId,
    persistentStorageSentinel
  });
  return {
    serviceWorkerStartCount: current.serviceWorkerStartCount + 1,
    persistentStorageSentinel
  };
})();

function runtimeIdentity() {
  return {
    extensionId: chrome.runtime.id,
    version: chrome.runtime.getManifest().version
  };
}

function tabSummary(tab) {
  if (!tab) {
    return null;
  }
  return {
    id: tab.id ?? null,
    windowId: tab.windowId ?? null,
    index: tab.index ?? null,
    active: tab.active === true,
    url: tab.url ?? tab.pendingUrl ?? "",
    title: tab.title ?? ""
  };
}

async function fetchCurrentContext() {
  if (!probeConfig.contextURL) {
    return null;
  }
  const response = await fetch(probeConfig.contextURL, {
    cache: "no-store",
    credentials: "omit"
  });
  if (!response.ok) {
    return null;
  }
  return response.json();
}

async function deliverReport(context, event, fields) {
  const reportURL = context?.reportURL || probeConfig.reportURL;
  if (!reportURL || !context?.phaseToken || !context.documentId) {
    return false;
  }
  const identity = runtimeIdentity();
  const response = await fetch(reportURL, {
    method: "POST",
    cache: "no-store",
    credentials: "omit",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      event,
      source: "service-worker",
      phase: context.phase,
      phaseToken: context.phaseToken,
      documentId: context.documentId,
      runtimeId: identity.extensionId,
      version: identity.version,
      fixtureRevision: probeConfig.fixtureRevision ?? "",
      workerBootId,
      workerAck: event === "worker-ack",
      reportedAt: Date.now(),
      ...fields
    })
  });
  return response.ok;
}

async function reportAgainstCurrentPhase(event, fields) {
  const current = await fetchCurrentContext();
  if (!current?.phaseToken) {
    return false;
  }
  return deliverReport(
    {
      ...current,
      documentId: current.latestDocumentId || `worker:${workerBootId}`
    },
    event,
    fields
  );
}

void startupReady
  .then((storageState) =>
    reportAgainstCurrentPhase("worker-boot", {
      lifecycle: "boot",
      ...storageState
    })
  )
  .catch(() => {});

chrome.runtime.onInstalled.addListener((details) => {
  const identity = runtimeIdentity();
  let createdTabPromise = Promise.resolve({
    requested: false,
    tabId: 0,
    url: "",
    error: ""
  });

  if (details.reason === "install" && probeConfig.workerCreatedURL) {
    const createdURL = new URL(probeConfig.workerCreatedURL);
    createdURL.searchParams.set("runtimeId", identity.extensionId);
    createdURL.searchParams.set("version", identity.version);
    // This call intentionally happens before the first await. It verifies the
    // zero-extension hot-install path has a ready Chrome window context.
    createdTabPromise = new Promise((resolve) => {
      chrome.tabs.create({ url: createdURL.href, active: false }, (tab) => {
        resolve({
          requested: true,
          tabId: tab?.id ?? 0,
          url: tab?.url || tab?.pendingUrl || createdURL.href,
          error: chrome.runtime.lastError?.message ?? ""
        });
      });
    });
  }

  void (async () => {
    await startupReady;
    const createdTab = await createdTabPromise;
    await reportAgainstCurrentPhase("runtime-installed", {
      reason: details.reason,
      previousVersion: details.previousVersion ?? "",
      createdTab
    });
  })().catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  void startupReady
    .then((storageState) =>
      reportAgainstCurrentPhase("runtime-startup", {
        lifecycle: "startup",
        ...storageState
      })
    )
    .catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    await startupReady;
    const identity = runtimeIdentity();

    if (message?.type === "probe-content-script") {
      const context = {
        phase: message.phase,
        phaseToken: message.phaseToken,
        documentId: message.documentId,
        reportURL: message.reportURL
      };
      await chrome.storage.local.set({
        latestProbeContext: context,
        lastContentRuntimeMessage: message.type,
        lastContentMessageAt: Date.now(),
        lastContentSenderURL: sender.url ?? ""
      });
      const senderTab = {
        id: sender.tab?.id ?? null,
        windowId: sender.tab?.windowId ?? null,
        url: sender.tab?.url ?? sender.url ?? "",
        title: sender.tab?.title ?? "",
        frameId: sender.frameId ?? null,
        documentId: sender.documentId ?? ""
      };
      let tabQueries = {
        currentWindow: null,
        lastFocusedWindow: null,
        senderListed: false,
        senderMatch: null,
        error: ""
      };
      try {
        const [currentWindowTabs, lastFocusedWindowTabs, allTabs] =
          await Promise.all([
            chrome.tabs.query({ active: true, currentWindow: true }),
            chrome.tabs.query({ active: true, lastFocusedWindow: true }),
            chrome.tabs.query({})
          ]);
        const senderMatch = allTabs.find((tab) => tab.id === senderTab.id);
        tabQueries = {
          currentWindow: tabSummary(currentWindowTabs[0]),
          lastFocusedWindow: tabSummary(lastFocusedWindowTabs[0]),
          senderListed: Boolean(senderMatch),
          senderMatch: tabSummary(senderMatch),
          error: ""
        };
      } catch (queryError) {
        tabQueries.error = String(queryError);
      }

      let workerToContent = {
        ok: false,
        response: null,
        error: ""
      };
      if (Number.isInteger(senderTab.id) && senderTab.id >= 0) {
        try {
          const request = {
            type: "probe-worker-to-content",
            phaseToken: message.phaseToken,
            documentId: message.documentId
          };
          const response = Number.isInteger(senderTab.frameId)
            ? await chrome.tabs.sendMessage(senderTab.id, request, {
                frameId: senderTab.frameId
              })
            : await chrome.tabs.sendMessage(senderTab.id, request);
          workerToContent = {
            ok:
              response?.ok === true &&
              response.source === "content-script" &&
              response.runtimeId === identity.extensionId &&
              response.documentId === message.documentId,
            response: response ?? null,
            error: ""
          };
        } catch (sendError) {
          workerToContent.error = String(sendError);
        }
      } else {
        workerToContent.error = "sender.tab.id is unavailable";
      }
      let reportDelivered = false;
      let error = "";
      try {
        reportDelivered = await deliverReport(context, "worker-ack", {
          injectionCount: message.injectionCount,
          documentURL: message.pageURL ?? sender.url ?? "",
          senderTab,
          tabQueries,
          workerToContent,
          dnr: {
            source: "page"
          }
        });
      } catch (reportError) {
        error = String(reportError);
      }
      sendResponse({
        ok: true,
        source: "service-worker",
        extensionId: identity.extensionId,
        version: identity.version,
        reportDelivered,
        workerBootId,
        senderTab,
        workerToContent,
        error
      });
      return;
    }

    if (message?.type === "probe-surface-ping") {
      const stored = await chrome.storage.local.get({
        latestProbeContext: null
      });
      let workerTabContext = null;
      if (message.surface === "popup") {
        workerTabContext = {
          lastFocusedWindow: null,
          error: ""
        };
        try {
          const lastFocusedWindowTabs = await chrome.tabs.query({
            active: true,
            lastFocusedWindow: true
          });
          workerTabContext.lastFocusedWindow = tabSummary(
            lastFocusedWindowTabs[0]
          );
        } catch (queryError) {
          workerTabContext.error = String(queryError);
        }
      }
      await chrome.storage.local.set({
        lastSurfaceRuntimeMessage: message.type,
        lastSurface: message.surface,
        lastSurfaceMessageAt: Date.now()
      });
      sendResponse({
        ok: true,
        source: "service-worker",
        extensionId: identity.extensionId,
        version: identity.version,
        surface: message.surface,
        probeContext: stored.latestProbeContext,
        workerTabContext
      });
      return;
    }

    sendResponse({
      ok: false,
      source: "service-worker",
      extensionId: identity.extensionId,
      version: identity.version,
      error: "unknown-message"
    });
  })().catch((error) => {
    const identity = runtimeIdentity();
    sendResponse({
      ok: false,
      source: "service-worker",
      extensionId: identity.extensionId,
      version: identity.version,
      error: String(error)
    });
  });
  return true;
});
