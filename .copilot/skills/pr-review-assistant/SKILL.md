# Skill: pr-review-assistant

## Purpose
End-to-end **review one PR**: fetch diff, pull context, run code-review analysis, post substantive comments at all four severity tiers directly to ADO, write a per-iteration markdown report, and email Nir a one-pager summary. Built for the **Your Team**.

## Invocation — on-demand only

**Nirvana does NOT review PRs automatically.** It reviews a PR only when Nir explicitly asks: "review PR `<id>`" / "draft review for PR `<id>`" / "review my queue" / "pr-review-assistant". The same agent flow applies; it can re-review an iteration if invoked with `-Force`.

> The scheduled task `DM-PrReviewAssistant` is **disabled** (per Nir, 2026-05-29). No 5-minute scan runs. The runner's scheduled-scan code path (cutoff filter, one-PR-per-tick) still exists but is only exercised if the task is re-enabled. Idempotency state in `state/seen.json` still prevents re-reviewing the same (PR, iteration) twice within a given invocation.

## Fixed context
- ADO org `your-ado-org`, project `One` (from `config/agent.json` → `ado`).
- Nir's identity in ADO: resolve via `ado-core_get_identity_ids` once per session (search filter: `manager.email` from agent config).
- Output report path: `<repo>\reports\pr-reviews\<pr-id>\iter-<n>.md` (one file per iteration; never overwrite previous).
- **DM review rules:** `<repo>\.copilot\skills\pr-review-assistant\rules\*.md` — single source of truth for the team-specific code-review rules layered on top of generic hygiene (SOLID/CLEAN, COGS/perf scaling, PSL storage abstraction, test naming, FluentAssertions, no `Thread.Sleep`/`Task.Delay`, no fire-and-forget async, parallelism bound to `ConcurrentExclusiveSchedulerPair`, etc.). The runner reads every `*.md` in this folder and injects the absolute paths into the agent prompt; the agent MUST load every listed file before composing findings. Editing a rules file takes effect on the next review — no other plumbing needed. These rules apply to **DM code only** (Kusto.Cloud.Platform is exempt per the scope note at the top of each rules file).
- State folder: `<repo>\.copilot\skills\pr-review-assistant\state\`
  - `seen.json` — array of `{ "pr": <id>, "iteration": <n>, "reviewed_at": "<ISO>" }` records (lifetime-once per pair). Runner manages this; the agent does NOT touch it.
  - `cutoff.txt` — auto-review cutoff (scheduled scan only). First non-comment line is an ISO 8601 timestamp; PRs created strictly before that instant are dropped from the scan candidates **unless** Nir was added as a reviewer on/after the same instant (the runner reads the PR's threads and looks for a system-message comment `"<adder> added <SelfDisplayName> as a reviewer"`; the latest such timestamp on/after the cutoff "rescues" the PR). The sentinel `none` (or a missing file) disables the filter entirely. **On-demand `review PR <id>` / `-PRId <id>` invocations bypass this gate** (Nir explicitly named the PR). `-Force` still only affects `seen.json` — to retroactively review an old PR, use the on-demand path.
- Email recipient: `Get-AgentField -Path 'manager.email'`.
- Subject prefix: `Get-AgentField -Path 'agent.mail_subject_prefix'`.

## Inputs (provided to the agent in the prompt)
The runner constructs the prompt with these pre-validated facts so the agent doesn't repeat them:
- `<pr-id>` — required.
- `<iteration-id>` — the latest iteration ID at scan time.
- `<repository>` — repo name (e.g. `Azure-Kusto-Service`).
- `<report-path>` — absolute path to write the per-iteration markdown report.
- `<is-on-demand>` — `true`/`false`. When `false` (scheduled), the skill is allowed to **skip** if it determines the diff is too large (see size guard).
- `<migration-mode>` — `true`/`false`. When `true`, **draft only**: do not post comments to ADO, do not send email, do not write state. Write the report file only.

## Flow (per PR)

### 1. Validate
- Re-fetch the PR via `ado-repo_get_pull_request_by_id`. Confirm `status='Active'`, `isDraft=false`, `createdBy.id != <nir-id>`, `<nir-id>` is in `reviewers`.
- If any check fails, abort with a single log line — do NOT post or email.

### 2. Pull diff
- `ado-repo_get_pull_request_iterations` to confirm the iteration ID exists (in case a force-push rewrote history between the runner's scan and the agent's review).
- `ado-repo_get_pull_request_iteration_changes` for the file list + change types. If the iteration ID drifted, use the latest iteration instead.
- For each changed file, fetch the new content via `ado-repo_get_item` (or the diff representation if simpler). Skip binary files and files larger than 200 KB.

### 3. Size guard
If diff exceeds **either**:
- 30 changed files, OR
- 1500 changed lines (added + removed)

→ post **one** top-level thread (status=`Active`) with this exact text:

```
Auto-review skipped: this iteration changes <N> files / <L> lines, above the auto-review threshold (30 files / 1500 lines). Will need manual eyes.

— Nirvana
```

…then post the size-skip **marker thread** per §7a (`kind=size-skipped`, status=`Closed`), write a stub report (`status: skipped-size`), email Nir with subject `… — auto-review skipped (too large)`, and exit. Update `seen.json` (idempotent skip — don't re-trigger on the same iteration).

### 4. Pull context (best-effort; never block review on these)
- For each changed file's path, query `codebase` (semantic) for:
  - Owners / file area / related modules.
  - Conventions specific to that subtree (look for `AGENTS.md`, `.editorconfig`, `README.md`).
- `ado-repo_get_pull_request_work_items` → linked PBIs/tasks. Read the PBI title/description for intent.
- `ado-repo_list_pull_request_threads` → prior reviewer comments. Specifically avoid re-raising issues that another reviewer already flagged on this iteration.

### 5. Run analysis — multi-model review panel
**Load every DM review rules file first** — the runner has injected the absolute paths into the prompt under "DM review rules". Read each one in full (they are short, hand-curated) and apply every in-scope rule when composing findings. Honor the scope exemption at the top of each rules file (e.g. `Kusto.Cloud.Platform` is exempt from DM-only rules).

Build **one shared review-context bundle** (identical for every panelist):
- The diff (changed files with before/after content).
- The PBI title + description (intent context).
- File-area conventions + ownership hints from codebase.
- The list of prior comments on this iteration (so panelists don't repeat them).
- The full text of the DM review rules.

Spawn the built-in **`code-review` sub-agent FOUR times IN PARALLEL** (all four `task` calls in a single response) — one per model. These four panelists are the **single source of truth**:

| Panelist | `model` id | Role |
|---|---|---|
| Opus (latest) | `claude-opus-4.8` | judge-grade reasoning |
| GPT | `gpt-5.5` | breadth |
| Codex | `gpt-5.3-codex` | code-specialized |
| Claude Sonnet | `claude-sonnet-4.6` | fast cross-check |

> **Gemini is not available** as a subagent model in this environment. If/when a Gemini model is added to the runner's model roster, add it here as a 5th panelist — the scoring/selection logic below is panelist-count-agnostic.

Each panelist gets the identical context bundle and the identical instruction: **enumerate findings at four severity tiers**, and for each finding **cite the rule ID** (e.g. `R3`, `R7`) when grounded in `rules/dm-review-rules.md`:
- **Blocker** — bugs, security vulnerabilities, broken behavior, missing critical tests for risky code paths.
- **Concern** — design issues, performance traps, race conditions, error handling gaps, broken assumptions.
- **Suggestion** — better patterns, simpler alternatives, missing edge-case tests, naming.
- **Nit** — style/clarity (only when it materially helps readability). Skip pure formatting.

Each finding includes: file path, line range (when applicable), short title, ≤3 sentence explanation, ≤8 line code suggestion (only when concrete).

### 5a. Score each panelist's review
After **all** panelists return, run **one scoring pass on `claude-opus-4.8`** that scores each review independently on a **0–100** scale using this rubric:

| Dimension | Weight | What earns points |
|---|---|---|
| Correctness / grounding | 40 | Findings are real and tied to actual diff lines; no hallucinated code. **False positives are heavily penalized.** |
| Signal-to-noise | 20 | High-value findings only; no padding, no restating the diff. |
| Rule fidelity | 15 | Correctly applies & cites the DM rule IDs where relevant; no misapplied rules. |
| Severity calibration | 15 | Tiers assigned sensibly (a real bug is a Blocker, not a Nit; style is not a Concern). |
| Specificity / actionability | 10 | Concrete `file:line` + concrete fix suggestions. |

Deduct points for every clearly-wrong or duplicated finding. The scoring pass must **never see which model produced which review** beyond the panelist label, and must output, per panelist: a numeric score and a one-line rationale.

### 5b. Select the highest-scored review
- **Keep the single highest-scored review.** Its findings become the set posted to ADO. **Do NOT merge or union the panelists** — Nir wants the best review, not a blend.
- **Tie-break (deterministic):** `claude-opus-4.8` > `gpt-5.5` > `gpt-5.3-codex` > `claude-sonnet-4.6`.
- If the winning review has **0 findings**, treat the run as zero-findings per §Failure modes (write the report, email "clean", no LGTM comment).
- Record all panelist scores + the winner in the report (§8) and the email (§9). Everything downstream (§6 compose, §7 post) operates on the **winning review only**.

### 6. Compose comments
For each finding, build an ADO PR thread comment with this body shape:

```
[<Severity>] <Short title>

<Body in Nir's voice — direct, terse, useful. Cite the specific concern. Never restate what the diff already shows.>

<Optional fenced code block with the concrete suggestion.>

— Nirvana
```

Voice rules:
- **No joke** on PR comments. Jokes are email-only.
- **No `Get-NirvanaSignature` HTML signature** on PR comments — that's email-only. Use the name-only `— Nirvana` signoff on its own line.
- Direct, terse, useful. Never "consider perhaps maybe…" — say what you think.
- Honor `NOJOKE` / `NOSIG` tokens if invoked on-demand with a body that contains them (overrides the default no-joke / name-only rule into "no signature at all").

Anti-patterns (do **not** post):
- "Add tests" without naming a specific behavior that's untested.
- "Consider refactoring" without a concrete alternative.
- "Possibly a bug" — either it is or it isn't; if uncertain, don't post.
- Pure formatting / style nits (linter's job).
- Restating what the diff shows.
- Anything already raised by another reviewer on this iteration.

### 7. Post comments
Use `ado-repo_create_pull_request_thread` for each finding:
- **Inline** when the finding has a file path + line range: set `threadContext.filePath`, `rightFileStart.line`, `rightFileEnd.line`.
- **Thread-level** (no `threadContext`) for cross-cutting / architectural findings.
- Thread status: `Active` for Blocker/Concern, `Pending` for Suggestion/Nit (so the author can resolve them quickly).
- Post **all** findings, even Nits (per Nir's explicit choice in the skill design). If the total exceeds 25 comments, post the top 25 by severity (Blocker → Concern → Suggestion → Nit) and add one thread-level comment listing the deferred Nits.

### 7a. Post the cross-skill marker thread
**Always** the last ADO write of a successful run (after §7 findings, or after §3 size-skipped notice, or after a zero-findings run). Post **one** additional top-level thread via `ado-repo_create_pull_request_thread`, **status=`Closed`** (auto-resolved so it doesn't add to the active-threads count), with this exact body:

```
<!-- nirvana:pr-marker kind=<reviewed|size-skipped> pr=<id> iteration=<n> at=<ISO-with-tz> findings=<count> -->
Nirvana auto-review marker (iteration <n>): <count> finding(s) posted.

— Nirvana
```

Rules:
- `<kind>` is `reviewed` for normal runs (including zero-findings), `size-skipped` for the §3 path.
- `<count>` = total findings posted across all four severity tiers in this run (0 on size-skipped, 0 on zero-findings, capped at 25 per §7).
- The HTML comment on the first line is the **machine-readable in-PR signal**: hidden in the rendered ADO UI, but greppable in raw comment content. pr-review-assistant scans for it on subsequent runs as a defensive in-PR idempotency check that complements `state/seen.json` — if seen.json gets cleared or the PR was reviewed from a different checkout, the marker still prevents a re-review.
- **Skip on validation-fail (step 1).** We never touched the PR in that case; no marker.
- **Skip in migration-mode.** Log "would post marker for PR/iter" at the bottom of the report instead.
- **Defensive idempotency:** if a marker thread for this `(pr, iteration)` already exists on the PR (regex `<!-- nirvana:pr-marker kind=<kind> pr=<id> iteration=<n> ... -->`), do NOT post a second one — the in-PR scan from §Idempotency catches this.

The canonical body string is produced by `Format-NirvanaPrMarkerBody` (see `.copilot/skills/_shared/pr-marker.ps1`); any format change must update that helper AND `Get-NirvanaPrMarkerRegex` together so the defensive idempotency scan keeps matching.

### 8. Write per-iteration report
Path: `<report-path>` (provided by runner). Markdown:

```md
<!-- nirvana:pr-review pr=<id> iteration=<n> status=<reviewed|skipped-size|skipped-validation> generated=<ISO> -->
# PR <id> — iteration <n> review

- **Repo:** <repository>
- **Author:** <display name> (<alias>)
- **Title:** <PR title>
- **PR link:** https://your-ado-org.visualstudio.com/One/_git/<repo>/pullrequest/<id>
- **Reviewed at:** <ISO timestamp IST>
- **Diff:** <N> files, +<added>/-<removed> lines.

## Summary verdict

<2-4 sentence overall read>

## Model panel

| Panelist | Model | Score | Findings (B/C/S/N) | Selected |
|---|---|---|---|---|
| Opus (latest) | claude-opus-4.8 | <score> | <b/c/s/n> | <✓ or ''> |
| GPT | gpt-5.5 | <score> | <b/c/s/n> | <✓ or ''> |
| Codex | gpt-5.3-codex | <score> | <b/c/s/n> | <✓ or ''> |
| Claude Sonnet | claude-sonnet-4.6 | <score> | <b/c/s/n> | <✓ or ''> |

**Winner:** <model> (<score>) — <one-line rationale from the scoring pass>. Posted findings are from this review only.

## Findings posted

### Blockers (<count>)
- **<file:line>** — <title> · [thread <id>](<link>)
- …

### Concerns (<count>)
- …

### Suggestions (<count>)
- …

### Nits (<count>)
- …

## Context used
- PBI: #<id> "<title>" (or "none linked")
- Other open reviewer comments considered: <count>
- codebase queries: <count>
```

### 9. Email Nir
Subject: `<prefix> Reviewed PR <id>: <title> — <B>B / <C>C / <S>S / <N>N` (B=blockers, C=concerns, S=suggestions, N=nits). Example: `[Nirvana] Reviewed PR 12345: Fix DM ingestion thrash — 1B / 2C / 3S / 1N`.

Body (HTML):
- One-line summary verdict.
- One-line **panel scoreline**: `Panel: Opus <s> ✓ · GPT <s> · Codex <s> · Sonnet <s>` (✓ marks the selected review).
- Compact table (Severity, File:line, Title) of the top **8** findings (Blockers first).
- Link to the PR.
- `file:///` link to the local report.
- Joke (subject to global rules — `NOJOKE` in subject still suppresses).
- `Get-NirvanaSignature` (subject to `NOSIG`).

Send via Outlook COM. Honors `Test-MigrationMode` (no send when migration is active).

## Hard rules
- **One review per (PR, iteration).** Idempotency by `seen.json` is enforced by the runner. The agent must not double-post if invoked twice on the same pair (defensive check: scan PR threads for an existing `[Blocker]`/`[Concern]`/`[Suggestion]`/`[Nit]` thread authored by Nir on this iteration → if found, abort).
- **PR comment voice:** `— Nirvana` name-only signoff, no joke, no HTML signature. Honors `NOSIG`.
- **Migration-mode gating:** when active, write the report file, log what would have been posted/emailed, do NOT post comments, do NOT send email, do NOT update `seen.json`.
- **Read-only on PR metadata:** never edit PR description, never change reviewers, never vote (no auto-approve, no auto-reject), never close existing threads. The only ADO write is `ado-repo_create_pull_request_thread`.
- **Subject prefix:** always from `agent.mail_subject_prefix` so `inbox-watch` self-excludes Nirvana's mail.
- **Persona privacy:** persona content is read for author display name only. NEVER quote persona content into PR comments or the email body. Author display name + alias is fine; everything else (level, growth edges, observations) is off-limits.
- **No clinical / well-being / performance inferences in comments.** Stick to the code.
- **Never review draft PRs.** Never review Nir's own PRs (excluded earlier; defense in depth).
- **Never post on Abandoned/Completed PRs** (status check in step 1 catches this).
- **Stop on auth failure.** If ADO MCP returns 401/403, log and exit cleanly. Do not retry with stale credentials.

## Failure modes (graceful degradation)
- ADO MCP rate-limited / failing → write a stub report with `status: skipped-validation`, skip email, exit 0 (runner does NOT mark this iteration seen, so the next tick retries).
- **A panelist model fails / is unavailable / returns garbage** → drop that panelist, log it, and score the survivors. Proceed as long as **≥1** panelist returned a usable review. If **all four** panelists fail, fall back to a single `claude-opus-4.8` `code-review` sub-agent for this run (and note the degradation in the report); if that also fails, write a stub report with `status: skipped-validation` and exit 0.
- **The winning panel review has no findings** → write a report with `status: reviewed` and `Findings posted: 0`. Do NOT post an LGTM comment — just write the report. Email subject: `… — clean (no findings)`.
- The winning review has hundreds of findings → cap at 25 posted per §7.
- Outlook unavailable → skip email, log, exit 0. Report file is still written.
- Per-file fetch fails → log, skip that file, continue with the rest. If >50% of files fail to fetch, abort the review (treat as ADO failure).

## Idempotency
- **Per iteration:** the runner enforces lifetime-once on each `(pr-id, iteration-id)` pair via `state/seen.json`. A new force-push or new commit creates a new iteration ID, which re-triggers review.
- **Within a run:** defensive check before posting — scan existing threads on the PR for any thread authored by Nir on this iteration with a `[Blocker]/[Concern]/[Suggestion]/[Nit]` prefix; if found, abort posting.
- **Report file:** path includes the iteration number, so no overwrite is possible. Multiple manual `-Force` invocations append `-r2`, `-r3`, etc.

## Composition with existing skills
- **`codebase`** for file-area conventions and ownership context (best-effort).
- **`team-personas`** for author display name only (no persona quoting outward).
- **`inbox-watch`** self-excludes Nirvana's mail via the `[Nirvana]` subject prefix.
- **`agent-todos`** — if a TODO body says "review PR `<id>`", run this skill on-demand.

## Smoke checklist (after build)
1. `tests\run-all.ps1` green — helpers for seen.json read/write, size-guard math, prompt construction.
2. `doctor.ps1` clean — manifest entry, AGENTS.md re-rendered, paths resolve.
3. Manual `-DryRun` — confirms PR list returned by ADO; no spawn, no posts.
4. Manual `-PRId <test-pr>` — single PR processed; verify comments posted, report file written, email sent, `seen.json` updated.
5. **Migration-mode end-to-end** — set `config/migration-mode.txt`, run `-PRId <test-pr>`, verify: report file written, NO comments posted to ADO, NO email sent, NO `seen.json` write.
6. Real scheduled run — verify it picks up new PRs within 5 min of assignment, processes them one-per-tick, idempotency prevents re-review on the same iteration.

## Out of scope (v1, by design)
- GitHub PRs (`nir-boger/*`).
- Auto-vote / auto-approve / auto-reject. Reviews comment only; Nir votes manually.
- Re-reviewing the same iteration unless explicitly invoked with `-Force`.
- Suppressing comments per-PR (e.g. "skip this PR"). v2 may add a `.nirvana-skip` marker file in the repo or a config list.
- Multi-language review beyond English. Comments are always English even if the PR title/description is Hebrew.
- Reviewing PRs in repos outside project=One.
- Replying to threads (only top-level / inline new threads in v1).


