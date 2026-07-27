(() => {
  const root = document.documentElement;
  const phaseOutput = document.querySelector("#probe-phase");
  const statusOutput = document.querySelector("#probe-status");
  const documentId = root.dataset.rexProbeDocumentId ?? "";
  const reportURL = root.dataset.rexProbeReportUrl ?? "";
  const contextURL = root.dataset.rexProbeContextUrl ?? "";
  let phase = root.dataset.rexProbePhase ?? "";
  let phaseToken = root.dataset.rexProbePhaseToken ?? "";

  async function postReport(event, fields = {}, context = null) {
    const reportContext = context ?? { phase, phaseToken };
    const response = await fetch(reportURL, {
      method: "POST",
      cache: "no-store",
      credentials: "omit",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        event,
        source: "page",
        phase: reportContext.phase,
        phaseToken: reportContext.phaseToken,
        documentId,
        documentURL: location.href,
        reportedAt: Date.now(),
        ...fields
      })
    });
    if (!response.ok) {
      throw new Error(`Report endpoint returned ${response.status}`);
    }
  }

  function endpoint(pathname, context) {
    const url = new URL(pathname, location.origin);
    url.searchParams.set("phaseToken", context.phaseToken);
    url.searchParams.set("documentId", documentId);
    url.searchParams.set("nonce", crypto.randomUUID());
    return url;
  }

  async function testNetworkPolicy(context) {
    let controlOK = false;
    let controlError = "";
    try {
      const control = await fetch(endpoint("/control", context), {
        cache: "no-store"
      });
      controlOK = control.ok && (await control.text()) === "control-ok";
    } catch (error) {
      controlError = String(error);
    }

    let dnrBlocked = false;
    let blockedStatus = 0;
    let blockedBody = "";
    let blockedError = "";
    try {
      const blocked = await fetch(
        endpoint("/rex-mv3-dnr-blocked", context),
        { cache: "no-store" }
      );
      blockedStatus = blocked.status;
      blockedBody = await blocked.text();
    } catch (error) {
      dnrBlocked = true;
      blockedError = String(error);
    }

    root.dataset.rexProbeDnr = dnrBlocked ? "blocked" : "reached-server";
    await postReport(
      "page-dnr",
      {
        dnr: {
          controlOK,
          controlError,
          blocked: dnrBlocked,
          blockedStatus,
          blockedBody,
          blockedError
        }
      },
      context
    );
    return { controlOK, dnrBlocked };
  }

  async function synchronizePhase() {
    try {
      const response = await fetch(contextURL, { cache: "no-store" });
      if (!response.ok) {
        return;
      }
      const context = await response.json();
      if (!context.phaseToken || context.phaseToken === phaseToken) {
        return;
      }
      const previousPhase = phase;
      phase = context.phase;
      phaseToken = context.phaseToken;
      root.dataset.rexProbePhase = phase;
      root.dataset.rexProbePhaseToken = phaseToken;
      phaseOutput.textContent = phase;
      statusOutput.textContent = "Armed; waiting for Rex runtime change";
      await postReport("phase-armed", {
        previousPhase,
        expectedState: context.expectedState,
        expectedVersion: context.expectedVersion ?? ""
      });
    } catch {
      // The CLI may be between restarts; the next poll retries.
    }
  }

  (async () => {
    const initialContext = { phase, phaseToken };
    await postReport("page-loaded", {
      navigationType:
        performance.getEntriesByType("navigation")[0]?.type ?? "unknown",
      persisted: false
    }, initialContext);
    const network = await testNetworkPolicy(initialContext);
    statusOutput.textContent =
      network.controlOK
        ? network.dnrBlocked
          ? "DNR blocked the probe request"
          : "DNR request reached the server"
        : "Control request failed";
    window.setInterval(synchronizePhase, 300);
  })().catch((error) => {
    statusOutput.textContent = `Failed: ${String(error)}`;
  });
})();
