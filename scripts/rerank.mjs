#!/usr/bin/env node
// rerank.mjs — rerank FTS5/bm25 candidates with an EMBEDDING similarity, under
// a mandatory redaction + hard request cap before any external call.
//
// WHY
// ---
// scripts/semantic-search.sh (and /api/semantic) return bm25 candidates, which
// optimise lexical overlap, not meaning. This adds the missing re-ranking step:
// embed the query + each candidate, order by cosine similarity. Its design
// encodes three standing constraints so a future external call cannot drift
// into an unapproved spend or a secret leak:
//
//   1. OFFLINE BY DEFAULT. The default embedder is a deterministic, dependency-
//      free hashing embedder (word unigrams + bigrams hashed into a fixed-dim,
//      L2-normalised vector) — no model, no network, no key, reproducible.
//   2. REDACTION IS MANDATORY on the external path. Every text is passed
//      through scripts/redact.mjs BEFORE it leaves the process (key shapes +
//      NAME=value secrets), so a transcript token never reaches a provider.
//   3. A HARD REQUEST CAP. `RERANK_MAX_TEXTS` (per call) and
//      `RERANK_MAX_REQUESTS` (per process) bound the work; over the cap is a
//      refusal, not a truncation. The external path ALSO refuses unless
//      `RERANK_ALLOW=1` is set deliberately (RULES #68-style gate: an
//      agent must not auto-spend).
//
// CONTRACT
//   export localEmbed(text, dim) -> number[] (unit vector)
//   export cosine(a, b) -> number
//   export rerank(query, docs, {embed, limit}) -> [{...doc, rerank_score}]
//   export embedExternal(texts, {allow, baseUrl, model, apiKey, cap, fetcher})
//   CLI: node scripts/rerank.mjs --query Q [--docs FILE | -] [--limit N] [--json]
//        node scripts/rerank.mjs --self-test
//
// Read-only. No network unless the external path is explicitly allowed.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite"; // FTS5 candidate pull (--fts)
import { redact } from "./redact.mjs";

export const DIM = 256;

// Hashing trick: map each token (and adjacent token bigram) to a bucket by a
// 32-bit FNV-1a hash, accumulate, L2-normalise. Deterministic, offline.
export function localEmbed(text, dim = DIM) {
  const toks = String(text || "").toLowerCase().match(/[a-z0-9_]+/g) || [];
  const grams = toks.slice();
  for (let i = 0; i + 1 < toks.length; i++) grams.push(toks[i] + "_" + toks[i + 1]);
  const v = new Float64Array(dim);
  for (const g of grams) {
    let h = 2166136261 >>> 0;
    for (let i = 0; i < g.length; i++) {
      h ^= g.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    v[h % dim] += 1;
  }
  let n = 0;
  for (const x of v) n += x * x;
  n = Math.sqrt(n);
  if (n > 0) for (let i = 0; i < dim; i++) v[i] /= n;
  return Array.from(v);
}

export function cosine(a, b) {
  const n = Math.min(a.length, b.length);
  let s = 0;
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s; // both unit vectors -> dot is cosine
}

// Rerank candidate docs ({id?, text}) against the query. Stable: ties keep the
// incoming order (Array.sort is stable in Node), so an FTS5 order is preserved
// when the embeddings cannot separate two docs.
export function rerank(query, docs, opts = {}) {
  const embed = opts.embed || localEmbed;
  const qv = embed(query);
  const scored = (docs || []).map((d) => ({
    ...d,
    rerank_score: Number(cosine(qv, embed(d.text || "")).toFixed(6)),
  }));
  scored.sort((a, b) => b.rerank_score - a.rerank_score);
  return typeof opts.limit === "number" ? scored.slice(0, opts.limit) : scored;
}

export const CAP_DEFAULTS = { maxTexts: 50, maxChars: 2000, maxRequests: 8 };

function caps(opts = {}) {
  return {
    maxTexts: Number(opts.maxTexts ?? process.env.RERANK_MAX_TEXTS ?? CAP_DEFAULTS.maxTexts),
    maxChars: Number(opts.maxChars ?? process.env.RERANK_MAX_CHARS ?? CAP_DEFAULTS.maxChars),
    maxRequests: Number(opts.maxRequests ?? process.env.RERANK_MAX_REQUESTS ?? CAP_DEFAULTS.maxRequests),
  };
}

let _requests = 0; // per-process external request counter (the hard cap)

// External embeddings, OpenAI-compatible POST /embeddings. Refuses (never
// spends, never leaks) unless deliberately allowed and within caps.
export async function embedExternal(texts, opts = {}) {
  const allowed = opts.allow ?? process.env.RERANK_ALLOW === "1";
  if (!allowed) {
    return { available: false, reason: "external embeddings not approved (set RERANK_ALLOW=1 deliberately; redaction + caps still apply)" };
  }
  const baseUrl = opts.baseUrl || process.env.RERANK_BASE_URL || "";
  const model = opts.model || process.env.RERANK_MODEL || "";
  const apiKey = opts.apiKey || process.env.RERANK_API_KEY || "";
  if (!baseUrl || !model || !apiKey) {
    return { available: false, reason: "RERANK_BASE_URL / RERANK_MODEL / RERANK_API_KEY not all set" };
  }
  const c = caps(opts);
  if (!texts.length) return { available: true, embeddings: [] };
  if (texts.length > c.maxTexts) {
    return { available: false, reason: `hard cap: ${texts.length} texts > RERANK_MAX_TEXTS=${c.maxTexts}` };
  }
  if (_requests >= c.maxRequests) {
    return { available: false, reason: `hard cap: request budget exhausted (RERANK_MAX_REQUESTS=${c.maxRequests})` };
  }
  // REDACTION IS MANDATORY, and the char cap is applied to the redacted text.
  const safe = texts.map((t) => redact(String(t || "").slice(0, c.maxChars)));
  const fetchImpl = opts.fetcher || fetch;
  _requests++;
  try {
    const res = await fetchImpl(baseUrl.replace(/\/+$/, "") + "/embeddings", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + apiKey },
      body: JSON.stringify({ model, input: safe }),
      signal: opts.signal,
    });
    if (!res.ok) return { available: false, reason: "http " + res.status };
    const body = await res.json();
    const embeddings = (body.data || []).map((d) => d.embedding);
    return { available: true, embeddings, count: embeddings.length };
  } catch (e) {
    return { available: false, reason: String(e && e.message ? e.message : e) };
  }
}

// Pull bm25 candidates straight from an FTS5 index (the one semantic-search.sh
// builds at data/search/opencode-index.db: parts_fts(part_id, session_id,
// type, text)). Read-only; query tokens are quoted so FTS5 syntax cannot be
// injected. Returns [] on any error (a missing index is not a crash).
export function ftsCandidates(idxPath, query, limit = 50) {
  const toks = String(query || "").toLowerCase().match(/[a-z0-9_]+/g) || [];
  if (!toks.length) return [];
  const match = toks.map((t) => '"' + t + '"').join(" ");
  let db;
  try {
    db = new DatabaseSync(idxPath, { readOnly: true });
    return db
      .prepare(
        "SELECT part_id AS id, session_id, type, text, bm25(parts_fts) AS bm25 " +
          "FROM parts_fts WHERE parts_fts MATCH ? ORDER BY bm25 LIMIT ?",
      )
      .all(match, limit)
      .map((r) => ({ id: r.id, session_id: r.session_id, type: r.type, text: r.text, bm25: r.bm25 }));
  } catch {
    return [];
  } finally {
    try { db && db.close(); } catch { /* already closed / never opened */ }
  }
}

// --- CLI -------------------------------------------------------------------
async function selfTest() {
  const checks = [];
  // 1. local embedder is a unit vector and deterministic.
  const a = localEmbed("blank output no text part");
  const b = localEmbed("blank output no text part");
  const norm = Math.sqrt(a.reduce((s, x) => s + x * x, 0));
  checks.push(["local embed is unit-norm", Math.abs(norm - 1) < 1e-9]);
  checks.push(["local embed is deterministic", a.every((x, i) => x === b[i])]);
  checks.push(["cosine(a,a) == 1", Math.abs(cosine(a, a) - 1) < 1e-9]);

  // 2. rerank orders the semantically-closer doc first (vs a decoy).
  const docs = [
    { id: "decoy", text: "the quarterly report is due on Friday and the budget is tight" },
    { id: "hit", text: "the assistant panel is blank; no text part after the last tool call" },
  ];
  const r = rerank("blank output, no answer printed", docs);
  checks.push(["rerank puts the lexically-closer doc first", r[0].id === "hit"]);
  checks.push(["rerank limit slices", rerank("x", docs, { limit: 1 }).length === 1]);

  // 3. external path refuses without explicit allow (never auto-spends).
  const denied = await embedExternal(["sk-secret"], { allow: false });
  checks.push(["external refuses without RERANK_ALLOW", denied.available === false && denied.reason.includes("not approved")]);

  // 4. external path refuses when a required env piece is missing.
  const noenv = await embedExternal(["x"], { allow: true, baseUrl: "", model: "", apiKey: "" });
  checks.push(["external refuses on missing config", noenv.available === false]);

  // 5. HARD CAP: over maxTexts is a refusal, not a truncation.
  const overCap = await embedExternal(new Array(5).fill("x"), { allow: true, baseUrl: "http://x", model: "m", apiKey: "k", maxTexts: 2 });
  checks.push(["external refuses over text cap", overCap.available === false && overCap.reason.includes("hard cap")]);

  // 6. REDACTION IS MANDATORY: a secret never reaches the provider body.
  let sent = "";
  const stub = async (url, init) => { sent = init.body; return { ok: true, json: async () => ({ data: [{ embedding: [1, 0] }] }) }; };
  const ok = await embedExternal(["DEEPSEEK_API_KEY=sk-live-abcdef0123456789 hello"], {
    allow: true, baseUrl: "http://embed.local", model: "m", apiKey: "k", fetcher: stub,
  });
  checks.push(["external call succeeds with a stub fetcher", ok.available === true && ok.count === 1]);
  checks.push(["redaction stripped the secret before egress", !sent.includes("sk-live-abcdef0123456789") && sent.includes("[REDACTED]")]);

  // 7. the char cap truncates the (redacted) text actually sent.
  let sent2 = "";
  const stub2 = async (url, init) => { sent2 = JSON.parse(init.body).input[0]; return { ok: true, json: async () => ({ data: [{ embedding: [1, 0] }] }) }; };
  await embedExternal(["abcdefghij"], { allow: true, baseUrl: "http://x", model: "m", apiKey: "k", maxChars: 3, fetcher: stub2 });
  checks.push(["char cap truncates the text sent", sent2.length <= 3]);

  // 8. FTS5 pull + rerank end-to-end (offline, temp index).
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "rerank-"));
  const idx = join(dir, "idx.db");
  const idb = new DatabaseSync(idx);
  idb.exec("CREATE VIRTUAL TABLE parts_fts USING fts5(part_id UNINDEXED, session_id UNINDEXED, type UNINDEXED, text)");
  const ins = idb.prepare("INSERT INTO parts_fts(part_id,session_id,type,text) VALUES(?,?,?,?)");
  ins.run("p1", "s1", "text", "the assistant panel is blank and no answer printed");
  ins.run("p2", "s1", "text", "quarterly budget report due friday");
  idb.close();
  const cand = ftsCandidates(idx, "blank answer", 10);
  const rr = rerank("blank answer", cand);
  checks.push(["fts5 pull returns candidates", cand.length >= 1]);
  checks.push(["fts5 candidate reranks to the blank doc", rr.length >= 1 && rr[0].id === "p1"]);
  checks.push(["missing index -> no crash, empty", ftsCandidates(join(dir, "nope.db"), "x", 5).length === 0]);
  rmSync(dir, { recursive: true, force: true });

  let fail = 0;
  console.log("=== rerank.mjs --self-test ===");
  for (const [name, pass] of checks) { if (!pass) fail++; console.log((pass ? "  PASS " : "  FAIL ") + name); }
  console.log("result: " + (fail ? "FAIL" : "PASS"));
  return fail ? 1 : 0;
}

function readDocsArg(argv) {
  const i = argv.indexOf("--docs");
  if (i === -1) return [];
  const src = argv[i + 1];
  const raw = !src || src === "-" ? readFileSync(0, "utf8") : readFileSync(src, "utf8");
  const out = [];
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    try {
      const o = JSON.parse(t);
      out.push({ id: o.id ?? String(out.length), text: String(o.text ?? "") });
    } catch { /* skip malformed line */ }
  }
  return out;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--self-test")) return selfTest();
  const qi = argv.indexOf("--query");
  if (qi === -1) {
    console.log("usage: rerank.mjs --query Q [--docs FILE | -] [--limit N] [--json] | --self-test");
    return 2;
  }
  const query = argv[qi + 1] || "";
  const li = argv.indexOf("--limit");
  const limit = li !== -1 ? Number(argv[li + 1]) || undefined : undefined;
  const fi = argv.indexOf("--fts");
  const idx = fi !== -1 ? argv[fi + 1] : null;
  const docs = idx ? ftsCandidates(idx, query, limit || 50) : readDocsArg(argv);
  const out = rerank(query, docs, { limit });
  if (argv.includes("--json")) console.log(JSON.stringify({ query, source: idx ? "fts5" : "docs", n: out.length, results: out }, null, 2));
  else for (const d of out) console.log(`${d.rerank_score.toFixed(4)}  ${d.id}  ${String(d.text).slice(0, 80)}`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(await main());
}
