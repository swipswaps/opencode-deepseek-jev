import { IS_DEMO } from "./demo.js";

export { IS_DEMO };

export async function fetchJSON(path, ms = 12000) {
  const opts = ms && typeof AbortSignal !== "undefined" && AbortSignal.timeout
    ? { signal: AbortSignal.timeout(ms) }
    : undefined;
  const res = await fetch(path, opts);
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return res.json();
}

export function fmtUsd(n) {
  const v = Number(n) || 0;
  return "$" + (Math.abs(v) >= 1 ? v.toFixed(2) : v.toFixed(4));
}

const intFmt = new Intl.NumberFormat("en", { maximumFractionDigits: 0 });
const compactFmt = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
export const fmtInt = (n) => intFmt.format(Number(n) || 0);
export const fmtCompact = (n) => compactFmt.format(Number(n) || 0);

export function fmtDur(ms) {
  const v = Math.max(0, Number(ms) || 0);
  if (v >= 3600000) return (v / 3600000).toFixed(1) + "h";
  if (v >= 60000) return (v / 60000).toFixed(1) + "m";
  if (v >= 1000) return (v / 1000).toFixed(1) + "s";
  return Math.round(v) + "ms";
}

export function timeStr(ms) {
  if (!ms) return "";
  const d = new Date(Number(ms));
  try {
    return d.toLocaleTimeString(undefined, { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" }) +
      "." + String(d.getMilliseconds()).padStart(3, "0");
  } catch {
    return String(ms);
  }
}

export function dateStr(ms) {
  if (!ms) return "";
  try {
    return new Date(Number(ms)).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  } catch {
    return String(ms);
  }
}

export function parseModel(model) {
  if (!model) return "?";
  try {
    const m = typeof model === "string" ? JSON.parse(model) : model;
    return [m.providerID, m.id].filter(Boolean).join("/") || m.id || "?";
  } catch {
    return String(model);
  }
}

export function activityType(x) {
  if (x.type === "tool") return x.tool || "tool";
  if (x.type === "reasoning") return "reasoning";
  if (x.type === "text") return "text";
  if (x.type === "patch") return "patch";
  return x.type || "?";
}

export function activityDetail(x) {
  return x.cmd || x.text || x.files || "";
}

export function activityStatus(x) {
  if (x.type !== "tool") return "";
  return x.status || "";
}

export function activityColor(x) {
  if (x.status === "error") return "error";
  if (x.type === "tool") return x.status === "running" || x.status === "pending" ? "warning" : "primary";
  if (x.type === "text") return "success";
  if (x.type === "reasoning") return "secondary";
  if (x.type === "patch") return "error";
  return "default";
}

export function matchesFilter(x, filter) {
  if (filter === "all") return true;
  if (filter === "tools") return x.type === "tool";
  if (filter === "text") return x.type === "text";
  if (filter === "reasoning") return x.type === "reasoning";
  if (filter === "errors") return x.status === "error";
  if (filter === "steps") return String(x.type || "").startsWith("step");
  return true;
}

export function activityTiming(x, now = Date.now()) {
  const start = Number(x.ts) || now;
  let end = Number(x.te) || 0;
  const running = x.status === "running" || x.status === "pending" || !end;
  if (running || end < start) end = now;
  if (end - start < 150) end = start + 150;
  return { start, end, running, ms: end - start };
}

export function sessionDuration(s) {
  const a = Number(s.p_start) || 0;
  const b = Number(s.p_end) || 0;
  if (b > a) return b - a;
  const d = Number(s.time_updated) - Number(s.time_created);
  return d > 0 ? d : 0;
}

export function sessionHref(id) {
  if (IS_DEMO) return "#";
  try {
    const srv = `${location.protocol}//${location.hostname}:4096`;
    const b64 = btoa(srv).replace(/=+$/, "");
    return `${srv}/server/${b64}/session/${encodeURIComponent(id)}`;
  } catch {
    return "#";
  }
}

export function copyText(text, done) {
  const t = String(text == null ? "" : text);
  const finish = () => done && done();
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t).then(finish, () => fallback(t, finish));
      return;
    }
  } catch {
    /* fall through */
  }
  fallback(t, finish);
}

function fallback(text, done) {
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    ta.remove();
    done();
  } catch {
    /* clipboard unavailable */
  }
}
