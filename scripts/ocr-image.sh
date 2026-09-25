#!/usr/bin/env bash
#
# ocr-image.sh — extract text from a screenshot/scan using a LOCAL OCR
# engine, so the system can read images even when every API model fails.
#
# Engines, in order of preference:
#   1. tesseract CLI  (apt: tesseract-ocr)         — lightweight, terminal/UI text
#   2. PaddleOCR      (pip: paddleocr)             — receipts-ocr backend style
#
# The receipts-ocr project (github.com/swipswaps/receipts-ocr) runs
# tesseract.js in the browser and PaddleOCR in backend/app.py; this script
# reuses the same engines as a local CLI fallback.
#
# Usage:
#   ./scripts/ocr-image.sh <image.png|jpg|...> [lang]     # print text to stdout
#   ./scripts/ocr-image.sh --check                         # report which engine is available
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

usage() { printf 'usage: %s <image> [lang] | %s --check\n' "$0" "$0"; }

engine_available() {
    if have tesseract; then printf 'tesseract'; return 0; fi
    if python3 -c 'import paddleocr' >/dev/null 2>&1; then printf 'paddleocr'; return 0; fi
    printf ''; return 1
}

main() {
    case "${1:-}" in
        --check)
            local e
            e=$(engine_available)
            if [ -n "$e" ]; then
                printf 'OCR engine available: %s\n' "$e"
                return 0
            fi
            printf 'OCR engine: NONE\n'
            printf 'install one of:\n'
            printf '  apt-get install -y tesseract-ocr\n'
            printf '  pip install paddleocr paddlepaddle\n'
            return 1
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

    if have tesseract; then
        tesseract "$img" stdout -l "$lang"
        return $?
    fi

    if python3 -c 'import paddleocr' >/dev/null 2>&1; then
        python3 - "$img" "$lang" <<'PY'
import sys
from paddleocr import PaddleOCR
img, lang = sys.argv[1], sys.argv[2]
try:
    ocr = PaddleOCR(lang=lang, use_doc_orientation_classify=False, use_doc_unwarping=False, use_textline_orientation=False)
    result = ocr.ocr(img, cls=False)
    for page in result or []:
        for line in page or []:
            print(line[1][0])
except Exception as e:
    print("PaddleOCR failed: %s" % e, file=sys.stderr)
    sys.exit(1)
PY
        return $?
    fi

    printf 'FAIL: no OCR engine available. Install tesseract-ocr or paddleocr.\n'
    printf '  apt-get install -y tesseract-ocr\n'
    printf '  pip install paddleocr paddlepaddle\n'
    return 1
}

main "$@"
