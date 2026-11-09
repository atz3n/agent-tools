#!/usr/bin/env python3
"""extract-test-runs.py <log>

Diagnose WHY a test re-run failed, using only `tool_execution_end` events
from a pi JSON-mode log — never the final assistant text, which habitually
quotes earlier failed runs from the child's fix loop.

Prints one line per test-run result found: `<line-number> [matches...]`.
The LAST entries are the runs nearest the end of the step; a run whose text
contains `failed` there means the child ended on red — the orchestrator's
own re-run of the project's test command decides.
"""
import json
import re
import sys

TRIGGER = re.compile(r"\d+ passed")
FINDINGS = re.compile(r"\d+ (?:passed|failed|error)[^\n\"]{0,40}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: extract-test-runs.py <log>", file=sys.stderr)
        return 1

    try:
        f = open(sys.argv[1], errors="replace")
    except OSError as e:
        print(f"cannot read log: {e}", file=sys.stderr)
        return 1

    with f:
        for n, line in enumerate(f):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "tool_execution_end":
                continue
            r = e.get("result")
            t = r if isinstance(r, str) else json.dumps(r)
            if TRIGGER.search(t):
                print(n, FINDINGS.findall(t))
    return 0


if __name__ == "__main__":
    sys.exit(main())
