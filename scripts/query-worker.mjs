#!/usr/bin/env node
// query-worker.mjs — runs heavy read-only aggregations off the dashboard's
// single-threaded event loop. node:sqlite handles cannot cross threads, so
// this worker re-executes queries in-thread against its own read-only
// handles (opened per call inside query-lib).
//
// Single source of truth: the query bodies live in query-lib.mjs, imported
// by BOTH dashboard.mjs (inline cold path + fallback) and this worker.
// dashboard.mjs is deliberately never imported here: its module scope
// exits without argv[2], which crashes worker startup.
// dbPath arrives per message (workers inherit only [node, script] argv).
//
// Protocol: parent posts {id, fn, dbPath, args};
// worker posts {id, ok, value|error}. Every return must be
// structured-cloneable (plain JSON shapes only — the same shapes already
// served over HTTP and asserted by test-dashboard.sh).
import { parentPort } from "node:worker_threads";
import { healthReport, handoffAdvice, budgetRisks } from "./session-health.mjs";
import { annotateReport, modelLedger } from "./quirks.mjs";
import { apiSignalsFresh, apiPatternsFresh, apiWordsFresh, apiSemanticFresh, apiTrendsFresh,
         apiSearchFresh, apiIntegrationsFresh, apiCostFresh, apiActivityFresh, apiBoardFresh } from "./query-lib.mjs";

const FNS = {
  // Mirrors refreshHealthCache's sync prefix (minus live adjudication,
  // which stays on the main thread with the cache store).
  healthSync(dbPath) {
    const r = healthReport(dbPath);
    Object.assign(r, annotateReport(r));
    r.per_model = modelLedger(dbPath);
    try {
      r.handoff = handoffAdvice(dbPath);
    } catch {
      r.handoff = { available: false };
    }
    try {
      r.risks = budgetRisks(dbPath);
    } catch {
      r.risks = { available: false };
    }
    return r;
  },
  signals(dbPath) {
    return apiSignalsFresh(dbPath);
  },
  // /api/trends: small query, but a cold cache miss must not run on the loop.
  trends(dbPath) {
    return apiTrendsFresh(dbPath);
  },
  // Remaining sync outliers measured on the live store (2026-10-19):
  // search 6.8 s, integrations 8.6 s, cost/activity on the 2 s poll path.
  search(dbPath, q, limit) {
    return apiSearchFresh(dbPath, q, limit);
  },
  integrations(dbPath) {
    return apiIntegrationsFresh(dbPath);
  },
  cost(dbPath) {
    return apiCostFresh(dbPath);
  },
  activity(dbPath) {
    return apiActivityFresh(dbPath);
  },
  patterns(dbPath, limit) {
    return apiPatternsFresh(dbPath, limit);
  },
  words(dbPath, limit) {
    return apiWordsFresh(dbPath, limit);
  },
  // FTS5/bm25 search: the in-memory index build (~19s on a large part table)
  // runs here, never on the dashboard's event loop. The rebuild window
  // (FTS_MIN_REBUILD_MS) is query-lib's default / env knob.
  semantic(dbPath, q, limit) {
    return apiSemanticFresh(dbPath, q, limit);
  },
  models(dbPath) {
    return modelLedger(dbPath);
  },
  // /api/board payload: the cold read (~19s) that used to block the event loop.
  board(dbPath, todoPath, obsDbPath) {
    return apiBoardFresh(dbPath, todoPath, obsDbPath);
  },
};

parentPort.on("message", (m) => {
  const fn = FNS[m.fn];
  if (typeof fn !== "function") {
    parentPort.postMessage({ id: m.id, ok: false, error: "unknown worker fn: " + m.fn });
    return;
  }
  try {
    parentPort.postMessage({ id: m.id, ok: true, value: fn(m.dbPath, ...(m.args || [])) });
  } catch (e) {
    parentPort.postMessage({ id: m.id, ok: false, error: String((e && e.message) || e) });
  }
});
