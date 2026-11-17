# Incident Report — {system} {what went wrong} for {duration} ({qualifiers})

> Sections marked *(optional)*: include only when there is real content — skip rather than pad.

| | |
|---|---|
| **Service** | `{service}` — {endpoints, replicas, namespace, port} |
| **Manifests** | [`path/to/deploy.yaml`](path/to/deploy.yaml) |
| **Backend** | `{upstream host:port}` — {software + version} |
| **Evidence** | `{app1.log}` (N lines), `{app2.log}` (N lines), `{db.log}` (N lines) |
| **Failure** | **{YYYY-MM-DD HH:MM:SS UTC}** — {how it started} |
| **Still unhealthy at** | {YYYY-MM-DD HH:MM UTC} → **≥ {duration}** *(or: recovered at …)* |
| **Detection** | {how/when found — or "none, found N h later by hand"} |
| **Restarts** | {n} |
| **Severity** | {1/2/3} — {one-line qualifier, e.g. "total ingest outage, zero errors logged, zero automated detection"} |
| **Timezone note** | {all sources verified UTC — how} |

---

## TLDR

{≤ 6 sentences: what broke, since when, why (mechanism in one clause), what it cost, whether it
self-healed, and the single most important fix. No claim the body doesn't prove.}

## ELI5

{1–2 short paragraphs, zero context assumed, no unexplained acronyms or file paths. An analogy
that preserves the real mechanism.}

**The moral:** {one sentence — what we're changing so it can't happen again.}

---

## 1. Executive summary

{Fuller narrative than the TLDR, 1–2 paragraphs: what happened, the surprising bits, the primary
root cause with a pointer to its evidence section, and the contributing factors in one sentence.}

## 2. Timeline

| When (UTC) | Event |
|---|---|
| {ts} | {deploy/change/anomaly/detection/repair} |

## 3. Evidence A — {source 1}

### 3.1 {What this source shows}

| {bucket} | n | p50 | p95 | max |
|---|---|---|---|---|
| {…} | | | | |

```
{verbatim log excerpt}   <- {annotation of the pivotal line}
```

> **{One-line bold takeaway: what this source proves.}**

## 4. Evidence B — {source 2}

{Same pattern — one section per independent source; correlate them explicitly
("two pods, same second → cause is shared and downstream").}

## 5. Root cause

**Primary ({H1}) — {mechanism}.** {Evidence-backed explanation, with section references (§3.1, §4).}

**Contributing factors**

| # | Factor | Effect |
|---|--------|--------|
| C1 | {e.g. no liveness probes} | {turned a 45 s outage into 17 h} |

**Ruled out:** {hypothesis} ({the observation that falsifies it}); {…}

## 6. Impact

- Throughput: {X/h → Y/h from {ts}}.
- Data: {known minimum lost} known; real figure {estimate + why it's an estimate}.
- Detection: {where it failed to surface — app logs, DB logs, alerting}.

## 7. Actions taken *(optional — anything already done during/before the report)*

- {What, when, result, side effects — e.g. "Rebooted node3 → node2 → node1, each with a verified snapshot; 0 pending pods after; few-second blip on X".}

## 8. Remediation

### 8.1 {Application}

```{lang}
{concrete config/code fix}
```

### 8.2 {Infrastructure}
### 8.3 {Network / data layer}
### 8.4 Observability

- {Alert that would have caught this: rule + "fires at {ts} on {date}"}

## 9. Open questions / next diagnostics

1. {Question} — {command or data source that answers it}.

## 10. Diagnosis playbook for this class of problem *(optional — include when the failure pattern is reusable)*

Run in order, read-only, with kubectl/context pointed at the affected system:

1. **{Check name}** — `{exact command}`; {how to read the output; what result means what}.
2. **{Check name}** — `{command}`; {…}. **The decisive check:** {the one observation that names this class of problem}.

## 11. Follow-ups

- [ ] {Actionable item, owner-agnostic}
- [ ] {Adjacent finding found while investigating}

## 12. Lessons / gotchas learned

- {Process lesson — bold lead phrase, e.g. **Never trust pinning you haven't verified.** …}
- {Tooling trap: a command that exits 0 while failing, a status field that lies, a renamed field.}
- {Environment quirk worth remembering for the next session at this keyboard.}

## Appendix — how this analysis was produced

```bash
{the exact commands used to derive every number above}
```

{Caveats: log timestamp granularity, sampling, anything that limits precision.}

---

# Short-tier variant (SEV 3 / confirmed single-cause fixes)

```markdown
# {Short title — what is broken}

**Date:** {YYYY-MM-DD/HH}
**Symptom:** {observable failure + verbatim error string + where it appears}
**Status:** {e.g. "root cause confirmed, fix pending approval" / "fixed in <commit>"}
**Related:** {link to related incidents/commits, or omit}

## TLDR

{2–4 sentences: cause, why it surfaced now (crash vs growth cliff), the fix in one clause.}

## Root cause (confirmed {how it was confirmed — where, read-only})

**{One-sentence mechanism.}**

Evidence ({host/context, what was run}):
- `{query/command}` → {result}
- `{EXPLAIN / measurement}` → {numbers}

**Why it broke "suddenly" on {date}:** {growth cliff or trigger, with the threshold that was crossed}.

## Fix

```{sql/sh/yaml}
{exact, executable commands — with run-now caveats like "full scan, run off-peak"}
```

{Expected effect + how it self-heals, if it does.}

## Next steps

1. {Step, with when/where to run it.}

## Debugging notes (for the next session)

- {Non-obvious access path, endpoint, or tool quirk discovered while diagnosing.}
```
