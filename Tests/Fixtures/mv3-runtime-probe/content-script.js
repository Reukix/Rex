(() => {
  const root = document.documentElement;
  const phase = root.dataset.rexProbePhase ?? "";
  const phaseToken = root.dataset.rexProbePhaseToken ?? "";
  const documentId = root.dataset.rexProbeDocumentId ?? "";
  const reportURL = root.dataset.rexProbeReportUrl ?? "";
  if (!phase || !phaseToken || !documentId || !reportURL) {
    return;
  }

  const previousInjectionCount = Number(
    root.dataset.rexMv3ProbeInjectionCount ?? "0"
  );
  const injectionCount =
    (Number.isInteger(previousInjectionCount) ? previousInjectionCount : 0) + 1;
  root.dataset.rexMv3ProbeInjectionCount = String(injectionCount);
  root.dataset.rexMv3ContentScript = "injected";
  root.dataset.rexMv3RuntimeMessage = "pending";

  const runtimeId = chrome.runtime.id;
  const version = chrome.runtime.getManifest().version;

  async function postReport(fields) {
    const response = await fetch(reportURL, {
      method: "POST",
      cache: "no-store",
      credentials: "omit",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        event: "content-script",
        source: "content-script",
        phase,
        phaseToken,
        documentId,
        runtimeId,
        version,
        injectionCount,
        documentURL: location.href,
        reportedAt: Date.now(),
        ...fields
      })
    });
    if (!response.ok) {
      throw new Error(`Report endpoint returned ${response.status}`);
    }
  }

  (async () => {
    const stored = await chrome.storage.local.get({
      lifetimeInjectionCount: 0
    });
    const lifetimeInjectionCount =
      (Number.isInteger(stored.lifetimeInjectionCount)
        ? stored.lifetimeInjectionCount
        : 0) + 1;
    await chrome.storage.local.set({
      lifetimeInjectionCount,
      contentScriptInjectedAt: Date.now(),
      contentScriptURL: location.href,
      latestProbeContext: {
        phase,
        phaseToken,
        documentId,
        reportURL
      }
    });

    let workerResponse;
    let workerError = "";
    try {
      workerResponse = await chrome.runtime.sendMessage({
        type: "probe-content-script",
        phase,
        phaseToken,
        documentId,
        reportURL,
        pageURL: location.href,
        injectionCount
      });
    } catch (error) {
      workerError = String(error);
    }

    const workerAck =
      workerResponse?.ok === true &&
      workerResponse.source === "service-worker" &&
      workerResponse.extensionId === runtimeId &&
      workerResponse.version === version &&
      workerResponse.reportDelivered === true;
    root.dataset.rexMv3ContentScriptInjectionCount = String(injectionCount);
    root.dataset.rexMv3RuntimeMessage = workerAck
      ? "acknowledged"
      : "invalid-response";
    root.dataset.rexMv3RuntimeExtensionId =
      workerResponse?.extensionId ?? runtimeId;
    root.dataset.rexMv3RuntimeVersion = version;

    await postReport({
      workerAck,
      workerError: workerError || workerResponse?.error || "",
      workerRuntimeId: workerResponse?.extensionId ?? "",
      workerVersion: workerResponse?.version ?? "",
      lifetimeInjectionCount,
      dnr: {
        pageSignal: root.dataset.rexProbeDnr ?? "pending"
      }
    });
  })().catch(async (error) => {
    root.dataset.rexMv3RuntimeMessage = "error";
    root.dataset.rexMv3RuntimeError = String(error);
    try {
      await postReport({
        workerAck: false,
        workerError: String(error),
        dnr: {
          pageSignal: root.dataset.rexProbeDnr ?? "pending"
        }
      });
    } catch {
      // The extension may have been disabled while this document was reporting.
    }
  });
})();
