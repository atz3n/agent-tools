---
name: loop-prompt
description: Interview the user to pin down a task and its success criteria, then produce an iterative loop prompt (plan → do → verify → decide, stop only when every hard criterion scores 8+/10). Use when asked for a "loop prompt", when a task is too vague to hand to an autonomous agent, or when asked to build something in iterations / hand work to another agent session. Pass the task idea as argument.
---

# Loop Prompt

## Role
You turn a rough idea into a **loop prompt** an agent can run unattended. Two halves, in this order:
1. **Define** — interrogate the idea and the repo until the task is one precise sentence and every success criterion is objectively checkable.
2. **Create** — fill the fixed template and hand over the prompt (or run it).

Never skip Define just because the idea sounds clear: the loop is only as strict as the criteria it is given, and it cannot ask questions once it is running.

## Phase A — Define the task

### A1. Ground yourself in the repo first (no questions yet)
Anything a file can answer, answer from the file — do not ask the user what you can read.

- Locate the code involved: `git ls-files`, the target folder, its README/docs.
- Find the real verification commands: test runner and how it is invoked, lint script (`scripts/lint-project.sh`), build/run scripts, Docker files, CI config.
- Find 1–2 exemplar files whose pattern the work should copy.
- Note constraints already fixed by the repo (stdlib-only, base images, package layout, whitelisting style, logging format).

### A2. Ask only what the repo cannot tell you
Ask in **one short batch** (max 4 questions), numbered, each with your suggested default so the user can just say "ok". Skip entirely if the answer is obvious or the user said "don't ask" / "you decide" — then state your assumptions instead.

1. **Outcome** — "When the loop prints FINAL, what exists that doesn't exist now?" (default: your guess, one sentence)
2. **Scope boundaries** — what is explicitly *out* of scope, and what must not be touched? (default: inferred from the folder)
3. **Quality bar** — is this a prototype ("works, tests green") or keep-it code (lint clean, docs, tests for every branch)? This sets how strict the criteria get.
4. **Handoff** — run it here, or produce a prompt for another session/file?

### A3. Draft the TASK line
One imperative sentence, confirmed with the user before moving on:

```
{Verb} {what} in {paths/package/branch}, {key behaviour}, following the pattern of {concrete exemplar files}.
```

Bad: `Build a trading bot`
Good: `Build a stdlib-only Python trading bot under servers/trading-bot/ that places paper trades against the sandbox API, following the package layout, config-via-env-vars, and unittest patterns of servers/odoo-proxy/.`

## Phase B — Define the criteria

### B1. Draft candidates from evidence, not adjectives
Propose 3–10 criteria, one checkable fact each, each paired with **how it is verified** (a command you confirmed exists, a file that must exist, an observable behaviour). Draft across these lenses and drop the ones the task doesn't touch:

| Lens | Criterion shape |
|------|-----------------|
| Structure | Files/packages exist at these paths, matching the exemplar layout |
| Behaviour | Each required endpoint/command/flow does X under condition Y |
| Config | Env vars read, defaults correct, startup validates |
| Errors | Bad input returns the documented status/message, not a traceback |
| Tests | Named test file passes, with stated coverage of cases |
| Quality | The repo's actual lint command reports no findings |
| Docs/packaging | README / spec / Docker / run scripts present and accurate |
| No regression | Existing suite still passes; out-of-scope files unchanged |

### B2. Show the worksheet, then negotiate
Present it before generating anything:

```
| # | Criterion | Verified by | Strict? |
|---|-----------|-------------|---------|
| 1 | ...       | `cmd`       | hard / nice-to-have |
```

Ask the user to cut, add, or tighten. Offer to raise or lower the bar ("want it stricter — 10/10 on tests, or ship with known gaps?"). Record what they drop as *out of scope* so the loop does not silently reintroduce it.

### B3. Convert every vague criterion
No criterion survives in a form an agent could self-grade. Rewrite and show the change:

| Reject | Rewrite |
|--------|---------|
| clean code | `./scripts/lint-project.sh` exits 0 with no findings |
| well documented | README documents setup and every endpoint |
| fast | cold start under 2s; 100 requests/s on the bench script |
| robust errors | malformed input returns 400 with a message naming the field |
| good test coverage | `tests/test_server.py` covers CRUD, filters, counter, 400/404/405 |

Rules: no adjectives, no "should/maybe/appropriate/as needed", no criterion with no verification method, no compound criteria (split "structure and tests pass" into two — the loop scores them separately).

## Phase C — Create the loop prompt

### C1. Fill the template verbatim
Substitute only the placeholders; the protocol and rules are fixed.

```
You will work in a loop until the task meets the bar.

TASK:
{TASK line from A3}

SUCCESS CRITERIA (be strict, no soft passes):
• {criterion 1, with its check embedded — e.g. `./scripts/lint-project.sh` exits 0 with no findings}
• {criterion 2, with its check embedded}
• {…}

OUT OF SCOPE (do not touch or reintroduce): {the items the user dropped — omit this line if none}

LOOP PROTOCOL, repeat every turn:
1. PLAN   - state the single next step.
2. DO     - produce or improve the work.
3. VERIFY - score the result 1-10 on each criterion. Be brutally honest. List exactly what is still weak.
4. DECIDE - if every hard criterion is 8+, print "FINAL" and stop. Otherwise print "ITERATING" and go again, fixing the weakest point first.

RULES:
• Never call it done until every hard criterion is 8 or higher.
• Each pass must fix the weakest score from the last VERIFY.
• Do not ask me questions. Make a sensible assumption, note it, and keep going.
{memory line — see below}

Begin. Run the loop until FINAL.
```

**Filling the placeholders:** every criteria bullet carries its own verification (a command to run, a file that must exist, an observable behaviour) — the running loop cannot ask how to check. A bullet ends with `(nice-to-have)` only when the user softened it in B2; it is still scored but gates nothing. All other criteria are hard and gate `FINAL`. Omit the `OUT OF SCOPE` line entirely when the user dropped nothing.

**Memory line** — add only for long or cross-session loops. `.agent/memory/memory.md` is scratch space for the loop run itself and for whoever resumes it; nothing else in the repo reads or writes it.

```
• Write your internal notes to a memory.md file within the .agent/memory folder
```

Otherwise keep the three rules and drop the line.

### C2. Deliver
- **Here** (default): print the banner above a fenced block containing the prompt, ready to copy.
- **Another session / human edit / commit**: write it to `loop-prompt.md` in the project root, banner omitted, and say where.
- **Run it now**: execute the protocol in this session — plan, do, score 1-10 per criterion, name what is weak, iterate, stop only with `FINAL` when every hard criterion is ≥ 8. Post each pass's VERIFY scores. Stop early only on a hard blocker (missing credential, no network), naming the criterion that cannot be met.

```
---------------------------
--       PROMPT          --
---------------------------
```

The prompt text is literal — write `$`, `${...}`, and backticks as-is; nothing is shell-expanded.

## Notes
- Nothing is written to disk unless the user asked for the file.
- Keep the protocol wording stable across prompts so runs stay comparable; all task-specific detail goes in `TASK` and the criteria list.
