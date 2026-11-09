#!/usr/bin/env python3
"""latest-qa-run.py <spec-file>

Print the NEWEST (last) `### QA Run` block of a feature spec — don't guess
the block number. The project-qa skill appends one block per run; the
implement<->qa loop verdict depends ONLY on the latest block: any bug whose
Status is not `Fixed (Run N)` and not `Deferred (user decision…)` (any
when/where/date suffix) is open. Reading an older block misjudges the open
bugs and burns fix rounds.
"""
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: latest-qa-run.py <spec-file>", file=sys.stderr)
        return 1

    path = sys.argv[1]
    try:
        with open(path, errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        print(f"spec file not readable: {path} ({e})", file=sys.stderr)
        return 1

    starts = [i for i, l in enumerate(lines) if l.startswith("### QA Run")]
    if not starts:
        print(f"no '### QA Run' blocks in {path} — the qa step has not run", file=sys.stderr)
        return 1

    sys.stdout.writelines(lines[starts[-1]:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
