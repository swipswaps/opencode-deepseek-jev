#!/usr/bin/env bash
#
# ocr-image.sh — extract text from a screenshot/scan using a LOCAL OCR
# engine, so the system can read images even when every API model fails.
# Each result is persisted to data/observability/observability.db (ocr_run)
# so the dashboard can surface and search it.
#
# Engines, in order of preference:
#   1. tesseract CLI        (apt: tesseract-ocr)  — in the Docker image
#   2. tesseract.js (node)  (npm: tesseract.js)    — receipts-ocr browser engine
#   3. PaddleOCR            (pip: paddleocr)        — receipts-ocr backend engine
#
# Usage:
#   ./scripts/ocr-image.sh <image.png|jpg|...> [lang]     # print text, persist
#   ./scripts/ocr-image.sh --check                         # report available engines
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }
have_tjs() { node -e "require.resolve('tesseract.js')" >/dev/null 2>&1; }
have_paddle() { python3 -c 'import paddleocr' >/dev/null 2>&1; }

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

usage() { printf 'usage: %s <image> [lang] | %s --check\n' "$0" "$0"; }

persist_ocr() {
    local img="$1" engine="$2" lang="$3" text="$4" obs="$5"
    python3 - "$obs" "$img" "$engine" "$lang" "$text" <<'PY'
import sqlite3, sys, hashlib, datetime
obs, img, engine, lang, text = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
if not text.strip():
    sys.exit(0)
sha = hashlib.sha256(open(img, "rb").read()).hexdigest()[:16]
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
con = sqlite3.connect(obs)
con.execute("CREATE TABLE IF NOT EXISTS ocr_run(id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, image TEXT, sha TEXT, engine TEXT, lang TEXT, text TEXT)")
con.execute("INSERT INTO ocr_run(ts,image,sha,engine,lang,text) VALUES(?,?,?,?,?,?)", (ts, img, sha, engine, lang, text))
con.commit(); con.close()
PY
}

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")

    case "${1:-}" in
        --check)
            local avail=0
            have tesseract && { printf 'tesseract (cli): available\n'; avail=1; }
            have_tjs && { printf 'tesseract.js (node): available\n'; avail=1; }
            have_paddle && { printf 'paddleocr (pip): available\n'; avail=1; }
            if [ "$avail" -eq 0 ]; then
                printf 'no OCR engine available. Install one:\n'
                printf '  apt-get install -y tesseract-ocr          (in Dockerfile)\n'
                printf '  npm install tesseract.js                  (runs in node, no apt)\n'
                printf '  pip install paddleocr paddlepaddle        (receipts-ocr backend)\n'
                return 1
            fi
            return 0
            ;;
        "")
            usage; return 2
            ;;
    esac

    local img="${1:-}" lang="${2:-eng}"
    if [ ! -f "$img" ]; then
        printf 'FAIL: no such image: %s\n' "$img"
        return 1
    fi

    local text="" engine=""
    local rc=0

    if have tesseract; then
        engine='tesseract'
        text=$(tesseract "$img" stdout -l "$lang")
        rc=$?
    elif have_tjs; then
        engine='tesseract.js'
        text=$(node "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ocr-tesseractjs.mjs" "$img" "$lang")
        rc=$?
    elif have_paddle; then
        engine='paddleocr'
        text=$(python3 - "$img" "$lang" <<'PY'
import sys
from paddleocr import PaddleOCR
img, lang = sys.argv[1], sys.argv[2]
ocr = PaddleOCR(lang=lang, use_doc_orientation_classify=False, use_doc_unwarping=False, use_textline_orientation=False)
result = ocr.ocr(img, cls=False)
for page in result or []:
    for line in page or []:
        print(line[1][0])
PY
)
        rc=$?
    else
        printf 'FAIL: no OCR engine available.\n'
        printf '  apt-get install -y tesseract-ocr\n'
        printf '  npm install tesseract.js\n'
        printf '  pip install paddleocr paddlepaddle\n'
        return 1
    fi

    printf '%s\n' "$text"
    if [ "$rc" -eq 0 ] && [ -n "$REPO" ] && [ -n "$text" ]; then
        persist_ocr "$img" "$engine" "$lang" "$text" "$REPO/data/observability/observability.db"
    fi
    return "$rc"
}

main "$@"
