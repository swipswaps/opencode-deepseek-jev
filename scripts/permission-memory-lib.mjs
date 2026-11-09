// permission-memory-lib.mjs — pure helpers for the permission-memory plugin.
//
// Kept OUT of .opencode/plugins/ on purpose: OpenCode's plugin loader treats
// every named export in a plugin file as a plugin factory. memoryKey() returns
// null for a non-command input, which made the loader dereference null
// (.config/.dispose) and abort every headless `opencode run` with a generic
// UnknownError. The plugin re-exports only its factory; the self-test imports
// these helpers directly.
export function normalizeCommand(cmd) {
    return String(cmd ?? "").replace(/\s+/g, " ").trim();
}

export function memoryKey(sessionID, type, metadata) {
    const cmd = normalizeCommand(metadata?.command ?? "");
    if (!cmd) return null;
    return [sessionID ?? "-", String(type ?? "-").toLowerCase(), cmd].join("|");
}
