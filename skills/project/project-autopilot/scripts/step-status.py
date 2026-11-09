#!/usr/bin/env python3
"""step-status.py <id> <step> <n>

One-call poll for a launched step: sentinel + progress counters.
Tests the .rc sentinel, NEVER `kill -0`: in a container the launcher exits
immediately, the finished pi is reparented to a PID 1 that does not reap it,
and it stays `[pi] <defunct>` forever — `kill -0` on a zombie SUCCEEDS, so
every completed step would look like it is still running.

Output:
  DONE rc=<n>                  → step finished; read the rc value
  "aborted":<true|false>       → terminal agent_settled flag, checked for you
  RUNNING tool_calls=<n> log_lines=<n> → still working (rising counters = progressing)
"""
import os
import re
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: step-status.py <id> <step> <n>", file=sys.stderr)
        return 1

    id_, step, n = sys.argv[1:4]
    log = f"/tmp/autopilot-{id_}-{step}-{n}.log"
    rc = f"/tmp/autopilot-{id_}-{step}-{n}.rc"

    if os.path.exists(rc):
        with open(rc, errors="replace") as f:
            code = f.read().strip()
        print(f"DONE rc={code}")
        tail = ""
        try:
            for line in open(log, errors="replace"):
                if line.strip():
                    tail = line
        except OSError:
            pass
        m = re.search(r'"aborted":[a-z]*', tail)
        print(m.group(0) if m else '"aborted":<not found in last line>')
    else:
        calls = lines = 0
        try:
            for line in open(log, errors="replace"):
                if line.strip():
                    lines += 1
                if '"type":"tool_execution_end"' in line:
                    calls += 1
        except OSError:
            pass
        print(f"RUNNING tool_calls={calls} log_lines={lines}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
