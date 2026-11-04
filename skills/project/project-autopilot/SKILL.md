---
name: project-autopilot
description: Autonomously run the project pipeline (write-spec → architecture → implement → qa) for features in fresh pi sessions on a dedicated git branch — build ONE feature (e.g. "1.4"), a whole PHASE (e.g. "phase 1"), or the "next" pending feature(s). Pre-flight checks feature dependencies (PLAN.md + spec Status lines) and external dependencies (docker, network, credentials) before calling any project skill, then loops implement↔qa until each feature is Approved and hands off the branch for review/PR. Supports `--dry-run` (pre-flight + plan only). Use when asked to build/implement a feature or phase autonomously/unattended.
---

# Project Autopilot

## Role
You are the unattended orchestrator. You never implement anything yourself — you launch fresh, non-interactive pi sessions that run the project skills, verify their output, and keep the pipeline moving. The user is away; nothing may wait on them.

Work from the project root (`PLAN.md`, `features/` relative to it).

## 1. Parse the argument
- `1.4` (or a feature name) → build that single feature.
- `phase 1` (or `phase P1`) → every row of that phase's table in PLAN.md.
- `next [N]` → the next 1 (or N) not-yet-Approved features in roadmap order.
- No argument → ask nothing; treat as `next 1`.
- `--dry-run` (with any target) → run the pre-flight, print the plan (branch, order, steps per feature, GO/NO-GO), then stop without launching a session.
- Anything unrecognized (an ID matching no PLAN.md row and no spec file, a phase that doesn't exist, a garbled argument) → do not guess and do not start: report the argument you received, list the valid targets from PLAN.md, and stop.

If the user named a model, cost limit, or tool restriction, carry it onto **every** launch (`--model <pattern>`, `--tools …`).

**Session budget:** cap the run at 12 launched sessions unless the user gave a number. Every launch counts — steps, retries, and cross-skill interventions. When the cap is reached, stop cleanly at the current feature boundary and report what remains.

Resolve the build set, then **topologically sort it** using the PLAN.md Dependencies column. Features outside the set that a set member depends on must already be Approved (checked in step 2), not built by you.

Derive the run's branch name from the target: `autopilot/1.4`, `autopilot/phase-1`, `autopilot/next-3` (or a branch name the user supplied — the user's choice wins).

## 2. Pre-flight — before calling any project skill
Run all checks, then report one consolidated GO/NO-GO. **Abort with a clear message if anything fails** — do not start a pipeline you can't finish.

### a. Feature dependency readiness
For each feature F in the set, for each dependency D in PLAN.md:
- D is in the build set → it just has to come earlier in the topological order (1.11-style "All Phase N tasks" = every phase feature precedes it).
- D is outside the set → `features/{D}-*.md` must exist and its `## Status:` line must be **Approved**. A dependency at Implemented/In Review blocks the run (its bugs may still change behavior).
- No spec file and status "Roadmap" is fine — that's what this skill will create.

### b. External dependencies
Discover the project's own conventions — never assume a layout. Read the committed env examples (`.env.example`, `settings.env`, compose `env_file:` entries, `secrets/*.txt` / `secrets/*.env`) plus docs/README for required variables; a placeholder value like `your-api-key-here` means a secret is missing. Check **values only** — `grep -v '^#' file | grep '=' | awk -F= 'tolower($2) ~ /your-|placeholder|changeme|xxx/'` — never grep the whole file: env files habitually contain the word "placeholders" in their own comments, and a whole-file grep reports a false positive on a file whose real values are set. Check only what the build set actually needs — a database/broker/third-party credential matters only once a feature in the set touches it. Verify the toolchain:
- `docker info` succeeds if any feature in the set builds or runs containers; `node --version` if lint/tests run through npx; the interpreter/compiler the project's toolchain files imply.
- Network reachable if images, packages, or npx downloads must be fetched.
- `pi --version` succeeds — the orchestrator launches child `pi` sessions, so if `pi` is not on PATH in this environment, abort with that reason rather than discovering it at the first step.
- **Discover the project's test command once, here** (`make test`, `python3 -m unittest`, `npm test`, `go test ./...`, a Docker script…) from `Makefile` / `pyproject.toml` / `package.json` / `go.mod` / README, and reuse it for every verification below — never hardcode `make test`.
- Secrets: look for the gitignored file the project actually loads. If a needed secret is absent, check the user's original instruction: if they said "mocked" or "no credentials", proceed with mocked verification and record live-verification as deferred; otherwise **abort** and name the exact file/variables to fill.
- Never echo secret values; only check presence/placeholder status.

### c. Repo hygiene & branch setup
- Identify the base branch: current branch if it is the project's main line (`main`/`master`, or the repo default), otherwise ask nothing — base off `main` if it exists, else the current HEAD.
- `git status --short` must be clean. Commit only uncommitted work produced by **your own earlier autopilot sessions on this branch** (as `chore:`); anything else — especially a dirty tree you did not create — is reported, never committed.
- `git checkout -b <branch>` from the base (if the branch already exists from an earlier aborted run, check it out and continue where the specs' Status lines say to resume — never reset it).
- Record **two** bases, and re-record them after checking out a pre-existing branch from an earlier run:
  - `run_base=$(git rev-parse HEAD)` — the tip this run starts from; used for "commits made by this run".
  - `review_base=$(git merge-base <base-branch> HEAD)` — where the branch diverged from the main line; used for the review diff, so a resumed run still shows everything the branch adds, not just its last session.
- **Resuming after an interrupted orchestrator:** nothing is redone by hand. The branch, the spec Status lines, and `/tmp/autopilot-<id>-<step>-<n>.log` + its `.rc` sentinel are the whole record — re-read them and continue from the step table in section 3. A step with no `.rc` file was interrupted, not completed: relaunch it (same prompt, next `<n>`), it does not count as a retry.

Print the plan: branch name, ordered feature list, steps per feature (from status lines), GO/NO-GO. Then proceed without waiting.

## 3. The pipeline — per feature, in order
For each feature, read its spec `## Status:` (authoritative; no spec file = start at write-spec) and run only the needed steps:

| Status | Next step(s) |
|---|---|
| (no spec) | write-spec → architecture → implement → qa |
| Planned | architecture → implement → qa |
| Architected | implement → qa |
| Implemented | qa |
| In Review, open High/Critical bugs | implement (bugfix) → qa — repeat (max 3 rounds) |
| In Review, only Low/Medium open bugs | qa (run the accept-or-defer pass, then verdict) |
| In Review, no open bugs | qa (finalize verdict) |
| Approved | skip, log "already approved" |

### Launching a step (always a fresh session)

**1. Build the prompt as a file, not a shell variable.** The verbatim preamble from "THE PREAMBLE" (plus the per-step extension) contains apostrophes, double quotes, em dashes and real newlines. Re-escaping it inside a double-quoted shell assignment (`PREAMBLE="… the skill's own recommendation …"`) silently truncates or mangles the prompt, and the child then runs a corrupted instruction. Write the finished prompt with the file-writing tool, or with a **quoted** heredoc so nothing is expanded — real newlines in the prompt, never a literal `\n`:
```sh
prompt_file=/tmp/autopilot-<id>-<step>-<n>.prompt
cat > "$prompt_file" <<'EOF'
<verbatim preamble>

/skill:project-<step> <id>
EOF
```

**2. Launch detached, with a completion sentinel that carries the exit code.**
```sh
cd <project-root>
id=<id>; step=<step>; n=<n>
prompt_file=/tmp/autopilot-$id-$step-$n.prompt
log=/tmp/autopilot-$id-$step-$n.log
rc=/tmp/autopilot-$id-$step-$n.rc
test -s "$prompt_file" || { echo "missing prompt file"; exit 1; }
rm -f "$rc"
setsid nohup bash -c 'pi -p --approve --mode json "$1" >"$2" 2>&1; echo "$?" >"$3"' \
  _ "$(cat "$prompt_file")" "$log" "$rc" >/dev/null 2>&1 &
```
- **Why backgrounded:** the child must outlive the tool call that started it. A foreground call running for tens of minutes is fragile — a harness/tool timeout, an interrupted orchestrator, or a killed process group takes the child down with it, mid-commit and with no log. Detached, it keeps working and keeps writing the log, which is exactly what "Resuming after an interrupted orchestrator" (2c) relies on. Backgrounding is *not* permission to run steps concurrently (see below).
- **Why the `.rc` file:** once the launcher shell exits there is no `wait` and no `$?` for the session, and `$!` may not even be the `pi` PID (`setsid` forks). `echo "$?" >"$rc"` is the only durable record of the real exit code. Read it — never infer success from output alone.
- **Why `--mode json`:** in default text mode `pi -p` writes nothing until it finishes, so the log sits at 0 bytes for the whole step and `tail` gives no signal at all. JSON mode streams events as they happen, so the log doubles as a live progress feed (step 3) and ends with a terminal `agent_settled` event carrying an `aborted` flag.
- `setsid` puts the child in its own session so killing my process group cannot take it down; because of that fork, do **not** treat `$!` as the pi PID.

**3. Poll adaptively — and never use `kill -0` as the liveness test.** In a container the launcher exits immediately, the finished `pi` is reparented to a PID 1 that does not reap it, and it stays `[pi] <defunct>` forever: `kill -0 <pid>` on a zombie **succeeds**, so every completed step looks like it is still running. Test the sentinel:
```sh
if [ -f "$rc" ]; then echo "DONE rc=$(cat "$rc")"; else
  echo "RUNNING tool_calls=$(grep -c '"type":"tool_execution_end"' "$log") log_lines=$(wc -l <"$log")"
fi
```
Cadence: **30–60s for the first ~3 minutes** — a bad prompt, a missing skill, or a session that crashes immediately shows up there, and catching it at 2 minutes instead of 15 is the whole point of polling early — then widen to **4–5 minutes** once the step is visibly progressing (tool calls accumulating, files/commits appearing). A flat short interval across a whole run spends the orchestrator's own context window on polls that carry no news, so do all the checking in *one* call per poll (sentinel + `git log --oneline -1` + `git status --short` + tool-call count), not several.

Steps are strictly sequential — never run two features or two steps concurrently.

**4. Read the log.** The log is the source of truth — check the `.rc` file and read the log, never judge a step by its last 30 lines. A `tee | tail` pipeline hides the session's exit code behind `tail`'s, which would let a crashed step look successful. To pull the final assistant text out of the JSON log (no `jq` needed):
```sh
python3 -c 'import json,sys
for l in open(sys.argv[1]):
    try: e=json.loads(l)
    except ValueError: continue
    if e.get("type")=="agent_end" and e.get("messages"):
        for b in e["messages"][-1].get("content",[]):
            if b.get("type")=="text": print(b.get("text",""))' "$log"
tail -1 "$log" | grep -o '"aborted":[a-z]*'   # agent_settled: expect "aborted":false
```

Child sessions are plain `pi -p` processes started from the project root — they inherit this session's environment, installed skills, and credentials. Carry any user-requested `--model` / `--tools` / `--thinking` flags onto the `pi` line inside the wrapper.

### THE PREAMBLE — use verbatim, extended per step
`<test-command>` is the command recorded in pre-flight 2b.
```
You are running UNATTENDED. Never ask the user questions, and never end your turn with a question, a menu of options, or a request for confirmation — the interview, "continue?", and "user review" steps in your skill have no human on the other end. Wherever the skill says to ask, pick the skill's own recommendation if it has one, otherwise the most sensible default consistent with PLAN.md, docs/ and the existing code, record it in the spec's Decision Log marked auto-resolved, and keep going until the skill's checklist is complete. Leave no open questions. Stay on the current git branch: never create, switch, reset, merge, or push branches. If your step changed code, run <test-command> and make it pass before you finish; spec/design steps change no code, so do not touch tests there. When done, commit your work with the conventional commit your skill specifies.
```
Append to the QA step (with the two placeholders substituted as described below):
```
Bug severity policy (user decision): every Low- and Medium-severity bug is recorded with Status "Deferred (user decision — autopilot run <branch>, AUTOPILOT_DATE)" plus a suggested follow-up feature, never left open, and the spec's Last Updated date is bumped. High and Critical bugs stay Open as normal and are fixed in the implement↔qa loop. When no bug in the latest run block is still Open, set the spec Status to Approved.
```
Deferring Low **and** Medium is what makes approval reachable: `/skill:project-qa` never sets Approved while any bug in the latest run is Open, so deferring only Low would leave every Medium bug cycling the fix loop to its cap and aborting the run. Use the canonical `Deferred (user decision — <when/where>, <date>)` form verbatim — the bare prefix without the when/where and date breaks `/skill:project-doctor` and `/skill:project-help` bug parsing and loses the follow-up trail.

**The date is never typed from memory or guessed.** A wrong date silently desyncs the deferral records from the QA Run blocks and Last Updated date the child stamps with its own `date`, and poisons every later `Deferred (… <date>)` parse. Make it mechanical: leave the literal token `AUTOPILOT_DATE` in the quoted heredoc and substitute the real clock in the same script that launches the step, then assert the substitution before launching:
```sh
cat > "$prompt_file" <<'EOF'
<verbatim preamble>

<QA policy text with the literal token AUTOPILOT_DATE>

/skill:project-qa <id>
EOF
sed -i "s/AUTOPILOT_DATE/$(date +%F)/" "$prompt_file"
grep -q "autopilot run <branch>, $(date +%F)" "$prompt_file" || { echo "date stamp missing/wrong"; exit 1; }
```
The quoted heredoc keeps everything else unexpanded; only the token is substituted, with the same plain `date +%F` the child runs on the same host, so the stamp matches the dates the child computes itself. Substitute the run's branch name for `<branch>` the same way (it is known from pre-flight — type it, don't guess it).

(If the user explicitly said "fix all bugs", drop the deferral sentence instead — the user's instruction in this conversation always overrides this default. Note that this makes every Medium bug a blocker: expect more fix rounds.)

### After every step — verify, don't trust
- `/tmp/autopilot-<id>-<step>-<n>.rc` exists and contains `0`, the log ends with `agent_settled` and `"aborted":false`, and the final text is real completion — not a stop/"please confirm" message. (Child logs habitually end in a cheerful handoff paragraph, so confirm against the commit and Status line below, not the prose.) A vanished process with no `.rc` means the wrapper itself was killed: treat the step as failed.
- The claimed commit exists and matches the step's convention: `git log --oneline -1`.
- The spec Status moved as expected: `grep -m1 '^## Status:' features/{id}-*.md` — anchored, because the STATUS LIFECYCLE comment also contains the word "Status". If the glob matches more than one file, stop and resolve the duplicate spec files first (`/skill:project-doctor` flags them) before continuing.
- Code steps (implement/qa): **re-run the test command recorded in pre-flight 2b yourself** against the committed tree (capture output cheaply, e.g. `<test-command> 2>&1 | tail -5`). The child's log is not proof of green tests: it mixes raw tool output with the child's narrative, which habitually quotes earlier failed runs from its fix loop, and only the re-run verifies the *committed* state — strays, uncommitted fixes, and post-test edits fall out for free. Running the project's own test command is verification, not implementation, so it does not break the orchestrate-don't-build rule. Use log extraction only to diagnose *why* a re-run failed before writing the retry note — and then only from `tool_execution_end` events, never from the final assistant text:
  ```sh
  python3 -c 'import json,sys,re
  for n,l in enumerate(open(sys.argv[1],errors="replace")):
      try: e=json.loads(l)
      except ValueError: continue
      if e.get("type")=="tool_execution_end":
          r=e.get("result"); t=r if isinstance(r,str) else json.dumps(r)
          if re.search(r"\d+ passed", t):
              print(n, re.findall(r"\d+ (?:passed|failed|error)[^\\n\"]{0,40}", t))' "$log"
  ```
  The last entries are the runs nearest the end of the step; a run whose text contains `failed` there means the child ended on red — the re-run decides.
- `git status --short` is clean; if a step left uncommitted work, commit it as the step's type (`fix(1.x):` etc.).

**If the step stopped to ask for a different skill** (its log says the feature needs `/skill:project-architecture`, or it refused because the Status/Tech Design isn't ready — e.g. implement hitting a structural deviation it won't invent), do not re-run the same prompt: launch the requested skill for the same feature, verify it, then re-launch the original step. This intervention counts as the one retry.

Otherwise: retry the step ONCE with the same prompt plus a one-line note of what's missing. Second failure → stop the whole pipeline (later features may depend on it), report where and why.

### Implement↔QA loop (High/Critical bugs)
After each qa step, read the newest `### QA Run` block — don't guess the block number:
```sh
n=$(grep -c '^### QA Run' features/{id}-*.md); awk -v n="$n" '/^### QA Run/{i++} i==n' features/{id}-*.md
```
Any bug whose Status is not `Fixed (Run N)` and not `Deferred (user decision…)` (any when/where/date suffix) = open → run an implement step ("fix these open QA bugs: …list them…", commit `fix({id}):`), then a new qa step. **Cap: 3 rounds per feature.** Still failing after round 3 → leave the feature at In Review, stop the pipeline, report the bug history.

## 4. Final report & review handoff
Stay on the run branch — do NOT merge or push (the user reviews first; push/PR only if they explicitly ask). Print a summary table and stop — do not start features outside the requested set:

| Feature | Steps run | QA rounds | Result | Commits |
|---|---|---|---|---|
| 1.4 | spec→arch→impl→qa | 1 | Approved | e436d53..cb2c48b |

List: deferred Low/Medium bugs (with their follow-up features), any aborted feature and reason, and the next roadmap action (e.g. which features are now unblocked).

Then print the review handoff:
```sh
git log --oneline <run_base>..HEAD      # commits made by this run
git diff --stat <review_base>..HEAD     # what the branch changes, per file
git diff <review_base>..HEAD > /tmp/autopilot-<target>-review.diff
git diff <review_base>..HEAD | wc -l    # size of the full diff
```
A feature diff runs to thousands of lines — never paste the full diff into the report. Print the summary table, the `--stat` breakdown and the commit list inline; write the full diff to the file above and name the path (and offer it inline only if it is small or the user asks).

State: branch name ready for review; to open a PR, use `/skill:github-create-pull-request` (base = main line, head = <branch>); after merge, `git checkout <base-branch> && git pull && git branch -d <branch>`.

## Hard rules
- Never edit feature code or specs yourself — sessions do the work; you orchestrate, verify, and commit strays from your own sessions only.
- Never ask the user anything mid-run; the preamble decides every question.
- Never commit secrets; verify `.gitignore` covers whatever file holds them before any step that touches credentials.
- One failure mode that aborts immediately: dirty git state that a project session didn't create (someone editing concurrently — report instead of committing over it).
- Never merge, never push. The branch is handed back; PR/merge is the user's call.

## Checklist
- [ ] Argument parsed (or rejected with the valid targets listed); target set resolved and topologically sorted
- [ ] Pre-flight complete: feature dependencies Approved, external dependencies verified, test command recorded, GO/NO-GO reported
- [ ] Clean tree, run branch created, `run_base` and `review_base` recorded
- [ ] Every step launched through the verbatim preamble (written to a prompt file) in a fresh, detached `--mode json` session; the QA step's `AUTOPILOT_DATE` stamp substituted from `date +%F` and asserted before launch, never typed from memory
- [ ] Every step's real exit code read from the `.rc` sentinel; polled via the sentinel (never `kill -0`, which lies about zombies) with fast early / sparse later cadence
- [ ] Every step verified (commit, `^## Status:`, test command re-run by the orchestrator, clean tree) with at most one retry / cross-skill intervention
- [ ] Implement↔qa loop capped at 3 rounds per feature; Low/Medium bugs deferred in the canonical form
- [ ] Session budget respected; no features outside the requested set touched
- [ ] Final report printed: summary table, deferred bugs, aborted feature + reason, next roadmap action
- [ ] Review handoff printed (`run_base`/`review_base` diffs); nothing merged or pushed
