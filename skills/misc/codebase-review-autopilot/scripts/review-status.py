#!/usr/bin/env python3
"""review-status.py <review.md>

One-call verdict for the review -> fix -> review loop. Parses the tracker
and prints:

  overall: OPEN | CLOSED | MISSING
  passes: N
  open: N
  open-items:
    - <id> [<section>] <title>

The tracker file is the source of truth — never judge a round by session
prose. A finding's current state is its `### <id>. <Title> — <STATUS>`
line; passes flip statuses in place and a reopened id may appear again in
a later pass, so the LAST occurrence of an id wins. Section is the nearest
preceding `## ` heading (Bugs / Improvements / New findings) — Bug-class
sections decide the relaxed closing rule, so the section is reported.

Exit code: 0 when the file exists and parsed, 2 when the file is missing
(no review.md yet — the loop starts at pass 1), 1 on unusable arguments.
"""
import os
import re
import sys

FINDING = re.compile(
    r"^### (\d+(?:\.\d+)?)\.?\s+(.*?)\s+(?:\u2014|--)\s*(OPEN|DONE)\b.*$"
)
OVERALL = re.compile(r"Overall status:\s*(OPEN|CLOSED)")
PASS = re.compile(r"^#\s+Pass\s+(\d+)\b")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: review-status.py <review.md>", file=sys.stderr)
        return 1

    path = sys.argv[1]
    if not os.path.exists(path):
        print(f"overall: MISSING ({path} does not exist)")
        print("passes: 0")
        print("open: 0")
        print("open-items:")
        return 2

    try:
        lines = open(path, errors="replace").readlines()
    except OSError as e:
        print(f"cannot read tracker: {e}", file=sys.stderr)
        return 1

    overall = None
    passes = 0
    section = "?"
    findings: dict[str, tuple[str, str, str]] = {}

    for line in lines:
        m = OVERALL.search(line)
        if m:
            overall = m.group(1)  # last occurrence wins
            continue
        if PASS.match(line):
            passes += 1
            continue
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        m = FINDING.match(line)
        if m:
            fid, title, status = m.groups()
            findings[fid] = (section, title.strip(), status)

    def sort_key(fid: str) -> tuple:
        parts = fid.split(".")
        return tuple(int(p) if p.isdigit() else 0 for p in parts)

    open_items = {k: v for k, v in findings.items() if v[2] == "OPEN"}

    print(f"overall: {overall or 'NOT FOUND'}")
    print(f"passes: {passes}")
    print(f"open: {len(open_items)}")
    print("open-items:")
    for fid in sorted(open_items, key=sort_key):
        section, title, _ = open_items[fid]
        print(f"  - {fid} [{section}] {title}")
    if overall is None:
        print("warning: no 'Overall status:' line in header", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
