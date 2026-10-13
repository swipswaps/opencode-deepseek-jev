#!/usr/bin/env bash
#
# state-snapshot.sh — snapshot and restore the state you cannot regenerate.
#
# The recoverability plane that deploy.sh does not cover: deploy.sh makes
# *promotion* safe; this makes *loss* safe. The irreplaceable state is small
# and specific — the API keys and server password (.env.local), the TLS
# certs, and the compose/Caddy/config that ties them together. The session
# store (opencode.db) is large and opencode can run without it, so it is
# opt-in (--with-db) and copied consistently, never raw.
#
# Every snapshot carries a manifest.json with sha256 + mode + size per file,
# so a restore is verified, not hoped. Restore is itself reversible: it takes
# a pre-restore snapshot first. Secrets are never printed (by name/size only);
# snapshot dirs are 0700 and secret files 0600.
#
#   ./scripts/state-snapshot.sh snapshot [--with-db] [--keep N] [--json]
#   ./scripts/state-snapshot.sh list
#   ./scripts/state-snapshot.sh verify <snap|--latest>
#   ./scripts/state-snapshot.sh restore <snap|--latest> [--dry-run] [--allow-db-restore]
#   ./scripts/state-snapshot.sh --self-test        # offline fixture
#
# Env seams: SNAP_ROOT (default data/observability/snapshots), SNAP_REPO
# (default: resolved repo). Snapshot root is under gitignored data/.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -o pipefail

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# The irreplaceable set (repo-relative). DB files are handled separately.
state_files() {
    printf '%s\n' \
        .env.local \
        opencode.json \
        models.policy.json \
        docker/docker-compose.yml \
        docker/docker-compose.override.yml \
        docker/Caddyfile \
        docker/web-entrypoint.sh \
        docker/litellm.config.yaml \
        docker/certs/opencode.crt \
        docker/certs/opencode.key \
        docker/certs/ca.crt
}

db_files() {
    printf '%s\n' \
        data/observability/observability.db
}

py_backup_db() {
    # py_backup_db SRC DST — consistent copy via the sqlite backup API,
    # source opened read-only so a live writer is never disturbed.
    python3 - "$1" "$2" << 'PYEOF'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect("file:" + src + "?mode=ro", uri=True)
d = sqlite3.connect(dst)
s.backup(d)
d.close()
s.close()
PYEOF
}

manifest_write() {
    # manifest_write SNAPDIR REV TS — hash every copied file into manifest.json.
    python3 - "$1" "$2" "$3" << 'PYEOF'
import hashlib, json, os, sys
snap, rev, ts = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.path.join(snap, "files")
files = []
for dirpath, _dirs, names in os.walk(root):
    for n in names:
        p = os.path.join(dirpath, n)
        rel = os.path.relpath(p, root)
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        st = os.stat(p)
        files.append({"path": rel, "sha256": h.hexdigest(),
                      "bytes": st.st_size, "mode": oct(st.st_mode & 0o777)})
files.sort(key=lambda x: x["path"])
total = sum(f["bytes"] for f in files)
json.dump({"ts": ts, "rev": rev, "files": files, "total_bytes": total},
          open(os.path.join(snap, "manifest.json"), "w"), indent=1)
print("%d files %d bytes" % (len(files), total))
PYEOF
}

dir_mode() { chmod 700 "$1" 2>&1 || true; }

do_snapshot() {
    # do_snapshot DIR WITHDB — copy state into DIR/files (already created).
    local dest="$1" withdb="$2" rel src dst
    mkdir -p "$dest/files"
    dir_mode "$dest"
    while IFS= read -r rel; do
        src="$REPO/$rel"
        [ -f "$src" ] || continue
        dst="$dest/files/$rel"
        mkdir -p "$(dirname "$dst")"
        cp -p "$src" "$dst"
        case "$rel" in
            .env.local | *.key) chmod 600 "$dst" ;;
        esac
    done < <(state_files)
    while IFS= read -r rel; do
        src="$REPO/$rel"
        [ -f "$src" ] || continue
        dst="$dest/files/$rel"
        mkdir -p "$(dirname "$dst")"
        py_backup_db "$src" "$dst" 2>&1 || printf 'WARN: db copy failed for %s\n' "$rel"
    done < <(db_files)
    if [ "$withdb" -eq 1 ] && [ -f "$REPO/data/opencode/opencode.db" ]; then
        dst="$dest/files/data/opencode/opencode.db"
        mkdir -p "$(dirname "$dst")"
        printf 'copying opencode.db (may take a moment)...\n'
        py_backup_db "$REPO/data/opencode/opencode.db" "$dst" 2>&1 || printf 'WARN: opencode.db copy failed\n'
    fi
}

manifest_files() {
    # manifest_files SNAPDIR -> "rel<TAB>sha256<TAB>mode" lines.
    python3 - "$1" << 'PYEOF'
import json, sys, os
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
for f in m["files"]:
    print("%s\t%s\t%s" % (f["path"], f["sha256"], f["mode"]))
PYEOF
}

verify_snap() {
    # verify_snap SNAPDIR -> 0 iff every file matches its manifest sha256.
    local dest="$1" fail=0 rel sha mode got
    if [ ! -f "$dest/manifest.json" ]; then
        printf 'FAIL: no manifest in %s\n' "$dest"
        return 1
    fi
    while IFS=$'\t' read -r rel sha mode; do
        got=$(python3 -c 'import hashlib,sys
h=hashlib.sha256()
with open(sys.argv[1],"rb") as f:
    for c in iter(lambda: f.read(65536), b""): h.update(c)
print(h.hexdigest())' "$dest/files/$rel" 2>&1)
        if [ "$got" != "$sha" ]; then
            printf 'FAIL checksum: %s\n' "$rel"
            fail=1
        fi
    done < <(manifest_files "$dest")
    [ "$fail" -eq 0 ] && printf 'verify OK: %s\n' "$dest"
    return "$fail"
}

new_snap_dir() {
    local ts="$1"
    printf '%s/state-%s' "$SNAP_ROOT" "$ts"
}

prune() {
    local keep="$1" n=0 d
    ls -1dt "$SNAP_ROOT"/state-* 2>&1 | while IFS= read -r d; do
        [ -d "$d" ] || continue
        n=$((n + 1))
        if [ "$n" -gt "$keep" ]; then
            printf 'prune %s\n' "$d"
            find "$d" -type f -delete 2>&1 || true
            find "$d" -depth -type d -empty -delete 2>&1 || true
        fi
    done
}

cmd_snapshot() {
    local withdb=0 keep=10
    while [ $# -gt 0 ]; do
        case "$1" in
            --with-db) withdb=1; shift ;;
            --keep) keep="${2:-10}"; shift 2 ;;
            --keep=*) keep="${1#--keep=}"; shift ;;
            --json) JSON=1; shift ;;
            *) printf 'unknown snapshot arg: %s\n' "$1"; return 2 ;;
        esac
    done
    local ts dest rev summary
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    rev=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf unknown)
    mkdir -p "$SNAP_ROOT"
    dest=$(new_snap_dir "$ts")
    mkdir -p "$dest"
    do_snapshot "$dest" "$withdb"
    summary=$(manifest_write "$dest" "$rev" "$ts")
    [ -n "$keep" ] && prune "$keep"
    if [ "$JSON" -eq 1 ]; then
        python3 -c 'import json,sys,os
d=sys.argv[1]; m=json.load(open(os.path.join(d,"manifest.json")))
print(json.dumps({"snapshot":d,"ts":m["ts"],"rev":m["rev"],"files":len(m["files"]),"bytes":m["total_bytes"]}))' "$dest"
    else
        printf 'snapshot: %s\n  %s (rev %s)\n' "$dest" "$summary" "$rev"
        printf '  note: contains secrets (.env.local, *.key) at 0600 under %s\n' "$(basename "$dest")"
    fi
    return 0
}

resolve_snap() {
    # resolve_snap ARG -> path (ARG may be --latest, an id, or a path).
    local arg="$1" d
    if [ "$arg" = "--latest" ] || [ -z "$arg" ]; then
        d=$(ls -1dt "$SNAP_ROOT"/state-* 2>&1 | head -n 1)
        [ -n "$d" ] || { printf 'FAIL: no snapshots in %s\n' "$SNAP_ROOT"; return 1; }
        printf '%s' "$d"
        return 0
    fi
    if [ -d "$arg" ]; then printf '%s' "$arg"; return 0; fi
    if [ -d "$SNAP_ROOT/state-$arg" ]; then printf '%s' "$SNAP_ROOT/state-$arg"; return 0; fi
    if [ -d "$SNAP_ROOT/$arg" ]; then printf '%s' "$SNAP_ROOT/$arg"; return 0; fi
    printf 'FAIL: no such snapshot: %s\n' "$arg"
    return 1
}

cmd_verify() {
    local dest
    dest=$(resolve_snap "${1:-}") || return 1
    verify_snap "$dest"
}

cmd_list() {
    local d m
    ls -1dt "$SNAP_ROOT"/state-* 2>&1 | while IFS= read -r d; do
        [ -d "$d" ] || continue
        m=$(python3 -c 'import json,sys
try:
    j=json.load(open(sys.argv[1]))
    print("%s rev=%s files=%d bytes=%d" % (j["ts"], j["rev"], len(j["files"]), j["total_bytes"]))
except Exception:
    print("(no manifest)")' "$d/manifest.json" 2>&1)
        printf '%s  %s\n' "$(basename "$d")" "$m"
    done
}

cmd_restore() {
    local arg="" dry=0 allowdb=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            --allow-db-restore) allowdb=1; shift ;;
            --latest) arg="--latest"; shift ;;
            -*) printf 'unknown restore arg: %s\n' "$1"; return 2 ;;
            *) arg="$1"; shift ;;
        esac
    done
    local dest
    dest=$(resolve_snap "$arg") || return 1
    verify_snap "$dest" || { printf 'refusing restore: snapshot fails its own checksums\n'; return 1; }
    local rel src mode sha
    if [ "$dry" -eq 1 ]; then
        printf 'DRY RUN: would restore these over %s:\n' "$REPO"
        while IFS=$'\t' read -r rel sha mode; do
            case "$rel" in
                data/opencode/opencode.db) printf '  %s (only with --allow-db-restore)\n' "$rel" ;;
                *) printf '  %s\n' "$rel" ;;
            esac
        done < <(manifest_files "$dest")
        return 0
    fi
    # Reversibility: snapshot current state before overwriting it.
    cmd_snapshot > /dev/null 2>&1 || printf 'WARN: pre-restore snapshot failed\n'
    while IFS=$'\t' read -r rel sha mode; do
        case "$rel" in
            data/opencode/opencode.db)
                if [ "$allowdb" -eq 1 ]; then
                    printf 'restore %s (ensure opencode-web is stopped first)\n' "$rel"
                    mkdir -p "$(dirname "$REPO/$rel")"
                    cp -p "$dest/files/$rel" "$REPO/$rel"
                else
                    printf 'skip %s (pass --allow-db-restore, container stopped)\n' "$rel"
                fi
                continue
                ;;
        esac
        src="$dest/files/$rel"
        [ -f "$src" ] || continue
        mkdir -p "$(dirname "$REPO/$rel")"
        cp -p "$src" "$REPO/$rel"
        chmod "${mode#0o}" "$REPO/$rel" 2>&1 || true
        printf 'restored %s\n' "$rel"
    done < <(manifest_files "$dest")
    printf 'done. next: ./scripts/web-restart.sh  (recreate to pick up env/certs)\n'
    return 0
}

self_test() {
    local fail=0 work=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    mkdir -p "$work/repo/docker/certs" "$work/repo/data/observability" "$work/snap"
    printf 'opencode.json\n' > "$work/repo/opencode.json"
    printf 'DEEPSEEK_API_KEY=sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaa\nPASSWORD=secretvalue123\n' > "$work/repo/.env.local"
    chmod 600 "$work/repo/.env.local"
    printf 'cert\n' > "$work/repo/docker/certs/opencode.crt"
    printf 'key\n' > "$work/repo/docker/certs/opencode.key"
    python3 - "$work/repo/data/observability/observability.db" << 'PYEOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE t(x)"); c.execute("INSERT INTO t VALUES(1)"); c.commit(); c.close()
PYEOF
    export SNAP_REPO="$work/repo"
    local out=""
    out=$(SNAP_ROOT="$work/snap" bash "${BASH_SOURCE[0]}" snapshot 2>&1)
    printf '%s' "$out" | grep -q 'snapshot:' || { printf 'FAIL snapshot run\n'; fail=1; }
    local snap
    snap=$(ls -1d "$work/snap"/state-* 2>&1 | head -n 1)
    [ -d "$snap" ] || { printf 'FAIL snapshot dir\n'; fail=1; }
    [ -f "$snap/manifest.json" ] || { printf 'FAIL manifest\n'; fail=1; }
    [ "$(stat -c %a "$snap/files/.env.local")" = "600" ] || { printf 'FAIL env mode in snapshot\n'; fail=1; }
    SNAP_ROOT="$work/snap" bash "${BASH_SOURCE[0]}" verify --latest > /dev/null 2>&1 \
        || { printf 'FAIL verify clean\n'; fail=1; }
    # Tamper a snapshot file: verify must catch it.
    printf 'tampered\n' >> "$snap/files/opencode.json"
    SNAP_ROOT="$work/snap" bash "${BASH_SOURCE[0]}" verify --latest > /dev/null 2>&1 \
        && { printf 'FAIL verify missed tamper\n'; fail=1; }
    printf 'opencode.json\n' > "$snap/files/opencode.json"
    # Mutate live state, then restore, then assert restored + mode 600 + pre-snap.
    printf 'CORRUPT\n' > "$work/repo/opencode.json"
    printf 'CORRUPTKEY\n' > "$work/repo/docker/certs/opencode.key"
    SNAP_ROOT="$work/snap" bash "${BASH_SOURCE[0]}" restore "$snap" > /dev/null 2>&1 \
        || { printf 'FAIL restore run\n'; fail=1; }
    [ "$(cat "$work/repo/opencode.json")" = "opencode.json" ] || { printf 'FAIL config restored\n'; fail=1; }
    [ "$(cat "$work/repo/docker/certs/opencode.key")" = "key" ] || { printf 'FAIL key restored\n'; fail=1; }
    [ "$(stat -c %a "$work/repo/.env.local")" = "600" ] || { printf 'FAIL env mode after restore\n'; fail=1; }
    local nsnap
    nsnap=$(ls -1d "$work/snap"/state-* 2>&1 | wc -l | tr -d ' ')
    [ "$nsnap" -ge 2 ] && fail=$fail || { printf 'FAIL pre-restore snapshot missing\n'; fail=1; }
    out=$(SNAP_ROOT="$work/snap" bash "${BASH_SOURCE[0]}" list 2>&1)
    printf '%s' "$out" | grep -q 'rev=' || { printf 'FAIL list\n'; fail=1; }
    out=$(SNAP_ROOT="$work/snap" bash "${BASH_SOURCE[0]}" restore --latest --dry-run 2>&1)
    printf '%s' "$out" | grep -q 'DRY RUN' || { printf 'FAIL dry-run\n'; fail=1; }
    printf '%s' "$out" | grep -q 'sk-aaaaaaaaaaaa' && { printf 'FAIL dry-run leaked secret\n'; fail=1; }
    rm -f "$work/repo/.env.local" "$work/repo/opencode.json" "$work/repo/docker/certs/opencode.crt" "$work/repo/docker/certs/opencode.key" "$work/repo/data/observability/observability.db"
    find "$work/snap" -type f -delete 2>&1 || true
    find "$work/snap" -depth -type d -empty -delete 2>&1 || true
    find "$work/repo" -type f -delete 2>&1 || true
    find "$work/repo" -depth -type d -empty -delete 2>&1 || true
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'state-snapshot: self-test PASS\n'; else printf 'state-snapshot: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO="${SNAP_REPO:-}"
    if [ -z "$REPO" ]; then
        REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
        [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    fi
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    SNAP_ROOT="${SNAP_ROOT:-$REPO/data/observability/snapshots}"
    JSON=0
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        snapshot) cmd_snapshot "$@" ;;
        list) cmd_list ;;
        verify) cmd_verify "$@" ;;
        restore) cmd_restore "$@" ;;
        --self-test | self-test) self_test ;;
        "" | -h | --help)
            printf 'usage: %s {snapshot|list|verify|restore} ... [--self-test]\n' "$0"
            printf '  snapshot [--with-db] [--keep N] [--json]\n'
            printf '  list\n  verify <snap|--latest>\n'
            printf '  restore <snap|--latest> [--dry-run] [--allow-db-restore]\n'
            return 0 ;;
        *) printf 'unknown command: %s\n' "$cmd"; return 2 ;;
    esac
}

main "$@"
