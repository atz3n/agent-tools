#!/usr/bin/env python3
"""launch-step.py <id> <step> <n> <prompt-file> [extra pi flags...]

Launches one pipeline step as a fresh, DETACHED pi session with a durable
completion sentinel. Guarantees, identically, on every run:
  - the prompt is read from a file (never re-escaped through a shell variable)
  - the session runs in its own session (start_new_session == setsid), so it
    outlives the tool call that started it (harness timeout, killed process
    group, interrupted orchestrator)
  - the REAL exit code is written to /tmp/autopilot-<id>-<step>-<n>.rc when
    the session ends — the only durable record once the launcher exits
  - `--mode json` streams events to the log from the start (text mode writes
    nothing until the session finishes, so `tail` would show 0 bytes)

Run it from the project root — the detached session inherits this cwd.
Extra flags after <prompt-file> (e.g. --model <pattern> --tools ...) are
passed through to `pi`. The launcher PID is the supervisor, not pi itself.
Poll with step-status.py; never use `kill -0` (zombie PIDs lie in containers).
"""
import os
import subprocess
import sys

USAGE = "usage: launch-step.py <id> <step> <n> <prompt-file> [pi flags...]"


def supervise(log: str, rc: str, prompt_file: str, extra: list) -> None:
    """Child side: run pi to completion, then stamp the exit code into .rc."""
    with open(prompt_file, errors="replace") as f:
        prompt = f.read()
    with open(log, "wb") as out:
        try:
            p = subprocess.run(
                ["pi", "-p", "--approve", "--mode", "json", prompt, *extra],
                stdout=out,
                stderr=subprocess.STDOUT,
            )
            code = p.returncode
        except OSError:
            code = 127  # pi not on PATH — record it, don't leave a vanished process
    with open(rc, "w") as f:
        print(code, file=f)


def main() -> int:
    args = sys.argv[1:]

    # Internal detached mode: launch-step.py --supervise <log> <rc> <prompt-file> -- [pi flags...]
    if args and args[0] == "--supervise":
        log, rc, prompt_file = args[1:4]
        extra = args[5:] if args[4] == "--" else []
        supervise(log, rc, prompt_file, extra)
        return 0

    if len(args) < 4:
        print(USAGE, file=sys.stderr)
        return 1

    id_, step, n, prompt_file = args[:4]
    extra = args[4:]
    prompt_file = os.path.abspath(prompt_file)
    try:
        if os.path.getsize(prompt_file) == 0:
            raise OSError("empty file")
    except OSError:
        print(f"missing or empty prompt file: {prompt_file}", file=sys.stderr)
        return 1

    log = f"/tmp/autopilot-{id_}-{step}-{n}.log"
    rc = f"/tmp/autopilot-{id_}-{step}-{n}.rc"
    try:
        os.remove(rc)
    except FileNotFoundError:
        pass

    subprocess.Popen(
        [
            sys.executable, os.path.abspath(__file__),
            "--supervise", log, rc, prompt_file, "--", *extra,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    print(f"LAUNCHED id={id_} step={step} n={n} log={log} rc={rc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
