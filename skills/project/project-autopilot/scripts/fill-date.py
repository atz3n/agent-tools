#!/usr/bin/env python3
"""fill-date.py <prompt-file> <branch>

Substitutes the literal tokens AUTOPILOT_DATE and <branch> in a finished
prompt file with the real clock (ISO date — the same computation the child
runs on the same host, so the stamp matches dates the child computes itself)
and the run's branch name, then ASSERTS the canonical deferral stamp line is
present before the step may be launched. The date is never typed from memory
or guessed: a wrong date silently desyncs the deferral records from the QA
Run blocks and Last Updated date, and poisons every later
`Deferred (… <date>)` parse.

Run this AFTER writing the prompt (file-writing tool or quoted heredoc) and
BEFORE launch-step.py. The file is only rewritten when the assert passes.
"""
import datetime
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fill-date.py <prompt-file> <branch>", file=sys.stderr)
        return 1

    prompt_file, branch = sys.argv[1:3]
    try:
        with open(prompt_file, errors="replace") as f:
            text = f.read()
    except OSError as e:
        print(f"cannot read prompt file: {e}", file=sys.stderr)
        return 1
    if not text.strip():
        print(f"empty prompt file: {prompt_file}", file=sys.stderr)
        return 1

    today = datetime.date.today().isoformat()  # == `date +%F`
    text = text.replace("AUTOPILOT_DATE", today).replace("<branch>", branch)

    expected = f"autopilot run {branch}, {today}"
    if expected not in text:
        print(
            f"date stamp missing/wrong in {prompt_file} (expected '{expected}')",
            file=sys.stderr,
        )
        return 1

    with open(prompt_file, "w") as f:
        f.write(text)
    print(f"OK date={today} branch={branch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
