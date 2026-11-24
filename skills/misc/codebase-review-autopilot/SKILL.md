---
disable-model-invocation: true
name: codebase-review-autopilot
description: Autonomously drive the codebase-review find → fix → verify loop — launches a fresh pi session for every review pass and a fresh session for every fix round, repeating until review.md's Overall status is CLOSED or a stop condition hits. Pre-flight verifies pi/python, the target, and the project test command, then orchestrates and verifies each session without ever asking the user anything. Runs on the current branch and leaves every change UNCOMMITTED in the working tree — no branches, no commits, no pushes; the user reviews and commits. Supports `--dry-run`, `--max-rounds N`, and pass-through `--model`/`--tools`/`--thinking` flags. Use when asked to "autopilot the review", "review and fix automatically", "run review→fix→review until closed", or to drive a review.md to closure unattended. Pass a target folder as argument (defaults to the project root).
---

# Codebase Review Autopilot

## Role
You are the unattended orchestrator of the [codebase-review](../codebase-review/SKILL.md) loop. You never review and never fix anything yourself — every review pass and every fix round runs as a fresh, non-interactive `pi -p` session that runs `/skill:codebase-review`. You launch, verify, and decide. The user is away; nothing may wait on a question.

**No git state changes, ever.** No commits, no branches, no checkouts, no stashes, no resets, no merges, no pushes — not by you and not by the sessions you launch. Everything happens in the working tree on whatever branch the user has checked out, and the work is left there **uncommitted** for them to review and commit. `review.md` is the record of the run; git is not part of it.

**Bundled scripts.** The mechanical launch/poll/extract/status logic lives in `scripts/` next to this file (paths below are relative to this SKILL.md's directory) — plain Python 3 stdlib, run with `python3`. `launch-step.py`, `step-status.py` and `extract-final.py` are the same launchers project-autopilot uses (detached session, `.rc` sentinel, JSON log); `review-status.py` parses the tracker. Always run these scripts instead of re-typing commands — prompt quoting and log reading are where hand-typed runs go wrong. Read the script headers when diagnosing a weird state.

## 1. Parse the argument
- `<target-folder>` → the review target (defaults to the project root when omitted).
- `--dry-run` → run the pre-flight, print the plan (branch, starting pass, open findings, max rounds, GO/NO-GO), then stop without launching a session.
- `--max-rounds N` → cap on fix rounds (default 10). A "round" is one review pass plus, if it leaves findings open, one fix session.
- `--model <pattern>` / `--tools …` / `--thinking …` → carried onto **every** launch.
- Anything unrecognized → do not guess and do not start: report the argument you received, list the valid forms, and stop.

**Session budget:** cap the run at 2 × max-rounds + 1 launched sessions (21 by default) unless the user gave a number. Every launch counts — passes, fixes, retries. At the cap, stop cleanly at the round boundary and report what remains.

Derive `<id>` = a kebab slug of the target's basename (`.` / the repo root → the repo folder name). It names all session files: `/tmp/autopilot-<id>-<step>-<n>.*`.

## 2. Pre-flight — before launching any session
Run all checks, then report one consolidated GO/NO-GO. **Abort with a clear message if anything fails** — do not start a loop you can't finish.

- `pi --version` and `python3 --version` succeed — the orchestrator launches child `pi` sessions and every bundled script is Python; abort rather than discover this at the first launch.
- The target folder exists and contains files. `review.md` inside it may or may not exist — both are fine.
- **Tracker state:** `python3 <skill-dir>/scripts/review-status.py <target>/review.md` → note `overall`, `passes`, `open` and the open-item list. No file (exit 2) = the run starts at pass 1. A tracker whose header has no `Overall status:` line is malformed → abort and name it (a human or `/skill:project-doctor`-style fix, never a silent guess).
- **Test command:** discover the project's own test command once, here (`make test`, `python3 -m unittest`, `npm test`, `go test ./...`, a Docker script…) from `Makefile` / `pyproject.toml` / `package.json` / `go.mod` / README, and reuse it in every fix prompt and every re-run below — never hardcode one. If the target genuinely has no test command, record `none` and say so in the plan.
- **Working-tree state (a notice, not a gate):** `git status --short` and `git rev-parse --abbrev-ref HEAD`. Do **not** require a clean tree — uncommitted work is expected and is exactly what a review pass must read. Record the pre-run baseline (the `git status --short` output + the current branch) for the final report, and state plainly in the plan that fix sessions edit this tree in place and leave their changes uncommitted, so anything precious should be committed or backed up by the user before the run starts. Never "clean" a dirty tree yourself: no `git stash`, no `checkout`, no `reset`, no discarding changes you did not cause.

Print the plan: current branch, target, starting pass number, current open findings, max rounds, session budget, the uncommitted-work notice, GO/NO-GO. Then proceed without waiting.

## 3. The loop
Round k = **one review session**, then — only if the tracker still has open findings — **one fix session**. Steps are `<step>` ∈ {`review`, `fix`}; `<n>` is a global session counter, incremented on every launch including retries. Strictly sequential — never two sessions at once.

**1. Build the prompt as a file, not a shell variable.** The preamble contains apostrophes, quotes and real newlines; re-escaping it through a shell assignment silently corrupts it. Write it with a **quoted** heredoc:

```sh
prompt_file=/tmp/autopilot-<id>-review-<n>.prompt
cat > "$prompt_file" <<'EOF'
You are running UNATTENDED. Never ask the user questions, and never end your turn with a question, a menu of options, or a request for confirmation — there is no human on the other end. Wherever the skill says to ask, pick the skill's own recommendation if it has one, otherwise the most sensible default consistent with the repo, its docs and AGENTS.md, record it in the tracker, and keep going until the skill's checklist is complete. Leave no open questions. Make NO git state changes: do not run git add, commit, stash, checkout, reset, restore, clean, switch, merge, push, or branch, and never discard or revert changes you did not make — the working tree holds the user's own uncommitted work. Leave every change you make in the working tree UNCOMMITTED; the user reviews and commits. If your work changed code, run <test-command> and make it pass before you finish.

/skill:codebase-review <target>
EOF
```

The fix-round prompt replaces the skill line with (still after the verbatim preamble):

```
Fix every finding in <target>/review.md that review-status.py reports as open (run it to get the exact list — do not guess). Follow the codebase-review skill's Fix Mode exactly, including the class-sweep rule: fix every sibling instance or exempt each with a one-line reason in the DONE note. Set each finding to `DONE — <one line: what was changed and where>` and never mark a finding DONE that you did not actually implement and verify against the files. Do NOT run a review pass, do NOT append a new Pass section, do NOT change the Overall status — you only fix and update the affected finding lines. If <test-command> is not `none`, run it and make it pass. Leave all changes uncommitted.
```

**2. Launch detached, with a completion sentinel:**
```sh
cd <project-root>
python3 <skill-dir>/scripts/launch-step.py <id> <step> <n> "$prompt_file" [--model <pattern> --tools …]
```
The session runs detached (`setsid`) so it outlives the tool call that started it; its real exit code lands in `/tmp/autopilot-<id>-<step>-<n>.rc`, its JSON event stream in `.log`. The printed PID is the supervisor, not pi.

**3. Poll with `step-status.py <id> <step> <n>`** — never `kill -0` (zombie PIDs lie in containers). Cadence: 30–60s for the first ~3 minutes (a bad prompt or instant crash shows there), then widen to 4–5 minutes once counters are rising. Do all checking in one call per poll. A review pass that must read the whole target can legitimately run long — trust the sentinel, not the clock.

**4. Verify every session — the tracker is the source of truth, not the log:**
- `.rc` exists and contains `0`; `step-status.py` shows `"aborted":false`. A vanished process with no `.rc` = the wrapper was killed: treat as failed.
- `review-status.py <target>/review.md` re-run:
  - **review session:** `passes` incremented by exactly 1. `overall: CLOSED` → the loop is done, regardless of what the session's prose said.
  - **fix session:** `passes` unchanged (a fix session that appended a Pass section did something it shouldn't — reopen it as a failed step), and every previously-open id is now gone from `open-items`.
- Fix sessions only: the files each closed finding names really changed (`git status --short`, or re-read the cited lines), and **re-run `<test-command>` yourself** (`… 2>&1 | tail -5`) — the child's log mixes failed runs from its own fix loop, so only your re-run verifies the current tree.
- No session touched git state: current branch unchanged, and no commit appeared (`git log --oneline -1` still the pre-run tip). A session that committed or switched branches has violated its preamble — stop the loop and report it rather than continuing on a tree you no longer recognise.
- Use `python3 <skill-dir>/scripts/extract-final.py <log>` only to diagnose *why* a check failed, never to declare success — child logs habitually end in a cheerful handoff paragraph.

**Retries:** on a failed check, retry the step ONCE with the same prompt plus a one-line note of what's missing. Second failure → stop the whole loop, report where and why.

**Stop conditions** (checked after every review session, via `review-status.py` only):
1. `overall: CLOSED` → success, go to the final report.
2. `open: 0` but `overall: OPEN` → the reviewer left findings-none but didn't close (convergence needs a verifying pass). Launch another review pass, not a fix.
3. `open > 0` → launch the fix session, then loop.
4. **Stall:** the same open-item set (same ids) survives two consecutive fix rounds, or every fix round ends with items reopened → stop; more rounds won't fix this, a human decision is needed.
5. Max rounds or session budget reached → stop cleanly at the round boundary.
6. A step failed twice → stop and report.

## 4. Final report & handoff
Everything is still uncommitted on the user's own branch — leave it that way. Print:

| Round | Pass | Open before → after | Reopened | Note |
|---|---|---|---|---|

Then, from the final `review-status.py` output: Overall status and which convergence rule closed it (read the closing pass — "closed clean" vs "closed relaxed"), sessions launched, findings fixed across the run, and — if stopped early — the still-open items with their sections (Bug-class items first) and the exact stop condition that fired.

Show what the run changed against the pre-run baseline recorded in pre-flight:

```sh
git rev-parse --abbrev-ref HEAD   # unchanged from pre-flight
git status --short                # now vs. the pre-run baseline
git diff --stat                   # working-tree changes, per file
git diff > /tmp/review-<id>-changes.diff
```
Print the `--stat` breakdown inline and name the diff file path rather than pasting it; `git diff` shows only tracked-file edits, so also list files the run created (`??` in `git status`). Then hand off: the changes sit uncommitted in the working tree for the user to review and commit themselves.

## Hard rules
- **Never run any git state-changing command** — no add/commit/stash/reset/restore/clean/checkout/switch/merge/push/branch, by you or by any session you launch. The orchestrator's only git calls are read-only (`status`, `diff`, `log -1`, `rev-parse`). This is the rule that keeps the user's uncommitted work safe.
- Never review, never fix, never edit `review.md` yourself — sessions do the work; you launch and verify.
- Never ask the user anything mid-run; the preamble decides every question.
- The tracker file is the source of truth for every loop decision — never session prose, never `kill -0`, never inferring success from output.
- Never echo secret values; fix rounds may touch files under `secrets/`, so verify presence only and never print contents.

## Checklist
- [ ] Argument parsed (or rejected with valid forms); target, `<id>` slug, max rounds, budget, pass-through flags set
- [ ] Pre-flight GO/NO-GO: pi + python3 present, target mapped, tracker state read via `review-status.py`, test command recorded, pre-run baseline (`git status --short` + branch) recorded and the uncommitted-work notice stated
- [ ] Every prompt written to a file via quoted heredoc with the verbatim preamble; every session launched via `scripts/launch-step.py` detached with `--mode json`
- [ ] Every session polled via `scripts/step-status.py` (fast early / sparse later); exit code read from the `.rc` sentinel; `aborted:false` checked
- [ ] Every review session verified: pass count +1; every fix session verified: pass count unchanged, open ids closed, named files changed, test command re-run by the orchestrator
- [ ] No session altered git state: branch unchanged, no new commit, no stash; nothing committed, merged or pushed by anyone
- [ ] Stop conditions evaluated after every round (CLOSED / open-zero-review-again / stall / caps / double failure); at most one retry per step
- [ ] Final report: round table, closing rule or stop condition + open items, working-tree `--stat` + created-file list + diff path; changes left uncommitted
