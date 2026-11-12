#!/usr/bin/env python3
"""
handoff-validate.py — schema + SHA-256 for the durable handoff (P0, #6).

The explainer's failure mode #6 is context rot: a free-form handoff drifts and
nobody can tell whether it is current. This validates the newest
docs/HANDOFF-<date>.md against docs/handoff.schema.json and records a SHA-256 in
data/observability/handoff.json. `hardening-gate`/`closeout` require the stored
hash to match the file (a stale handoff is a FAIL).

  python3 scripts/handoff-validate.py --write
  python3 scripts/handoff-validate.py --check
  python3 scripts/handoff-validate.py --self-test
Exit: 0 PASS, 2 FAIL, 4 usage.
Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf, no subprocess.run.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def repo_root() -> Path:
    c = HERE
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return HERE.parent


ROOT = Path(os.environ.get("HANDOFF_REPO") or repo_root())
SCHEMA = ROOT / "docs" / "handoff.schema.json"
OUT = Path(os.environ.get("HANDOFF_OUT") or (ROOT / "data" / "observability" / "handoff.json"))


def utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def schema() -> dict:
    try:
        return json.loads(SCHEMA.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"file_glob": "docs/HANDOFF-*.md", "required_sections": []}


def newest() -> Path | None:
    files = sorted(ROOT.glob(schema().get("file_glob") or "docs/HANDOFF-*.md"))
    today = datetime.date.today()
    for f in reversed(files):
        m = re.search(r"(\d{4}-\d{2}-\d{2})", f.name)
        if not m:
            continue
        try:
            d = datetime.date.fromisoformat(m.group(1))
        except ValueError:
            continue
        if d > today:
            raise ValueError("future-dated handoff: %s" % f.name)
        return f
    return None


def sha(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def validate(path: Path) -> list:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = [ln.strip() for ln in text.splitlines()]
    return [s for s in (schema().get("required_sections") or []) if not any(ln.startswith(s) for ln in lines)]


def cmd_write() -> int:
    try:
        p = newest()
    except ValueError as e:
        print("handoff-validate: %s" % e)
        return 2
    if not p:
        print("handoff-validate: no docs/HANDOFF-*.md")
        return 2
    missing = validate(p)
    if missing:
        print("handoff-validate: missing sections: %s" % ", ".join(missing))
        return 2
    OUT.parent.mkdir(parents=True, exist_ok=True)
    glob = schema().get("file_glob") or "docs/HANDOFF-*.md"
    files = sorted(ROOT.glob(glob))
    doc = {"files": {str(f.relative_to(ROOT)): sha(f) for f in files},
           "newest": str(p.relative_to(ROOT)), "ts": utcnow(),
           "sections": schema().get("required_sections") or []}
    tmp = OUT.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, OUT)
    print("handoff-validate: wrote %s (%s)" % (OUT, doc["newest"]))
    return 0


def cmd_check() -> int:
    try:
        p = newest()
    except ValueError as e:
        print("handoff-validate: FAIL %s" % e)
        return 2
    if not p:
        print("handoff-validate: FAIL no docs/HANDOFF-*.md")
        return 2
    missing = validate(p)
    if missing:
        print("handoff-validate: FAIL missing sections: %s" % ", ".join(missing))
        return 2
    try:
        d = json.loads(OUT.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("handoff-validate: FAIL no record; run --write")
        return 2
    files = d.get("files") or {}
    if not isinstance(files, dict) or not files:
        print("handoff-validate: FAIL old record format; run --write")
        return 2
    changed = []
    for name, want in files.items():
        fp = ROOT / name
        if not fp.is_file() or sha(fp) != want:
            changed.append(name)
    newest_name = str(p.relative_to(ROOT))
    if d.get("newest") != newest_name or newest_name in changed:
        print("handoff-validate: FAIL newest %s changed or not recorded" % newest_name)
        return 2
    if changed:
        print("handoff-validate: FAIL changed since write: %s" % ", ".join(sorted(changed)))
        return 2
    print("handoff-validate: PASS %s (%d file(s))" % (newest_name, len(files)))
    return 0


def self_test() -> int:
    import tempfile
    w = Path(tempfile.mkdtemp())
    (w / "docs").mkdir()
    (w / "data" / "observability").mkdir(parents=True)
    (w / "opencode.json").write_text("{}")
    (w / "docker").mkdir()
    (w / "docker" / "Dockerfile").write_text("FROM scratch\n")
    (w / "docs" / "handoff.schema.json").write_text(
        json.dumps({"file_glob": "docs/HANDOFF-*.md",
                    "required_sections": ["## TL;DR", "## Next unit"]}))
    good = w / "docs" / "HANDOFF-2026-01-01.md"
    good.write_text("# Handoff\n\n## TL;DR\nx\n\n## Next unit\ny\n")
    bad = w / "docs" / "HANDOFF-2026-01-02.md"
    bad.write_text("# Handoff\n\n## TL;DR\nx\n")
    os.environ["HANDOFF_REPO"] = str(w)
    os.environ["HANDOFF_OUT"] = str(w / "data" / "observability" / "handoff.json")
    try:
        global ROOT, SCHEMA, OUT
        ROOT, SCHEMA, OUT = w, w / "docs" / "handoff.schema.json", Path(os.environ["HANDOFF_OUT"])
        if validate(good):
            print("handoff-validate: self-test FAIL good")
            return 1
        if not validate(bad):
            print("handoff-validate: self-test FAIL bad")
            return 1
        bad.write_text("# Handoff\n\n## TL;DR\nx\n\n## Next unit\ny\n")
        if cmd_write() != 0 or cmd_check() != 0:
            print("handoff-validate: self-test FAIL write/check")
            return 1
        print("handoff-validate: self-test PASS (schema, write, hash)")
        return 0
    finally:
        import shutil
        shutil.rmtree(w, ignore_errors=True)
        os.environ.pop("HANDOFF_REPO", None)
        os.environ.pop("HANDOFF_OUT", None)


def main() -> int:
    ap = argparse.ArgumentParser(description="Handoff schema + SHA-256")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.check:
        return cmd_check()
    return cmd_write()


if __name__ == "__main__":
    sys.exit(main())
