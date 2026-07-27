importScripts("probe-config.js");

const probeConfig = globalThis.REX_MV3_PROBE_CONFIG ?? {};
const workerBootId = crypto.randomUUID();
const startupReady = (async () => {
  const current = await chrome.storage.local.get({
    serviceWorkerStartCount: 0
  });
  await chrome.storage.local.set({
    serviceWorkerStartCount: current.serviceWorkerStartCount + 1,
    serviceWorkerStartedAt: Date.now(),
    workerBootId
  });
})();

function runtimeIdentity() {
  return {
    extensionId: chrome.runtime.id,
    version: chrome.runtime.getManifest().version
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
  .then(() =>
    reportAgainstCurrentPhase("worker-boot", {
      lifecycle: "boot"
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
    .then(() =>
      reportAgainstCurrentPhase("runtime-startup", {
        lifecycle: "startup"
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
      let reportDelivered = false;
      let error = "";
      try {
        reportDelivered = await deliverReport(context, "worker-ack", {
          injectionCount: message.injectionCount,
          documentURL: message.pageURL ?? sender.url ?? "",
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
        error
      });
      return;
    }

    if (message?.type === "probe-surface-ping") {
      const stored = await chrome.storage.local.get({
        latestProbeContext: null
      });
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
        probeContext: stored.latestProbeContext
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
