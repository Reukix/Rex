#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.dirname(scriptDirectory);
const fixtureDirectory = path.join(
  projectRoot,
  "Tests",
  "Fixtures",
  "mv3-runtime-probe"
);
const MAX_REPORT_BYTES = 64 * 1024;
const REPORT_EVENTS = new Set([
  "content-script",
  "page-dnr",
  "page-loaded",
  "phase-armed",
  "runtime-installed",
  "runtime-startup",
  "surface-ready",
  "worker-ack",
  "worker-boot"
]);

function usage() {
  return `Usage:
  node Scripts/verify-mv3-extension-runtime.mjs [options]

Runs a loopback-only, self-reporting MV3 probe. It does not launch Rex and does
not use a Chromium debugging endpoint. Keep this CLI running, open the printed
probe URL once in Rex, then use the "next" command before each manual extension
operation. Wait for [ARMED] before acting and never refresh the page manually.

Options:
  --report-port <n>       Loopback HTTP report port; 0 chooses a free port
                          (default: 0)
  --host <address>        Loopback address (default: 127.0.0.1)
  --base-version <v>      Generated v1 manifest version (fixture default)
  --update-version <v>    Generated v2 manifest version (default: 2.0.0)
  --catalog <path>        Optional Rex Extensions/catalog.json to assert
                          enabled/disabled/removed state
  --settle <ms>           Quiet window for exactly-once checks (default: 1000)
  --package-root <path>   Parent directory for generated v1/v2 packages
  --keep-packages         Preserve generated packages when the CLI exits
  --report-log <path>     JSONL event log path (default: .build/...)
  --self-test             Exercise the HTTP protocol and assertion engine
  --help                  Show this help

Interactive commands:
  next                    Arm the next standard phase
  phase <name>            Arm a named standard phase
  status                  Print the current assertion checklist
  assert                  Re-evaluate the current phase
  summary                 Print every started phase
  url                     Print the stable Rex probe URL
  packages                Print generated v1/v2 package paths
  reset                   Start a fresh copy of the current phase without arm
  help                    Print commands
  quit                    Stop the service

HTTP control:
  GET  /status
  GET  /probe-context
  POST /phase             {"name":"hot-install-v1","requireArm":true}
  POST /assert
`;
}

function parseArguments(argv) {
  const options = {
    host: "127.0.0.1",
    reportPort: 0,
    baseVersion: "",
    updateVersion: "2.0.0",
    catalogPath: "",
    settleMs: 1_000,
    packageRoot: "",
    keepPackages: false,
    reportLog: "",
    selfTest: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const nextValue = () => {
      index += 1;
      if (index >= argv.length) {
        throw new Error(`${argument} requires a value`);
      }
      return argv[index];
    };
    switch (argument) {
      case "--report-port":
        options.reportPort = Number(nextValue());
        break;
      case "--host":
        options.host = nextValue();
        break;
      case "--base-version":
        options.baseVersion = nextValue();
        break;
      case "--update-version":
        options.updateVersion = nextValue();
        break;
      case "--catalog":
        options.catalogPath = path.resolve(nextValue());
        break;
      case "--settle":
        options.settleMs = Number(nextValue());
        break;
      case "--package-root":
        options.packageRoot = path.resolve(nextValue());
        break;
      case "--keep-packages":
        options.keepPackages = true;
        break;
      case "--report-log":
        options.reportLog = path.resolve(nextValue());
        break;
      case "--self-test":
        options.selfTest = true;
        break;
      case "--help":
      case "-h":
        console.log(usage());
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown argument: ${argument}`);
    }
  }

  if (!["127.0.0.1", "::1", "localhost"].includes(options.host)) {
    throw new Error("--host must be a loopback address");
  }
  if (
    !Number.isInteger(options.reportPort) ||
    options.reportPort < 0 ||
    options.reportPort > 65_535
  ) {
    throw new Error("--report-port must be an integer from 0 through 65535");
  }
  if (
    !Number.isInteger(options.settleMs) ||
    options.settleMs < 250 ||
    options.settleMs > 30_000
  ) {
    throw new Error("--settle must be an integer from 250 through 30000");
  }
  return options;
}

function expect(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function validExtensionVersion(value) {
  return (
    typeof value === "string" &&
    /^(0|[1-9]\d*)(\.(0|[1-9]\d*)){0,3}$/.test(value)
  );
}

function extensionIdentifier(publicKey) {
  const digest = createHash("sha256")
    .update(Buffer.from(publicKey, "base64"))
    .digest()
    .subarray(0, 16);
  return [...digest]
    .flatMap((byte) => [byte >> 4, byte & 0x0f])
    .map((nibble) => String.fromCharCode(97 + nibble))
    .join("");
}

function packageIdentifier(publicKey) {
  return `local-${createHash("sha256")
    .update(`key:${publicKey}`)
    .digest("hex")
    .slice(0, 32)}`;
}

async function readFixture() {
  const manifestPath = path.join(fixtureDirectory, "manifest.json");
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const rules = JSON.parse(
    await fs.readFile(path.join(fixtureDirectory, "rules.json"), "utf8")
  );
  expect(manifest.manifest_version === 3, "Fixture must use Manifest V3");
  expect(
    typeof manifest.key === "string" && manifest.key.length > 0,
    "Fixture manifest key is missing"
  );
  expect(
    manifest.background?.service_worker === "service-worker.js",
    "Fixture service worker is missing"
  );
  expect(
    manifest.content_scripts?.some((entry) =>
      entry.js?.includes("content-script.js")
    ),
    "Fixture content script is missing"
  );
  expect(
    manifest.host_permissions?.includes("http://127.0.0.1/*"),
    "Fixture must allow the loopback report server"
  );
  expect(
    rules.some((rule) => rule.action?.type === "block"),
    "Fixture DNR block rule is missing"
  );
  return {
    manifest,
    extensionId: extensionIdentifier(manifest.key),
    packageId: packageIdentifier(manifest.key),
    pageTemplate: await fs.readFile(
      path.join(fixtureDirectory, "probe-page.html"),
      "utf8"
    ),
    pageScript: await fs.readFile(
      path.join(fixtureDirectory, "probe-page.js"),
      "utf8"
    )
  };
}

function standardPhases(baseVersion, updateVersion) {
  return [
    {
      name: "baseline-absent",
      expectedState: "inactive",
      expectedVersion: "",
      catalog: "absent",
      action: "Open the probe URL once in Rex with the probe removed."
    },
    {
      name: "hot-install-v1",
      expectedState: "active",
      expectedVersion: baseVersion,
      catalog: "enabled",
      requireWorkerCreated: true,
      action: "Import the generated v1 package in Rex."
    },
    {
      name: "hot-update-v2",
      expectedState: "active",
      expectedVersion: updateVersion,
      catalog: "enabled",
      action: "Import/update from the generated v2 package in Rex."
    },
    {
      name: "hot-disable",
      expectedState: "inactive",
      expectedVersion: "",
      catalog: "disabled",
      action: "Disable the probe extension in Rex."
    },
    {
      name: "hot-enable",
      expectedState: "active",
      expectedVersion: updateVersion,
      catalog: "enabled",
      action: "Enable the probe extension in Rex."
    },
    {
      name: "restart-enabled",
      expectedState: "active",
      expectedVersion: updateVersion,
      catalog: "enabled",
      requireWorkerBoot: true,
      action: "Quit Rex normally, reopen it, and wait for session restoration."
    },
    {
      name: "hot-remove",
      expectedState: "inactive",
      expectedVersion: "",
      catalog: "absent",
      action: "Remove the probe extension in Rex."
    },
    {
      name: "restart-absent",
      expectedState: "inactive",
      expectedVersion: "",
      catalog: "absent",
      action: "Quit and reopen Rex once more with the probe removed."
    }
  ];
}

function countMatching(values, predicate) {
  return values.reduce((count, value) => count + (predicate(value) ? 1 : 0), 0);
}

class ProbeState {
  constructor({
    sessionId,
    fixture,
    phases,
    settleMs,
    reportLog,
    catalogEnabled
  }) {
    this.sessionId = sessionId;
    this.fixture = fixture;
    this.phaseSpecs = phases;
    this.phaseSpecsByName = new Map(phases.map((phase) => [phase.name, phase]));
    this.settleMs = settleMs;
    this.reportLog = reportLog;
    this.catalogEnabled = catalogEnabled;
    this.catalogSnapshot = null;
    this.phases = [];
    this.phasesByToken = new Map();
    this.current = null;
    this.latestDocumentId = "";
    this.activityHandler = null;
  }

  async log(entry) {
    if (!this.reportLog) {
      return;
    }
    await fs.appendFile(
      this.reportLog,
      `${JSON.stringify({
        sessionId: this.sessionId,
        loggedAt: new Date().toISOString(),
        ...entry
      })}\n`
    );
  }

  notify(kind, detail = null) {
    this.activityHandler?.(kind, detail);
  }

  beginPhase(name, { requireArm = Boolean(this.latestDocumentId) } = {}) {
    const spec = this.phaseSpecsByName.get(name);
    if (!spec) {
      throw new Error(`Unknown phase: ${name}`);
    }
    const now = Date.now();
    const phase = {
      ...spec,
      index: this.phases.length,
      phaseToken: randomUUID(),
      requireArm,
      startedAt: now,
      lastActivityAt: now,
      documents: new Map(),
      reports: [],
      controls: [],
      blockedRequests: [],
      workerCreatedRequests: [],
      armedDocuments: new Set(),
      conflicts: [],
      lastPrintedSignature: ""
    };
    this.phases.push(phase);
    this.phasesByToken.set(phase.phaseToken, phase);
    this.current = phase;
    void this.log({
      type: "phase-start",
      phase: this.serializablePhase(phase, false)
    });
    this.notify("phase", phase);
    return phase;
  }

  currentContext() {
    const phase = this.current;
    return {
      protocolVersion: 1,
      sessionId: this.sessionId,
      phase: phase?.name ?? "",
      phaseToken: phase?.phaseToken ?? "",
      expectedState: phase?.expectedState ?? "",
      expectedVersion: phase?.expectedVersion ?? "",
      latestDocumentId: this.latestDocumentId,
      reportURL: this.baseURL ? `${this.baseURL}/extension-report` : ""
    };
  }

  recordDocument(request) {
    const phase = this.current;
    if (!phase) {
      throw new Error("No active probe phase");
    }
    const documentId = randomUUID();
    const document = {
      documentId,
      requestedAt: Date.now(),
      userAgent: request.headers["user-agent"] ?? ""
    };
    phase.documents.set(documentId, document);
    phase.lastActivityAt = Date.now();
    this.latestDocumentId = documentId;
    void this.log({
      type: "document-request",
      phase: phase.name,
      phaseToken: phase.phaseToken,
      document
    });
    this.notify("document", { phase, document });
    return { phase, document };
  }

  recordNetwork(kind, phaseToken, documentId, requestURL) {
    const phase = this.phasesByToken.get(phaseToken);
    if (!phase) {
      return false;
    }
    const record = {
      documentId,
      receivedAt: Date.now(),
      url: requestURL.href
    };
    if (kind === "control") {
      phase.controls.push(record);
    } else if (kind === "blocked") {
      phase.blockedRequests.push(record);
    } else if (kind === "worker-created") {
      phase.workerCreatedRequests.push(record);
    }
    phase.lastActivityAt = Date.now();
    void this.log({
      type: `network-${kind}`,
      phase: phase.name,
      phaseToken,
      record
    });
    this.notify("network", { kind, phase, record });
    return true;
  }

  recordWorkerCreated(requestURL) {
    const phase = this.current;
    if (!phase) {
      return;
    }
    const record = {
      documentId: `worker-created:${randomUUID()}`,
      receivedAt: Date.now(),
      url: requestURL.href
    };
    phase.workerCreatedRequests.push(record);
    phase.lastActivityAt = Date.now();
    void this.log({
      type: "network-worker-created",
      phase: phase.name,
      phaseToken: phase.phaseToken,
      record
    });
    this.notify("network", { kind: "worker-created", phase, record });
  }

  recordReport(report) {
    const phase = this.phasesByToken.get(report.phaseToken);
    if (!phase) {
      throw new Error("Unknown or expired phaseToken");
    }
    const normalized = {
      ...report,
      receivedAt: Date.now()
    };
    if (report.phase !== phase.name) {
      phase.conflicts.push(
        `Report ${report.event} named phase ${report.phase}, expected ${phase.name}`
      );
    }
    const documentEvents = new Set([
      "content-script",
      "page-dnr",
      "page-loaded",
      "worker-ack"
    ]);
    if (
      documentEvents.has(report.event) &&
      !phase.documents.has(report.documentId)
    ) {
      phase.conflicts.push(
        `${report.event} referenced unknown document ${report.documentId}`
      );
    }
    if (report.event === "phase-armed") {
      phase.armedDocuments.add(report.documentId);
    }
    phase.reports.push(normalized);
    phase.lastActivityAt = Date.now();
    void this.log({
      type: "extension-report",
      phase: phase.name,
      phaseToken: phase.phaseToken,
      report: normalized
    });
    this.notify("report", { phase, report: normalized });
    return phase;
  }

  updateCatalog(snapshot) {
    const signature = JSON.stringify(snapshot);
    if (signature === JSON.stringify(this.catalogSnapshot)) {
      return;
    }
    this.catalogSnapshot = snapshot;
    void this.log({
      type: "catalog",
      snapshot
    });
    this.notify("catalog", snapshot);
  }

  evaluate(phase = this.current, { ignoreSettle = false } = {}) {
    if (!phase) {
      return {
        status: "WAIT",
        reasons: ["No phase has started"],
        observations: []
      };
    }
    const failures = [...phase.conflicts];
    const waiting = [];
    const observations = [];
    const reports = phase.reports;

    if (phase.requireArm && phase.armedDocuments.size === 0) {
      waiting.push("existing page has not acknowledged the new phase");
    } else if (phase.requireArm) {
      observations.push(
        `armed by ${phase.armedDocuments.size} existing document(s)`
      );
    }

    const documents = [...phase.documents.values()];
    if (documents.length === 0) {
      waiting.push("waiting for Rex to load the phase document");
    } else if (documents.length > 1) {
      failures.push(
        `expected one document request, received ${documents.length}`
      );
    } else {
      observations.push(`one document request (${documents[0].documentId})`);
    }

    const documentId = documents[0]?.documentId ?? "";
    const pageLoaded = reports.filter(
      (report) =>
        report.event === "page-loaded" && report.documentId === documentId
    );
    const pageDNR = reports.filter(
      (report) =>
        report.event === "page-dnr" && report.documentId === documentId
    );
    const content = reports.filter(
      (report) =>
        report.event === "content-script" && report.documentId === documentId
    );
    const workerAcks = reports.filter(
      (report) =>
        report.event === "worker-ack" && report.documentId === documentId
    );
    const controls = phase.controls.filter(
      (record) => record.documentId === documentId
    );
    const blocked = phase.blockedRequests.filter(
      (record) => record.documentId === documentId
    );

    for (const [label, values] of [
      ["page-loaded report", pageLoaded],
      ["page-dnr report", pageDNR],
      ["control request", controls]
    ]) {
      if (documentId && values.length === 0) {
        waiting.push(`waiting for ${label}`);
      } else if (values.length > 1) {
        failures.push(`expected one ${label}, received ${values.length}`);
      }
    }

    if (phase.expectedState === "active") {
      if (content.length === 0 && documentId) {
        waiting.push("waiting for the content-script report");
      } else if (content.length > 1) {
        failures.push(
          `expected one content-script report, received ${content.length}`
        );
      }
      if (workerAcks.length === 0 && documentId) {
        waiting.push("waiting for the service-worker ack report");
      } else if (workerAcks.length > 1) {
        failures.push(
          `expected one worker ack, received ${workerAcks.length}`
        );
      }
      const contentReport = content[0];
      const workerReport = workerAcks[0];
      if (contentReport) {
        if (contentReport.runtimeId !== this.fixture.extensionId) {
          failures.push(
            `content runtime ID ${contentReport.runtimeId || "(empty)"} does not match`
          );
        }
        if (contentReport.version !== phase.expectedVersion) {
          failures.push(
            `content version ${contentReport.version || "(empty)"} is not ${phase.expectedVersion}`
          );
        }
        if (contentReport.injectionCount !== 1) {
          failures.push(
            `document injectionCount is ${contentReport.injectionCount}, expected 1`
          );
        }
        if (contentReport.workerAck !== true) {
          failures.push("content script did not receive a confirmed worker ack");
        }
      }
      if (workerReport) {
        if (workerReport.runtimeId !== this.fixture.extensionId) {
          failures.push(
            `worker runtime ID ${workerReport.runtimeId || "(empty)"} does not match`
          );
        }
        if (workerReport.version !== phase.expectedVersion) {
          failures.push(
            `worker version ${workerReport.version || "(empty)"} is not ${phase.expectedVersion}`
          );
        }
        if (
          contentReport &&
          workerReport.injectionCount !== contentReport.injectionCount
        ) {
          failures.push("content and worker injection counts do not correlate");
        }
      }
      if (pageDNR[0] && pageDNR[0].dnr?.blocked !== true) {
        failures.push("page reported that the DNR-blocked request completed");
      }
      if (blocked.length > 0) {
        failures.push(
          `DNR-blocked endpoint was reached ${blocked.length} time(s)`
        );
      }
      if (contentReport && workerReport && pageDNR[0]) {
        observations.push(
          `runtime ${contentReport.runtimeId} v${contentReport.version}, ` +
            "one injection, worker ack, DNR blocked"
        );
      }
    } else {
      if (content.length > 0) {
        failures.push(
          `inactive phase received ${content.length} content-script report(s)`
        );
      }
      if (workerAcks.length > 0) {
        failures.push(
          `inactive phase received ${workerAcks.length} worker ack report(s)`
        );
      }
      if (pageDNR[0] && pageDNR[0].dnr?.blocked !== false) {
        failures.push("page reported DNR still blocking in an inactive phase");
      }
      if (documentId && blocked.length === 0) {
        waiting.push("waiting for the unblocked DNR endpoint request");
      } else if (blocked.length > 1) {
        failures.push(
          `expected one unblocked DNR request, received ${blocked.length}`
        );
      }
      if (pageDNR[0] && blocked.length === 1) {
        observations.push("no injection or worker ack; DNR rule absent");
      }
    }

    if (phase.requireWorkerCreated) {
      if (phase.workerCreatedRequests.length === 0) {
        waiting.push("waiting for immediate onInstalled chrome.tabs.create");
      } else if (phase.workerCreatedRequests.length > 1) {
        failures.push(
          `worker-created page loaded ${phase.workerCreatedRequests.length} times`
        );
      } else {
        observations.push("onInstalled chrome.tabs.create loaded one page");
      }
      const installedReports = reports.filter(
        (report) => report.event === "runtime-installed"
      );
      if (installedReports.length === 0) {
        waiting.push("waiting for runtime.onInstalled report");
      } else if (
        !installedReports.some(
          (report) =>
            report.createdTab?.requested === true &&
            report.createdTab?.tabId > 0 &&
            !report.createdTab?.error
        )
      ) {
        failures.push("runtime.onInstalled did not confirm tabs.create success");
      }
    }

    if (phase.requireWorkerBoot) {
      const bootReports = reports.filter(
        (report) => report.event === "worker-boot"
      );
      if (bootReports.length === 0) {
        waiting.push("waiting for a post-restart worker boot");
      } else {
        observations.push("post-restart worker boot reported");
      }
    }

    if (this.catalogEnabled) {
      const snapshot = this.catalogSnapshot;
      if (!snapshot || snapshot.observedAt < phase.startedAt) {
        waiting.push("waiting for a fresh catalog snapshot");
      } else if (snapshot.error) {
        waiting.push(`catalog is temporarily unreadable: ${snapshot.error}`);
      } else if (phase.catalog === "absent" && snapshot.present) {
        failures.push("catalog still contains the probe extension");
      } else if (phase.catalog === "disabled") {
        if (!snapshot.present) {
          failures.push("catalog removed the probe instead of disabling it");
        } else if (snapshot.isEnabled !== false) {
          failures.push("catalog still marks the probe enabled");
        }
      } else if (phase.catalog === "enabled") {
        if (!snapshot.present) {
          failures.push("catalog does not contain the probe extension");
        } else if (snapshot.isEnabled !== true) {
          failures.push("catalog does not mark the probe enabled");
        } else if (snapshot.version !== phase.expectedVersion) {
          failures.push(
            `catalog version ${snapshot.version || "(empty)"} is not ${phase.expectedVersion}`
          );
        }
      }
      if (snapshot && !snapshot.error) {
        observations.push(
          snapshot.present
            ? `catalog ${snapshot.isEnabled ? "enabled" : "disabled"} v${snapshot.version}`
            : "catalog absent"
        );
      }
    }

    if (failures.length > 0) {
      return { status: "FAIL", reasons: failures, observations };
    }
    if (waiting.length > 0) {
      return { status: "WAIT", reasons: waiting, observations };
    }
    const quietFor = Date.now() - phase.lastActivityAt;
    if (!ignoreSettle && quietFor < this.settleMs) {
      return {
        status: "WAIT",
        reasons: [
          `exactly-once quiet window: ${quietFor}/${this.settleMs} ms`
        ],
        observations
      };
    }
    return { status: "PASS", reasons: [], observations };
  }

  serializablePhase(phase, includeEvidence = true) {
    const evaluation = this.evaluate(phase);
    const value = {
      name: phase.name,
      phaseToken: phase.phaseToken,
      expectedState: phase.expectedState,
      expectedVersion: phase.expectedVersion,
      catalogExpectation: phase.catalog,
      requireArm: phase.requireArm,
      startedAt: new Date(phase.startedAt).toISOString(),
      status: evaluation.status,
      reasons: evaluation.reasons,
      observations: evaluation.observations
    };
    if (includeEvidence) {
      value.evidence = {
        armedDocuments: [...phase.armedDocuments],
        documents: [...phase.documents.values()],
        reports: phase.reports,
        controls: phase.controls,
        blockedRequests: phase.blockedRequests,
        workerCreatedRequests: phase.workerCreatedRequests,
        conflicts: phase.conflicts
      };
    }
    return value;
  }

  snapshot() {
    return {
      protocolVersion: 1,
      sessionId: this.sessionId,
      extensionId: this.fixture.extensionId,
      baseURL: this.baseURL ?? "",
      probeURL: this.baseURL ? `${this.baseURL}/probe-page.html` : "",
      current: this.current
        ? this.serializablePhase(this.current)
        : null,
      catalog: this.catalogSnapshot,
      phases: this.phases.map((phase) => this.serializablePhase(phase))
    };
  }
}

function normalizeReport(value) {
  expect(value && typeof value === "object" && !Array.isArray(value), "Report must be an object");
  for (const field of [
    "event",
    "source",
    "phase",
    "phaseToken",
    "documentId"
  ]) {
    expect(
      typeof value[field] === "string" && value[field].length > 0,
      `Report field ${field} is required`
    );
  }
  expect(REPORT_EVENTS.has(value.event), `Unknown report event: ${value.event}`);
  for (const field of ["runtimeId", "version", "fixtureRevision"]) {
    if (value[field] !== undefined) {
      expect(typeof value[field] === "string", `${field} must be a string`);
    }
  }
  if (value.injectionCount !== undefined) {
    expect(
      Number.isInteger(value.injectionCount) && value.injectionCount >= 0,
      "injectionCount must be a non-negative integer"
    );
  }
  if (value.workerAck !== undefined) {
    expect(typeof value.workerAck === "boolean", "workerAck must be boolean");
  }
  return value;
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function renderPage(template, context, documentId, baseURL) {
  const replacements = {
    "{{PHASE}}": context.phase,
    "{{PHASE_TOKEN}}": context.phaseToken,
    "{{DOCUMENT_ID}}": documentId,
    "{{REPORT_URL}}": `${baseURL}/extension-report`,
    "{{CONTEXT_URL}}": `${baseURL}/probe-context`
  };
  let rendered = template;
  for (const [placeholder, value] of Object.entries(replacements)) {
    rendered = rendered.replaceAll(placeholder, escapeHTML(value));
  }
  return rendered;
}

async function readJSONBody(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > MAX_REPORT_BYTES) {
      throw new Error(`Request body exceeds ${MAX_REPORT_BYTES} bytes`);
    }
    chunks.push(chunk);
  }
  if (length === 0) {
    return {};
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function sendJSON(response, status, value) {
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff"
  });
  response.end(`${JSON.stringify(value, null, 2)}\n`);
}

function sendText(response, status, contentType, value) {
  response.writeHead(status, {
    "Content-Type": contentType,
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff"
  });
  response.end(value);
}

async function startReportServer(state, options) {
  const server = http.createServer(async (request, response) => {
    try {
      const authority =
        request.headers.host || `${options.host}:${options.reportPort}`;
      const requestURL = new URL(request.url ?? "/", `http://${authority}`);
      if (request.method === "OPTIONS") {
        response.writeHead(204, {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Headers": "Content-Type",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Cache-Control": "no-store"
        });
        response.end();
        return;
      }

      if (
        request.method === "GET" &&
        requestURL.pathname === "/probe-page.html"
      ) {
        const { document } = state.recordDocument(request);
        const page = renderPage(
          state.fixture.pageTemplate,
          state.currentContext(),
          document.documentId,
          state.baseURL
        );
        sendText(response, 200, "text/html; charset=utf-8", page);
        return;
      }
      if (
        request.method === "GET" &&
        requestURL.pathname === "/probe-page.js"
      ) {
        sendText(
          response,
          200,
          "text/javascript; charset=utf-8",
          state.fixture.pageScript
        );
        return;
      }
      if (
        request.method === "GET" &&
        requestURL.pathname === "/probe-context"
      ) {
        sendJSON(response, 200, state.currentContext());
        return;
      }
      if (request.method === "GET" && requestURL.pathname === "/status") {
        sendJSON(response, 200, state.snapshot());
        return;
      }
      if (request.method === "GET" && requestURL.pathname === "/control") {
        state.recordNetwork(
          "control",
          requestURL.searchParams.get("phaseToken") ?? "",
          requestURL.searchParams.get("documentId") ?? "",
          requestURL
        );
        sendText(response, 200, "text/plain; charset=utf-8", "control-ok");
        return;
      }
      if (
        request.method === "GET" &&
        requestURL.pathname === "/rex-mv3-dnr-blocked"
      ) {
        state.recordNetwork(
          "blocked",
          requestURL.searchParams.get("phaseToken") ?? "",
          requestURL.searchParams.get("documentId") ?? "",
          requestURL
        );
        sendText(
          response,
          200,
          "text/plain; charset=utf-8",
          "dnr-did-not-block"
        );
        return;
      }
      if (
        request.method === "GET" &&
        requestURL.pathname === "/worker-created.html"
      ) {
        state.recordWorkerCreated(requestURL);
        sendText(
          response,
          200,
          "text/html; charset=utf-8",
          "<!doctype html><title>Worker-created tab</title>" +
            "<main id=\"worker-created\">chrome.tabs.create succeeded</main>"
        );
        return;
      }
      if (
        request.method === "GET" &&
        requestURL.pathname === "/popup-created.html"
      ) {
        sendText(
          response,
          200,
          "text/html; charset=utf-8",
          "<!doctype html><title>Popup-created tab</title>" +
            "<main id=\"popup-created\">chrome.tabs.create succeeded</main>"
        );
        return;
      }
      if (request.method === "GET" && requestURL.pathname === "/favicon.ico") {
        response.writeHead(204, { "Cache-Control": "no-store" });
        response.end();
        return;
      }
      if (
        request.method === "POST" &&
        requestURL.pathname === "/extension-report"
      ) {
        const report = normalizeReport(await readJSONBody(request));
        const phase = state.recordReport(report);
        sendJSON(response, 202, {
          accepted: true,
          phase: phase.name,
          status: state.evaluate(phase).status
        });
        return;
      }
      if (request.method === "POST" && requestURL.pathname === "/phase") {
        const body = await readJSONBody(request);
        expect(typeof body.name === "string", "phase name is required");
        const phase = state.beginPhase(body.name, {
          requireArm:
            body.requireArm === undefined
              ? Boolean(state.latestDocumentId)
              : body.requireArm === true
        });
        sendJSON(response, 201, {
          context: state.currentContext(),
          phase: state.serializablePhase(phase)
        });
        return;
      }
      if (request.method === "POST" && requestURL.pathname === "/assert") {
        const evaluation = state.evaluate();
        const status =
          evaluation.status === "PASS"
            ? 200
            : evaluation.status === "FAIL"
              ? 409
              : 425;
        sendJSON(response, status, evaluation);
        return;
      }
      if (request.method === "GET" && requestURL.pathname === "/") {
        sendJSON(response, 200, {
          service: "Rex MV3 self-report probe",
          probeURL: `${state.baseURL}/probe-page.html`,
          statusURL: `${state.baseURL}/status`,
          context: state.currentContext()
        });
        return;
      }
      sendText(response, 404, "text/plain; charset=utf-8", "not-found");
    } catch (error) {
      sendJSON(response, 400, {
        error: error instanceof Error ? error.message : String(error)
      });
    }
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.reportPort, options.host, resolve);
  });
  const address = server.address();
  expect(
    address && typeof address !== "string",
    "Report server did not expose an address"
  );
  const host = options.host === "::1" ? "[::1]" : options.host;
  state.baseURL = `http://${host}:${address.port}`;
  return {
    server,
    baseURL: state.baseURL,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
        server.closeAllConnections?.();
      })
  };
}

function generatedConfig(baseURL, sessionId, revision) {
  return (
    "globalThis.REX_MV3_PROBE_CONFIG = Object.freeze(" +
    `${JSON.stringify(
      {
        protocolVersion: 1,
        sessionId,
        fixtureRevision: revision,
        contextURL: `${baseURL}/probe-context`,
        reportURL: `${baseURL}/extension-report`,
        workerCreatedURL: `${baseURL}/worker-created.html`
      },
      null,
      2
    )});\n`
  );
}

async function preparePackages({
  fixture,
  baseURL,
  sessionId,
  baseVersion,
  updateVersion,
  parentRoot
}) {
  expect(validExtensionVersion(baseVersion), `Invalid base version: ${baseVersion}`);
  expect(
    validExtensionVersion(updateVersion),
    `Invalid update version: ${updateVersion}`
  );
  expect(
    baseVersion !== updateVersion,
    "Base and update versions must differ"
  );
  let workspace;
  if (parentRoot) {
    await fs.mkdir(parentRoot, { recursive: true });
    workspace = path.join(
      parentRoot,
      `rex-mv3-self-report-${sessionId.slice(0, 8)}`
    );
    await fs.mkdir(workspace);
  } else {
    workspace = await fs.mkdtemp(
      path.join(os.tmpdir(), "rex-mv3-self-report-")
    );
  }

  const packages = {};
  for (const [label, version] of [
    ["v1", baseVersion],
    ["v2", updateVersion]
  ]) {
    const destination = path.join(workspace, `${label}-${version}`);
    await fs.cp(fixtureDirectory, destination, {
      recursive: true,
      errorOnExist: true
    });
    const manifest = {
      ...fixture.manifest,
      version
    };
    await fs.writeFile(
      path.join(destination, "manifest.json"),
      `${JSON.stringify(manifest, null, 2)}\n`
    );
    await fs.writeFile(
      path.join(destination, "probe-config.js"),
      generatedConfig(baseURL, sessionId, label)
    );
    packages[label] = {
      version,
      path: destination
    };
  }
  return { workspace, packages };
}

async function readCatalog(pathname, fixture) {
  try {
    const decoded = JSON.parse(await fs.readFile(pathname, "utf8"));
    expect(Array.isArray(decoded), "catalog root is not an array");
    const entry = decoded.find(
      (candidate) =>
        candidate?.runtimeID === fixture.extensionId ||
        candidate?.id === fixture.packageId
    );
    return {
      observedAt: Date.now(),
      present: Boolean(entry),
      isEnabled: entry?.isEnabled ?? false,
      version: entry?.version ?? "",
      runtimeID: entry?.runtimeID ?? "",
      runtimeStatus: entry?.runtimeStatus ?? ""
    };
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {
        observedAt: Date.now(),
        present: false,
        isEnabled: false,
        version: "",
        runtimeID: "",
        runtimeStatus: ""
      };
    }
    return {
      observedAt: Date.now(),
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

function startCatalogMonitor(state, pathname) {
  let stopped = false;
  let timer = null;
  const poll = async () => {
    if (stopped) {
      return;
    }
    state.updateCatalog(await readCatalog(pathname, state.fixture));
    timer = setTimeout(poll, 400);
  };
  void poll();
  return () => {
    stopped = true;
    clearTimeout(timer);
  };
}

function phaseAction(phase, packages) {
  if (phase.name === "hot-install-v1") {
    return `${phase.action}\n         ${packages.v1.path}`;
  }
  if (phase.name === "hot-update-v2") {
    return `${phase.action}\n         ${packages.v2.path}`;
  }
  return phase.action;
}

function printPhaseHeader(state, phase, packages) {
  console.log(
    `\n[PHASE ${phase.index + 1}/${state.phaseSpecs.length}] ${phase.name} ` +
      `(${phase.expectedState}${
        phase.expectedVersion ? ` v${phase.expectedVersion}` : ""
      })`
  );
  if (phase.requireArm) {
    console.log("[WAIT] Existing Rex probe page must report ARMED.");
    console.log("       Do not perform the action and do not refresh yet.");
  } else {
    console.log(`[ACTION] ${phaseAction(phase, packages)}`);
  }
}

function printEvaluation(state, phase = state.current, force = false) {
  if (!phase) {
    console.log("[WAIT] No phase has started.");
    return;
  }
  const evaluation = state.evaluate(phase);
  const signature = JSON.stringify(evaluation);
  if (!force && signature === phase.lastPrintedSignature) {
    return;
  }
  phase.lastPrintedSignature = signature;
  console.log(
    `[${evaluation.status}] ${phase.name}${
      evaluation.reasons.length
        ? ` - ${evaluation.reasons.join("; ")}`
        : ""
    }`
  );
  if (force || evaluation.status === "PASS" || evaluation.status === "FAIL") {
    for (const observation of evaluation.observations) {
      console.log(`  [OBS] ${observation}`);
    }
  }
  if (evaluation.status === "PASS") {
    const next = state.phaseSpecs[phase.index + 1];
    console.log(
      next
        ? `  Run "next" to arm ${next.name}.`
        : "  All standard phases have been started and passed."
    );
  }
}

function installActivityOutput(state, packages) {
  let settleTimer = null;
  state.activityHandler = (kind, detail) => {
    if (kind === "phase") {
      printPhaseHeader(state, detail, packages);
    } else if (
      kind === "report" &&
      detail.report.event === "phase-armed" &&
      detail.phase === state.current
    ) {
      console.log(
        `[ARMED] ${detail.phase.name} acknowledged by ${detail.report.documentId}`
      );
      console.log(`[ACTION] ${phaseAction(detail.phase, packages)}`);
      console.log("         Wait for Rex to reload automatically; do not refresh.");
    } else if (kind === "report") {
      console.log(
        `[REPORT] ${detail.phase.name} ${detail.report.event} ` +
          `${detail.report.documentId}`
      );
    } else if (kind === "document") {
      console.log(
        `[DOCUMENT] ${detail.phase.name} ${detail.document.documentId}`
      );
    } else if (kind === "network") {
      console.log(
        `[NETWORK] ${detail.phase.name} ${detail.kind} ${detail.record.documentId}`
      );
    } else if (kind === "catalog") {
      console.log(
        detail.error
          ? `[CATALOG] unreadable: ${detail.error}`
          : `[CATALOG] ${
              detail.present
                ? `${detail.isEnabled ? "enabled" : "disabled"} v${detail.version}`
                : "absent"
            }`
      );
    }
    printEvaluation(state);
    clearTimeout(settleTimer);
    settleTimer = setTimeout(
      () => printEvaluation(state, state.current, true),
      state.settleMs + 25
    );
  };
  return () => clearTimeout(settleTimer);
}

function printSummary(state) {
  console.log("\nPhase summary:");
  for (const phase of state.phases) {
    const evaluation = state.evaluate(phase);
    console.log(
      `  [${evaluation.status}] ${phase.name}` +
        (evaluation.reasons.length
          ? ` - ${evaluation.reasons.join("; ")}`
          : "")
    );
  }
}

function printCommands() {
  console.log(
    "\nCommands: next | phase <name> | status | assert | summary | url | " +
      "packages | reset | help | quit"
  );
}

function startInteractiveCLI({ state, packages, shutdown }) {
  const interfaceInstance = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: process.stdin.isTTY
  });
  let handling = Promise.resolve();

  interfaceInstance.on("line", (line) => {
    handling = handling
      .then(async () => {
        const [command = "", ...arguments_] = line.trim().split(/\s+/);
        if (!command) {
          return;
        }
        if (command === "next") {
          const currentIndex = state.current
            ? state.phaseSpecs.findIndex(
                (phase) => phase.name === state.current.name
              )
            : -1;
          const next = state.phaseSpecs[currentIndex + 1];
          if (!next) {
            console.log("[INFO] There is no next standard phase.");
            return;
          }
          state.beginPhase(next.name);
          return;
        }
        if (command === "phase") {
          expect(arguments_[0], "phase requires a standard phase name");
          state.beginPhase(arguments_[0]);
          return;
        }
        if (command === "status" || command === "assert") {
          printEvaluation(state, state.current, true);
          return;
        }
        if (command === "summary") {
          printSummary(state);
          return;
        }
        if (command === "url") {
          console.log(`${state.baseURL}/probe-page.html`);
          return;
        }
        if (command === "packages") {
          console.log(`v1 ${packages.v1.version}: ${packages.v1.path}`);
          console.log(`v2 ${packages.v2.version}: ${packages.v2.path}`);
          return;
        }
        if (command === "reset") {
          expect(state.current, "No current phase to reset");
          state.beginPhase(state.current.name, { requireArm: false });
          console.log(
            `[ACTION] Open ${state.baseURL}/probe-page.html in Rex once.`
          );
          return;
        }
        if (command === "help") {
          printCommands();
          return;
        }
        if (command === "quit" || command === "exit") {
          interfaceInstance.close();
          await shutdown(0);
          return;
        }
        throw new Error(`Unknown command: ${command}`);
      })
      .catch((error) => {
        console.error(`[ERROR] ${error.message}`);
      });
  });
  interfaceInstance.on("close", () => {
    if (process.stdin.isTTY) {
      return;
    }
    console.log("[INFO] stdin closed; HTTP service remains active.");
  });
  printCommands();
  return () => interfaceInstance.close();
}

async function postJSON(url, body) {
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
}

async function runSelfTest(options, fixture) {
  const sessionId = randomUUID();
  const phases = standardPhases(
    options.baseVersion || fixture.manifest.version,
    options.updateVersion
  );
  const state = new ProbeState({
    sessionId,
    fixture,
    phases,
    settleMs: options.settleMs,
    reportLog: "",
    catalogEnabled: false
  });
  const server = await startReportServer(state, {
    ...options,
    reportPort: 0
  });
  let packageWorkspace = "";
  try {
    const generated = await preparePackages({
      fixture,
      baseURL: server.baseURL,
      sessionId,
      baseVersion: phases[0].expectedVersion || fixture.manifest.version,
      updateVersion: options.updateVersion,
      parentRoot: ""
    });
    packageWorkspace = generated.workspace;
    const v2Manifest = JSON.parse(
      await fs.readFile(
        path.join(generated.packages.v2.path, "manifest.json"),
        "utf8"
      )
    );
    expect(
      v2Manifest.version === options.updateVersion,
      "Generated update package version is wrong"
    );

    const active = state.beginPhase("hot-update-v2", { requireArm: false });
    const pageResponse = await fetch(`${server.baseURL}/probe-page.html`);
    expect(pageResponse.ok, "Self-test page did not load");
    expect(
      (await pageResponse.text()).includes(active.phaseToken),
      "Rendered page does not contain its phase token"
    );
    const documentId = [...active.documents.keys()][0];
    const reportBase = {
      phase: active.name,
      phaseToken: active.phaseToken,
      documentId
    };
    await postJSON(`${server.baseURL}/extension-report`, {
      ...reportBase,
      event: "page-loaded",
      source: "page"
    });
    await fetch(
      `${server.baseURL}/control?phaseToken=${active.phaseToken}` +
        `&documentId=${documentId}`
    );
    await postJSON(`${server.baseURL}/extension-report`, {
      ...reportBase,
      event: "page-dnr",
      source: "page",
      dnr: { controlOK: true, blocked: true }
    });
    await postJSON(`${server.baseURL}/extension-report`, {
      ...reportBase,
      event: "worker-ack",
      source: "service-worker",
      runtimeId: fixture.extensionId,
      version: options.updateVersion,
      injectionCount: 1,
      workerAck: true
    });
    await postJSON(`${server.baseURL}/extension-report`, {
      ...reportBase,
      event: "content-script",
      source: "content-script",
      runtimeId: fixture.extensionId,
      version: options.updateVersion,
      injectionCount: 1,
      workerAck: true
    });
    expect(
      state.evaluate(active, { ignoreSettle: true }).status === "PASS",
      "Active self-report assertion did not pass"
    );

    const inactive = state.beginPhase("hot-remove", { requireArm: false });
    await fetch(`${server.baseURL}/probe-page.html`);
    const inactiveDocumentId = [...inactive.documents.keys()][0];
    const inactiveBase = {
      phase: inactive.name,
      phaseToken: inactive.phaseToken,
      documentId: inactiveDocumentId
    };
    await postJSON(`${server.baseURL}/extension-report`, {
      ...inactiveBase,
      event: "page-loaded",
      source: "page"
    });
    await fetch(
      `${server.baseURL}/control?phaseToken=${inactive.phaseToken}` +
        `&documentId=${inactiveDocumentId}`
    );
    await fetch(
      `${server.baseURL}/rex-mv3-dnr-blocked?phaseToken=${inactive.phaseToken}` +
        `&documentId=${inactiveDocumentId}`
    );
    await postJSON(`${server.baseURL}/extension-report`, {
      ...inactiveBase,
      event: "page-dnr",
      source: "page",
      dnr: { controlOK: true, blocked: false }
    });
    expect(
      state.evaluate(inactive, { ignoreSettle: true }).status === "PASS",
      "Inactive self-report assertion did not pass"
    );
    console.log(
      "[PASS] Self-report protocol, active/inactive assertions, and package " +
        "generation"
    );
  } finally {
    await server.close().catch(() => {});
    if (packageWorkspace) {
      await fs.rm(packageWorkspace, { recursive: true, force: true });
    }
  }
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const fixture = await readFixture();
  options.baseVersion = options.baseVersion || fixture.manifest.version;
  expect(
    validExtensionVersion(options.baseVersion),
    `Invalid base version: ${options.baseVersion}`
  );
  expect(
    validExtensionVersion(options.updateVersion),
    `Invalid update version: ${options.updateVersion}`
  );
  if (options.selfTest) {
    await runSelfTest(options, fixture);
    return;
  }

  const sessionId = randomUUID();
  const reportLog =
    options.reportLog ||
    path.join(
      projectRoot,
      ".build",
      `mv3-self-report-${sessionId.slice(0, 8)}.jsonl`
    );
  await fs.mkdir(path.dirname(reportLog), { recursive: true });
  await fs.writeFile(reportLog, "");
  const phases = standardPhases(options.baseVersion, options.updateVersion);
  const state = new ProbeState({
    sessionId,
    fixture,
    phases,
    settleMs: options.settleMs,
    reportLog,
    catalogEnabled: Boolean(options.catalogPath)
  });
  const reportServer = await startReportServer(state, options);
  const generated = await preparePackages({
    fixture,
    baseURL: reportServer.baseURL,
    sessionId,
    baseVersion: options.baseVersion,
    updateVersion: options.updateVersion,
    parentRoot: options.packageRoot
  });

  let shuttingDown = false;
  let stopCatalog = () => {};
  let closeCLI = () => {};
  let stopActivityOutput = () => {};
  const shutdown = async (exitCode) => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    closeCLI();
    stopActivityOutput();
    stopCatalog();
    printSummary(state);
    await reportServer.close().catch(() => {});
    if (options.keepPackages) {
      console.log(`Kept generated packages: ${generated.workspace}`);
    } else {
      await fs.rm(generated.workspace, { recursive: true, force: true });
    }
    console.log(`Report log: ${reportLog}`);
    process.exitCode = exitCode;
  };

  stopActivityOutput = installActivityOutput(state, generated.packages);
  if (options.catalogPath) {
    stopCatalog = startCatalogMonitor(state, options.catalogPath);
  }

  console.log("Rex MV3 self-report runtime probe");
  console.log(`Session:      ${sessionId}`);
  console.log(`Extension ID: ${fixture.extensionId}`);
  console.log(`Report URL:   ${reportServer.baseURL}/extension-report`);
  console.log(`Status URL:   ${reportServer.baseURL}/status`);
  console.log(`Probe URL:    ${reportServer.baseURL}/probe-page.html`);
  console.log(`v1 package:   ${generated.packages.v1.path}`);
  console.log(`v2 package:   ${generated.packages.v2.path}`);
  console.log(
    options.catalogPath
      ? `Catalog:      ${options.catalogPath}`
      : "Catalog:      not checked (pass --catalog for UI state assertions)"
  );
  console.log(`Report log:   ${reportLog}`);
  console.log(
    "\nOpen the Probe URL once in Rex. Keep this service running and never " +
      "refresh manually."
  );

  state.beginPhase("baseline-absent", { requireArm: false });
  closeCLI = startInteractiveCLI({
    state,
    packages: generated.packages,
    shutdown
  });
  process.once("SIGINT", () => {
    void shutdown(130);
  });
  process.once("SIGTERM", () => {
    void shutdown(143);
  });
}

main().catch((error) => {
  console.error(`[FAIL] ${error.message}`);
  process.exitCode = 2;
});
