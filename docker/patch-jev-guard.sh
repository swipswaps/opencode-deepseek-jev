#!/bin/sh
#
# patch-jev-guard.sh — add JEV_BASE_URL (custom System One backend) to the
# pinned jev-guard@0.3.1 in the opencode package cache.
#
# Why: jev-guard 0.3.1 (npm latest) only knows TypeSafe and the Vercel gateway;
# it ignores JEV_BASE_URL, so guarding through SubQ/Laya/Kev returns
# "typesafe HTTP 401". The feature exists on the project's main branch but is
# not released. This patch is local, offline, idempotent, and a no-op when the
# package already supports it. Remove it once a release ships the feature.
#
# The cache lives in the container filesystem, so this MUST run at every
# container start (both entrypoints call it) or the patch is lost on recreate.
#
set -u

found=0
for f in "$HOME"/.cache/opencode/packages/jev-guard@*/node_modules/jev-guard/src/jev.js; do
    [ -f "$f" ] || continue
    found=1
    if grep -q 'JEV_BASE_URL' "$f"; then
        printf '[patch-jev-guard] already supports JEV_BASE_URL: %s\n' "$f" >&2
        continue
    fi
    python3 - "$f" <<'PY'
import pathlib, sys

p = pathlib.Path(sys.argv[1])
s = p.read_text()

a = ('export function backend(env = process.env) {\n'
     '  if (env.JEV_API_KEY) return { kind: "typesafe", key: env.JEV_API_KEY };')
b = ('export function backend(env = process.env) {\n'
     '  if (env.JEV_BASE_URL) {\n'
     '    const base = String(env.JEV_BASE_URL).replace(/\\/+$/, "");\n'
     '    const url = /\\/v1\\/systemone$/.test(base) ? base : base + "/v1/systemone";\n'
     '    return { kind: "custom", key: env.JEV_BASE_API_KEY || "", url };\n'
     '  }\n'
     '  if (env.JEV_API_KEY) return { kind: "typesafe", key: env.JEV_API_KEY };')
assert a in s, "backend anchor missing"
s = s.replace(a, b, 1)

old = 'const request = () => fetchImpl(gw ? GATEWAY_URL : TYPESAFE_URL, {'
new = ('const url = gw ? GATEWAY_URL : (b.url || TYPESAFE_URL);\n'
       '  const request = () => fetchImpl(url, {')
assert old in s, "fetch anchor missing"
s = s.replace(old, new, 1)

oldh = ': { Authorization: `Bearer ${b.key}`, "Content-Type": "application/json" },'
newh = ': { ...(b.key ? { Authorization: `Bearer ${b.key}` } : {}), "Content-Type": "application/json" },'
assert oldh in s, "header anchor missing"
s = s.replace(oldh, newh, 1)

p.write_text(s)
print("patched " + str(p))
PY
    if [ "$?" -ne 0 ]; then
        printf '[patch-jev-guard] FAILED (anchors changed?): %s\n' "$f" >&2
    fi
done

if [ "$found" -eq 0 ]; then
    printf '[patch-jev-guard] no cached jev-guard package (no-op)\n' >&2
fi
exit 0
