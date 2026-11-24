#!/usr/bin/env python3
"""extract-final.py <log>

Print the final assistant text out of a pi JSON-mode log (no jq needed),
plus the terminal agent_settled `aborted` flag on stderr. The log is the
source of truth — never judge a step by its last 30 lines, and remember
child logs habitually end in a cheerful handoff paragraph: confirm against
the commit and Status line, not the prose.
"""
import json
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: extract-final.py <log>", file=sys.stderr)
        return 1

    path = sys.argv[1]
    try:
        lines = open(path, errors="replace").readlines()
    except OSError as e:
        print(f"cannot read log: {e}", file=sys.stderr)
        return 1

    found = False
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") == "agent_end" and e.get("messages"):
            for b in e["messages"][-1].get("content", []):
                if b.get("type") == "text":
                    print(b.get("text", ""))
                    found = True

    if not found:
        print("(no agent_end text found)", file=sys.stderr)

    # agent_settled: expect "aborted":false
    tail = lines[-1] if lines else ""
    flag = re.search(r'"aborted":[a-z]*', tail)
    print(flag.group(0) if flag else '"aborted":<not found in last line>', file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
