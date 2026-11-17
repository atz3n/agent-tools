---
name: incident-report
description: Write a thorough, evidence-first incident report (post-mortem) for an outage, silent failure, degraded service, or misconfiguration — with a TLDR and an ELI5 section up top, then timeline, log/table-backed evidence, root cause with contributing factors and ruled-out hypotheses, quantified impact, and concrete remediation. Use when asked to write an incident report, post-mortem, post-incident review, or to document an outage/bug that already happened. Pass a short description of the incident and/or paths to logs as argument.
---

# Incident Report

## Role
You write incident reports that a stranger can audit six months later: every claim carries its
evidence (a log line, a command output, a file path, a commit hash), and speculation is always
labeled as a hypothesis. The report is written so that the *next* engineer — or agent — can
re-derive every conclusion from the raw material you include, and can re-run the diagnosis when
the same class of problem returns.

## Cardinal Rules

1. **Evidence or it didn't happen.** Every factual claim cites its source: a quoted log excerpt
   (with timestamps), a command and its output, a file path (+line), or a commit hash. Include
   the exact commands you used to derive numbers so they are reproducible.
2. **Separate fact / hypothesis / ruled-out.** Primary root cause needs an evidence-backed
   mechanism. Competing explanations go in "Ruled out" with the observation that kills them.
   Unproven-but-likely causes are labeled *hypothesis (H1, H2…)*, never stated as fact.
3. **Quantify.** Durations, rates, counts, percentiles, byte volumes — "17 h 45 min", not
   "a long time". If you can't measure, write "≥ N" or "unknown — see Open questions", never
   a made-up number.
4. **All timestamps UTC**, stated once in the metadata header ("Timezone note") after you
   verified it (cross-correlate clocks when multiple sources exist).
5. **Erratum discipline.** If a correction arrives after writing, add an inline
   `**Erratum (date):**` at the affected claim — don't silently rewrite history.
6. **Report only.** Do not fix, deploy, or "quick patch" anything during the report. Fixes are
   proposed in the Remediation section and executed as separate, requested tasks. Reading logs,
   manifests, git history and running read-only diagnostics is in scope. Actions already taken
   by others *are* reported — under "Actions taken".

## Phase 0 — Intake

If the argument and the repo already answer everything (incident description, time window,
where the logs/evidence live), skip to Phase 1. Otherwise ask **one short batch (max 3
questions)**, numbered, each with your suggested default so the user can just say "ok":

1. **Symptom & window** — "What did users/callers observe, and when did it start (and end, if
   it did)?" (default: your reading of the argument, one sentence)
2. **Evidence access** — "Where is the raw material: log files, cluster/kubectl access, a repo,
   a ticket?" (default: the paths/commands mentioned in the argument; state what you can reach
   yourself before asking)
3. **Depth & destination** — full post-mortem or short report (see Report Tiers), and where it
   goes: file here, or filed as an issue somewhere? (default: full report if SEV 1–2, written
   to `incident-<slug>.md`)

Skip the batch entirely if the user said "you decide" / "don't ask" — state your assumptions
instead. Never block on answers you can derive: probe the ground first (`git log`, reachable
logs, manifests) and ask only what the ground cannot tell you.

## Phase 1 — Gather (before writing a single section)

Collect until each bullet is answered or explicitly marked unknown:

- **What/where**: affected service(s), namespace/instance, endpoints, manifests/config files, backend systems.
- **When**: first anomaly, moment of failure, detection time, recovery time (or "still broken as of <ts>").
- **Raw material**: application logs, server/database logs, `kubectl`/system output, git history of the involved files (`git log -S`, `git blame`). Read them end-to-end; grep is for extraction, not for understanding.
- **Derive numbers with reproducible commands** (line-shape histograms, per-hour stats, latency percentiles, counts of error signatures). Keep the commands for the appendix.
- **Correlate independent sources**: two components failing in the same second points downstream; a "healthy" server log during a client outage is itself a finding.
- **Silence is data**: zero errors logged during an outage is a headline finding, not an absence of one.
- **Ask "why now?"** whenever something broke "suddenly" after existing unnoticed: distinguish a *crash* (something changed at time T) from a *growth cliff* (a slow drift — data volume, traffic, config drift — crossed a threshold, e.g. a query that always full-scanned finally exceeded a 10 s timeout).
- **Compare environments**: if the same defect is harmless elsewhere, explain *why* (different event rhythm, different scale, a self-healing path). "Why dev worked with the identical bug" is a finding, not a footnote.
- **Check the tooling's own traps**: verification commands that exit 0 while lying, status fields that look healthy while broken, version changes that renamed the field you're grepping. Record these as gotchas.

While gathering, note anything **adjacent** you stumble on (exposed ports, committed secrets, missing probes). These become separate findings or follow-ups — do not merge them into the primary cause.

## Phase 2 — Assess severity & pick a tier

| Severity | Definition |
|----------|------------|
| **1** | Total outage or silent data loss; and/or no automated detection |
| **2** | Service degraded, elevated errors/latency, users affected |
| **3** | Latent defect or misconfiguration with no user impact yet |

Add modifiers where true: *silent* (no error, no alert), *undetected for X h*, *data loss ~N*.

**Report tiers** — match the report to the incident, don't inflate a simple one:

- **Full** (default for SEV 1–2, or any incident with multi-source evidence): every section below.
- **Short** (SEV 3, or confirmed single-cause fixes — a latent defect, a missing index, one bad manifest): header block (Date, Symptom, Status, Related), *TLDR*, *Root cause (confirmed)* with evidence bullets, *Fix* (executable, with the exact commands/SQL), *Next steps* (checkboxes), *Debugging notes for the next session*. Skip ELI5 only if the user asks; skip evidence sections rather than pad them.

## Phase 3 — Write

Use `template.md` (same folder) as the section skeleton for the full tier. Section order
matters: TLDR and ELI5 come **first** so a reader gets value in 30 seconds; the evidence
deep-dive serves auditors later.

Writing rules per section:

- **Header/metadata block**: Service, Manifests, Backend, Evidence (files + sizes/line counts),
  Failure time, Duration/still-unhealthy-at, Detection, Restart count, Severity, Timezone note.
  For the short tier: Date, Symptom (verbatim error string), Status, Related incidents/commits.
- **Title**: `Incident: <system> <what went wrong> for <duration> (<qualifiers>)` — e.g.
  *"Incident: ingest connector stalled for 17.5 h (silent, both replicas)"*.
  A title may not contain a conclusion the body doesn't prove.
- **TLDR** (≤ 6 sentences, no jargon beyond the system's name): what broke, since when, why
  (mechanism in one clause), what it cost, whether it self-healed, and the single most important
  fix. A CTO reading only this must not be misled.
- **ELI5**: explain the incident to a smart person with zero context — no unexplained acronyms,
  no file paths. Use an analogy that preserves the actual mechanism; an analogy that hides the
  mechanism is worse than none. 1–2 short paragraphs, and end with the one-sentence moral
  ("what we're doing so it can't happen again").

  **Worked example** — mechanism: *a client's TCP connection to its database was silently cut by
  a network device; the client had no timeouts, so every request queued forever behind the dead
  connection, with no errors logged.*

  > ❌ Bad TLDR: "There was a database problem that made the app stop working. It took a long
  > time to find and we fixed it by adding a timeout. Monitoring will also be improved."
  > — vague ("a problem"), no duration, no cost, doesn't say it was silent, no real fix named.

  > ✅ Good TLDR: "From 20:35 UTC on Nov 3 until 14:20 the next day (**17 h 45 min**), both
  > replicas of the ingest connector completed **zero** requests to the database — no errors, no
  > restarts, no alerts. The database itself stayed up: the connectors' long-lived connections
  > had been silently cut by a network device, and because the client had no query timeout and
  > no keepalive, every later request queued forever behind a dead connection. Ingest wrote
  > ~2 MB/h instead of ~920 MB/h; requests that finally 'succeeded' after 16 h returned HTTP 200
  > with nothing written. The single most important fix: query timeouts + TCP keepalive on the
  > DB pool, so a dead socket errors in seconds instead of hanging forever."
  > — every number is in the body with evidence; the mechanism fits in one clause.

  > ❌ Bad ELI5: "The pg pool's sockets went half-open because conntrack evicted the entry, and
  > with connectionTimeoutMillis 0 the promises never settled." — that's the report, not the ELI5.

  > ✅ Good ELI5: "The app talks to its database like a phone call. On the evening of Nov 3,
  > the phone line was cut without anyone saying goodbye: the app's phone still 'thinks' the
  > call is connected, so it just holds the receiver and waits — and every new message queues
  > silently behind it. Because the app never noticed, it never complained and never redialed,
  > and for almost 18 hours nothing was saved, although some messages were stamped 'done'. The
  > fix is to hang up and raise an alarm when the other side hasn't answered in a few seconds.
  > **The moral:** nothing may wait forever — with timeouts everywhere, failures show up in
  > seconds instead of vanishing for a day." — the phone analogy *is* the half-open-session
  > mechanism; dropping it (or adding jargon) would hide the cause.
- **Evidence sections** (one per independent source): tables for distributions/timelines,
  verbatim log excerpts for the pivotal moments (mark them with comments like `<- LAST completed request, ever`),
  and a one-line bold takeaway per subsection stating what this source proves.
- **Root cause**: primary mechanism first (with its evidence links, e.g. "§5.4"), then a
  *Contributing factors* table (`C1…Cn` — things that turned one failure into a long/silent one),
  then *Ruled out* with the falsifying observation for each.
- **Impact**: throughput before → after, data lost (known minimum + estimated real figure,
  clearly separated), and where it failed to surface.
- **Actions taken** (if anyone already did something during/before the report — restarts,
  reboots, restored configs): what, when, result, and side effects. Reporting actions ≠
  endorsing them; anything still contested stays in Remediation.
- **Remediation**: grouped by area (application / infrastructure / network / observability),
  concrete enough to execute — config snippets, probe YAML, exact alert rules with the threshold
  and *when they would have fired* ("fires at 20:36 on Nov 3").
- **Open questions / next diagnostics**: numbered, each with the command or data source that
  would answer it.
- **Diagnosis playbook for this class of problem** (include when the incident exposes a
  *reusable* failure pattern — status that lies, a swallowed update, a silent collision): an
  ordered list of read-only checks, each with the exact command and how to read its output
  ("X present in A but absent from B = the update was swallowed"). Write it so the next
  occurrence can be diagnosed by copy-paste, and say what the *decisive* check is.
- **Follow-ups**: checkbox list (`- [ ]`) — actionable items, including adjacent findings.
- **Lessons / gotchas learned**: short bullets — process lessons ("never trust a verification
  command whose exit code you haven't proven"), tooling traps (commands that exit 0 while
  failing, renamed status fields), and environment quirks worth remembering. Write for *the
  next session at the keyboard*.
- **Appendix**: the derivation commands, field indices, and caveats (e.g. log timestamp granularity).

## Phase 4 — Self-audit before delivering

Re-read the draft and check:

1. Every number traces to a quoted source or a listed command; spot-check three.
2. TLDR contains nothing the body disproves; ELI5 contains no unexplained jargon and its
   analogy preserves the mechanism.
3. Root cause mechanism explains *all* observed signatures (including the weird ones — the
   report must account for its own anomalies, e.g. false 200s in milliseconds).
4. No claim stronger than its evidence ("proves" vs "consistent with").
5. Severity matches the table; duration arithmetic is right; tier matches the material (no
   ten-section report for a missing index, no three-line report for a silent 17 h outage).
6. Every remediation item maps to a named cause or contributing factor.

## Phase 5 — Deliver

- **Default**: write the report to `incident-<short-slug>.md` in the current project and
  summarize the TLDR in chat.
- **File as issue** (when asked): file against the user's incidents repository via the GitHub
  proxy on `localhost:8086`, following the `github-manage-issues` skill, with label `incident`
  and the report as the body. If the proxy is not reachable, hand the user the markdown file
  and say how to file it.
