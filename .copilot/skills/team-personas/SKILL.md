# Skill: team-personas

## Purpose
Give Nirvana persistent, per-person knowledge of the **Your Team** so it can:
1. **Answer "who is X" / "tell me about X"** — role, focus areas, working style, history, anything Nir has shared.
2. **Draft replies and outgoing messages** that are aware of the recipient's style, level, and context.
3. **Auto-enrich other skills** (`email-team`, `post-to-teams`, `codebase` reviews, sprint reports) with persona context when a known team member is the recipient or subject.
4. **Coach Nir on the human side** — surface each person's motivations, decision-making style, stress signals, and conflict patterns so Nir can adapt *how* he leads them, not just *what* he asks of them. The persona is a behavioral coaching map, not a clinical profile.

## Fixed context
- Team: **Your Team** (your-ado-org / One)
- Persona store (directs): `<repo>\.copilot\skills\team-personas\people\<alias>.md` — one file per direct report
- Contacts store (non-directs): `<repo>\.copilot\skills\team-personas\contacts\<alias>.md` — lightweight file per peer / partner-team / external person who shows up in Nir's world
- Team overview: `<repo>\.copilot\skills\team-personas\team-overview.md`
- **Ownership snapshot:** `<repo>\.copilot\skills\team-personas\ownership-snapshot.md` — who owns what across the team's Epics → Features → PBIs/Bugs → Tasks plus the active sprint. Hand-curated; refresh on triggers like *"refresh ownership snapshot"*, *"who's working on X"*, *"who owns Y"*, *"update the team ownership map"*. Refresh path: WIQL on Epics + Features under both DM area paths, then `wit_get_work_items_for_iteration` for the current iteration of `Your Team`, then sweep off-sprint actives for directs that don't appear in the sprint.
- **Upstream source A — Cowork raw persona drops.** A separate Copilot-in-M365 agent named **Cowork** drops **raw** per-person data under `C:\Users\youralias\OneDrive\YourAgent\Personas\<YYYY-MM-DD>\`. Two file formats are auto-detected by `run-personas-import.ps1`:
  - **JSON (current Cowork output)** — schema `{ format, person_file, capture_window_start, capture_window_end, content }` where `content` is a markdown blob with `## Teams Messages (N)` + `## Emails (N)` blocks containing verbatim quoted bodies. Filename convention is `PascalCase_Underscore.json` (e.g. `Asaf_Mahlev.json`, `Ran_BenShmuel.json`); the runner converts to kebab-case alias by splitting on underscore AND on CamelCase boundaries (so `Ran_BenShmuel` → `ran-ben-shmuel`). Hebrew is encoded as `\uXXXX` and decodes natively via `ConvertFrom-Json`. **Behavior:** mines behavioral quotes (Hebrew + English regex pool covering channel preferences, stated positions, boundary signals, pushback invites, after-hours apologies) + top email subjects, appends idempotent dated lines to `people/<alias>.md` ## Daily observations. Does **not** overwrite the persona template — Cowork is the collector, Nirvana is the analyst.
  - **Markdown (legacy / future synthesized drops)** — full persona template overwrite; preserves curated `## Notes`, `## Daily observations`, and `## Employment` (existing-first, dedupe; Employment block is preserved verbatim from existing file).

  Importer: `.copilot/skills/run-personas-import.ps1`, scheduled task `DM-PersonasImport`. The `.ps1` file has a UTF-8 BOM so Hebrew regex literals parse correctly. **Emails Nir a summary** at the end of each run that imported anything (or hit errors).
- **Upstream source B — Cowork daily summary.** Cowork also drops a daily JSON summary at `C:\Users\youralias\OneDrive\YourAgent\DailySummary\DailySummary_<YYYY-MM-DD>.json` covering the last 24h of Nir's email + Teams + ADO surface, including non-direct people (peers, partner-team folks, customers). Nirvana parses it, routes each person to the right store (directs → `people/`, others → `contacts/`), appends a `(daily)` line to their observations, then deletes the source JSON + companion `.md` stub. Importer: `.copilot/skills/run-daily-summary-import.ps1`, processed-state tracked in `<repo>\.copilot\skills\team-personas\daily-summary-state.txt`. **Emails Nir a summary** at the end of each run that touched anything.
- **Upstream source C — Live ADO signal (per direct, build-time only).** When refreshing or building a persona, Nirvana sweeps Azure DevOps for that direct's *current* engineering activity so the persona reflects what they're actually shipping — not just what shows up in mail/Teams. Goal: Nir should be able to read any persona and know what that person is working on this sprint, like he'd know if he were tracking it himself. For each direct, query (org `your-ado-org`, project `One`):
  - **Active + recently-merged PRs (last ~60 days)** authored by the direct — `repo_list_pull_requests_by_repo_or_project(created_by_user=<alias>@microsoft.com, project='One', status=All, top=50)`. Capture: PR ID, title, repo, status (Active/Completed/Abandoned/Draft), source/target branch (the `user/<alias>/...` source branch is itself a signal), creation + completion date, top reviewers. Use to anchor `## Strengths`, `## Recent Topics & Projects`, and `## Current focus`. (Project-wide query is fine — the team's PR volume is bounded; team-specific repo whitelist lives in `team-personas/ado-repos.txt` for cases where Nir wants to scope down. Currently seeded with `Azure-Kusto-Service` since that's where 100% of the DM team's recent PRs land — Nir can add more if/when the team starts shipping into other repos.)
  - **Current + previous iteration work items** assigned to the direct — `work_list_team_iterations(team='Your Team', timeframe='current')` then `wit_get_work_items_for_iteration` filtered to `[System.AssignedTo] = <displayName>`, plus a WIQL fallback for the previous iteration. Capture: work item ID, type (PBI / Bug / Task), title, parent Feature/PBI, state, sprint. Use to anchor `## Current focus`.
  - **Off-sprint active items** assigned to the direct — WIQL: `WHERE [System.AssignedTo] = <displayName> AND [System.State] IN ('Active','Committed','Approved','New') AND [System.IterationPath] NOT UNDER <current sprint path>`. Catches long-running off-sprint work (security tasks, OKRs, follow-ups).
  - **Ownership-snapshot anchor.** Read `team-personas/ownership-snapshot.md` (which already maps Epics → Features → PBIs/Bugs → Tasks → owner across the team) and use it to ground claims about what each direct *owns* at the Feature/Epic level — that's the longer-arc context the per-sprint ADO sweep can't see by itself.
  - **Privacy / scope.** Same rules as everything else in this skill — PR/WIT signal stays inside `team-personas/`, never quoted in outgoing messages, never shared with external sub-agents. Internal-only secrets in PR titles/descriptions (cluster connection strings, customer SAS tokens, ARM resource IDs not already public) are scrubbed before they land in the persona — capture the *shape* of the work, not the secret payload.
  - **Failure mode.** If ADO queries fail (rate-limit, auth, repo missing from `ado-repos.txt`), the refresh continues with Cowork-only data and emits a `[ADO sweep partial]` line in the runner summary email — so Nir can see which directs got the full treatment vs. which fell back to mail/Teams signal only. Never block a refresh on ADO availability.
- Both runners use the shared helper `.copilot/skills/_runner-email.ps1` to send the summary mail; subjects are `[Nirvana] <runner> - <stats>` and inbox-watch is configured to ignore that prefix.
- See `sources.txt` for the running history of both pipelines.
- Net effect: Cowork supplies the **raw signal**; Nirvana owns **synthesis, routing, and persistence**. Treat structured sections (Snapshot, Recent Topics, Communication Style, behavioral sections) as Nirvana-authored from raw input; `## Notes` and `## Daily observations` stay curated/append-only.

## Persona-building philosophy
Personas are a **coaching tool for Nir**, not a directory entry. Every persona Nirvana generates, refreshes, or appends to must aim to make Nir a better manager for that specific person:

1. **Real, not generic.** Capture human texture — the actual phrases they use, the emojis they reach for, the topics that energize them, the meetings they accept fastest. If a section reads like it could apply to any SWE, rewrite it or drop it.
2. **Strengths, anchored to evidence.** Each strength must trace to a concrete artifact (PR, email, chat, RCA, design doc). No "is a good engineer" boilerplate.
3. **Growth-oriented.** For every persona, identify where the person is **inside** their comfort zone (executing well, low risk) and where they're **at the edge** (where Nir can push). The goal is to give Nir a concrete next move to help them grow — a stretch task, a new audience, a missing skill — not a label.
4. **Their language.** Capture how they write: opening phrases, sign-offs, preferred channel, emoji vocabulary, code-switching (Hebrew↔English), level of detail. Nirvana mirrors this when drafting *for* them; Nir uses it to read between the lines when *they* write.
5. **Day-to-day, not snapshot.** Every meaningful signal Nirvana observes (emails sent/received, chat exchanges, PR/commit, ICM behavior, sprint estimation gap) should append a date-stamped line to the persona's `## Daily observations` log. A persona is a slowly-growing record, not a once-a-quarter rewrite.
6. **Coaching-grade, not HR-grade.** Note tendencies and patterns; never write performance verdicts. "Has only led incident response within DM, not yet across teams" is fine; "doesn't lead" is not.
7. **Behavioral, not clinical.** Capture *observable* patterns — how they react under pressure, what energizes vs. drains them, how they push back, how they prefer recognition, what their early stress signals look like. Anchor every behavioral observation to artifacts (a specific message, chat, incident, meeting). **Never** use clinical / diagnostic labels (anxious, narcissistic, on the spectrum, depressed, ADHD, neurotic, etc.) or armchair-psychology hypotheses about *why* they behave that way beyond what they themselves have told Nir. The goal is for Nir to predict reactions and adapt his approach — not to diagnose, label, or manipulate.
8. **Behavioral hypotheses are OK if labeled.** When a pattern is suggestive but not yet confirmed (e.g., "seems to lose energy when scope is fuzzy"), prefix with `Hypothesis:` and tie it to ≥2 dated observations. Promote to a regular bullet only after a third independent confirmation. Drop it if a counter-signal appears.

These principles override the "minimum viable section" tendency — prefer one rich, evidence-backed line over five generic ones.

## Trigger → action mapping
| User intent | Action |
|---|---|
| "who is X", "tell me about X", "what does X do" | **Lookup mode** — load `people/<alias>.md`, give a 3–6 line summary, offer to drill in. |
| "use persona for X", "persona X", "load X's persona" | **Load mode** — pull the full persona into context for the rest of the conversation. |
| "draft reply to X about …", "write to X …" | **Draft mode** — compose the message using the persona's style/level. Routed through `email-team` or `post-to-teams` for actual sending. |
| "rebuild personas", "refresh personas", "reindex personas" | **Refresh mode** — re-parse the source files at the configured source path and regenerate `people/*.md` + `team-overview.md`. |
| "team-personas" alone | Show: source path, # of personas, last refresh date. |

## Cross-cutting auto-enrichment (other skills)
Whenever another Nirvana skill is composing text **for or about** a known team member (subject is a person; To/Cc contains a known alias; review of a PR authored by a known alias), Nirvana **silently** pulls that person's `people/<alias>.md` into context before drafting.

- Apply to: `email-team`, `post-to-teams`, `agent-todos`, `codebase` review mode, and `sprint-report-daily` when calling out individuals.
- **Do not** mention the persona file to the recipient. Persona context shapes tone/wording only — it is never quoted, attached, or referenced in outgoing messages.
- If multiple recipients have personas, blend tone toward the highest-context recipient and stay neutral overall.

## Hard rules — privacy & safety
- **Personas are private notes.** Never include persona content (verbatim or paraphrased) in any outgoing email, Teams post, ADO comment, web request, sub-agent prompt that may upload, or file outside `.copilot/skills/team-personas/`.
- **Never share persona files externally** — no attachments, no copy/paste into chat tools, no commits to non-Nirvana repos.
- **No sensitive personal info.** Don't record health data, family details Nir didn't volunteer, performance/HR judgments, or anything that would embarrass the person if they read it. If Nir dictates something risky, store it but flag it: "Stored under `risk:` — visible only here. Want me to keep or drop it?"
- **No clinical or diagnostic language.** Never label anyone with mental-health terms (anxious, depressed, ADHD, on the spectrum, narcissistic, neurotic, etc.) or armchair psychiatric framing. Describe *behavior* and *patterns* anchored to artifacts, not internal states. If Nir uses such a term in conversation, paraphrase neutrally (e.g., "Nir noted on <date> that <person> seemed under more stress than usual after <trigger>").
- **No manipulation.** Behavioral observations exist so Nir can adapt *his own* approach (timing, channel, framing, support). They must never be used to pressure, exploit, or steer the recipient against their interest. If a draft starts to read as exploiting a known soft spot — stop and reframe.
- **The persona reads safely if the subject saw it.** Final filter on every persona line: if this person opened their own file, would it feel like a fair, respectful coaching note from a manager who's paying attention? If not, rewrite or drop.
- **Read/write only inside** `<repo>\.copilot\skills\team-personas\`.
- **No ADO writes** as part of this skill.
- The persona is used to **shape Nirvana's wording**, not to manipulate the recipient. No psychological-pressure tactics, no exploiting weaknesses.

## Persona file shape (`people/<alias>.md`)
Use this template when generating/refreshing. All sections optional — omit empty ones.

```md
# <Display Name> (<alias>)

- **Role:** <e.g., Senior SDE, EM, PM>
- **Area / focus:** <DM ingest, EventHub connector, perf, etc.>
- **Reports to / works with:** <names>
- **Aliases / handles:** <ADO alias, GitHub, email if non-obvious>
- **Last refreshed:** <YYYY-MM-DD>

## Employment
<Manager-curated HR-style facts. Manually maintained by Nir; preserved across Cowork refreshes by `run-personas-import.ps1`. Use `—` for unknown/N/A.>
- **Birthday:** <D/M, year optional>
- **Gender:** <Male | Female | — for unknown/unspecified. Used for correct Hebrew grammar (זכר/נקבה) in WhatsApp/email drafts.>
- **Hired:** <YYYY-MM-DD — first day at Microsoft, including pre-FTE roles>
- **FTE since:** <YYYY-MM-DD if converted from intern/vendor/student, otherwise omit or use same as Hired>
- **Level:** <e.g., 60-66, Intern, Senior, Principal>
- **Last promotion:** <YYYY-MM-DD or —>

## Background
<2–4 lines: tenure, prior roles, things Nir has shared>

## Voice rules
<Optional. Per-person tone/emoji/language directives that any Nirvana skill talking *to* this person must honor. One bullet per rule, format: `<token/signal> — <when / when not>`. Examples: "🔥 emoji — one or two per upbeat reply, skip on incidents/performance" / "Hebrew OK in 1:1, English in group threads" / "≤4 lines, no preamble". Skills must read this section instead of hardcoding per-person rules.>

## Working style
<How they communicate: terse vs. verbose, async vs. sync, formality, English level, timezone>

## Language & writing patterns
<How *they* write — the texture Nir uses to read between the lines and Nirvana mirrors when drafting for them. Capture, with examples + dates wherever possible:>
- **Opening / closing phrases** — e.g., "היי מה נשמע?", "Hey [name]", "Thanks, <name>".
- **Emoji vocabulary** — which emojis they actually use and in what register (1:1 vs. group). e.g., "🤰🏽 / 😊 in 1:1 with Nir; none in group threads".
- **Signature phrases / verbal tics** — "Looking", "Ack", "Will look", "I think we should…", "rough draft, still iterating".
- **Code-switching** — when they switch between Hebrew and English (channel? audience? topic?).
- **Detail level** — terse one-liners vs. structured bullets vs. long-form RCA.
- **Humor / register** — dry, self-deprecating, formal, none.

## Strengths
<bulleted, each anchored to a concrete artifact (PR / email / commit / chat / incident with date)>

## Comfort zone
<What they own confidently and execute reliably — their "home turf". Be specific: areas, scopes, audiences, types of work. This is the baseline Nir doesn't need to coach on.>

## Growth edge & stretch opportunities
<The other half of the coaching map: where they're at the boundary of their comfort zone, and concrete moves Nir can make to help them grow. Format each as:>
- **Edge:** <observation, anchored to evidence — e.g., "has driven DM-internal incidents end-to-end but hasn't yet led a cross-team RCA with Eventstream / Aria SDK">
  - **Stretch:** <concrete next move Nir could offer — e.g., "next cross-team incident, ask them to own the writeup and the partner-team comms; offer to review pre-send">
  - **Risk if pushed too far:** <where the support net needs to be — e.g., "first cross-team thread, do a 15-min pre-call; don't drop them cold">

## Watch-outs
<Things to be mindful of when writing *to* them — friction signals, sensitivities, recurring blockers (provisioning, access, leave). Keep neutral and respectful.>

## Current focus
<What they're working on this sprint / quarter, if known>

## Motivations & drivers
<What energizes this person and what drains them. Use the lens that fits — common drivers include: mastery / craft, autonomy, impact / scope, recognition, growth / learning, belonging / team, security / stability, ownership. Anchor to evidence wherever possible.>
- **Energized by:** <e.g., "owning a horizontal migration end-to-end (msg_134, 2026-03-30)"; "AI tooling experiments with Nir (chat 2026-04-29)">
- **Drained by:** <e.g., "stalled threads waiting on other teams (msg_140 'kind ping', msg_136)"; "ambiguous scope without a decision-maker">
- **What 'a good week' looks like for them:** <one line, behavioral — not a status update>

## Behavioral patterns
<Concrete, observable reactions in recurring situations. Each line: situation → observed behavior → artifact. Prefer specific verbs over adjectives.>
- **Under pressure / live incident:** <e.g., "acks fast in chat, then returns with a written RCA within 24h (msg_262, msg_267, msg_271)">
- **When blocked / waiting:** <e.g., "polite escalating pings every 2-3 days, tags Nir for a directional call (msg_140, msg_138)">
- **When challenged / disagreed with:** <e.g., "engages on the technical merits, doesn't take it personally; asks for the counter-data (msg_271)">
- **When praised / recognized:** <e.g., "deflects with humor ('Amazing, now ask it to fix it ;)' msg_255)" / "warms up, opens follow-up thread the next day">
- **When uncertain:** <e.g., "asks for a 15-min sync rather than guessing (msg_253, 2026-02-18)">
- **When delegating / handing off:** <e.g., "writes structured handoff with ops ticket, alias updates, doc links (msg_252)">

> Mark unconfirmed patterns with `Hypothesis:` and require ≥2 dated observations; promote after a third confirmation. Drop on counter-signal.

## Decision-making style
<How they get from problem to decision. Pick the dominant mode(s) — they're not exclusive.>
- **Mode:** <data-driven / consensus-seeking / decisive / deliberative / experiment-first / risk-averse / risk-tolerant>
- **Speed:** <fast and revisits / slow and committed / waits for one more data point>
- **Who they pull in:** <names of usual sounding boards>
- **What unblocks them:** <e.g., "a one-line directional answer from Nir", "a written counter-proposal to react to">

## Conflict & disagreement style
<How disagreement actually shows up — important for Nir to read pushback correctly.>
- **Default register:** <direct / collaborative / avoidant / escalator-when-stuck / probing-questions>
- **How pushback sounds from them:** <e.g., "'I think we should...' = mild disagreement"; "switches to English mid-Hebrew thread = wants it on record">
- **Recovery pattern after a hard conversation:** <e.g., "back to normal next chat, no residue" / "needs a 1:1 to reset" / "goes quiet for ~24h then re-engages">

## Recognition & feedback preferences
<How they like to be seen and corrected.>
- **Recognition:** <public Teams shout-out / 1:1 only / written kudos / skip-level mention / peer-visible PR comment>
- **Critical feedback:** <direct in 1:1 / written first then talk / sandwich not needed / explicit examples required>
- **Frequency:** <prefers steady drip / annual / situational only>

## Stress & friction signals
<Early warning signs — what changes first when they're under load. Helps Nir notice before things escalate.>
- **Voice / tone shifts:** <e.g., "drops emojis", "switches from Hebrew to English", "replies turn one-line">
- **Rhythm shifts:** <e.g., "goes silent in standup", "skips optional meetings", "stops opening new threads">
- **Channel shifts:** <e.g., "moves to email when normally on chat", "starts CC'ing Nir on routine items">
- **What helps:** <e.g., "explicit 'park it for now' from Nir", "a 15-min unstructured 1:1", "removing one item from the plate">

## Trust & psychological safety signals
<What makes this person open up vs. close. Used to calibrate how candid Nirvana / Nir can be in a given moment.>
- **Opens up when:** <e.g., "1:1 in Hebrew, no agenda", "shared frustration about a partner team">
- **Closes when:** <e.g., "feels graded", "feels like a topic will reach skip-level without warning">
- **Topics they bring up themselves:** <signals they trust Nir on these — e.g., career, comp, family logistics, peer friction>

## How to write to them
<Concrete tone guidance: 1–3 bullets. e.g., "lead with the ask", "use bullet points", "Hebrew OK in 1:1s but English in group threads">

## Notes
<Anything else Nir has told me. Date-stamped lines preferred:>
- 2026-04-29: <observation / note>

## Daily observations
<Append-only running log of small day-to-day signals Nirvana picks up — one line per signal, never overwrite. Same artifact-anchored format as code-derived notes. Used to grow the persona slowly over time; promote recurring patterns into Strengths / Growth edge during the next refresh.>
- YYYY-MM-DD (signal): <observation> [src: <email msg_id / chat id / PR / commit / meeting>]

## Sources
<Files this persona was built from, with line refs if useful>
```

## Refresh mode — steps
1. Read `sources.txt` in this skill folder for the configured source path. If missing or empty, ask Nir for the path and write it to `sources.txt`.
2. Enumerate source files (Cowork drops are typically `.md`, one per persona; format may vary). Read them.
3. **Sweep ADO live signal per direct (Source C).** For each direct in the roster, run the four queries described in §Source C (active+recent PRs, current+previous iteration work items, off-sprint actives, ownership-snapshot anchor). Cache the results in-memory for the rest of this refresh; do **not** persist the raw ADO payload to disk. Use `team-personas/ado-repos.txt` as the optional repo whitelist; if the file is missing or empty, fall back to a project-wide PR query (`project='One'`) and warn in the summary mail.
4. For each person mentioned (Cowork) **and** each direct with non-empty ADO signal:
   - Pick a stable alias (prefer their ADO/MS alias; fallback to first-name-lowercased).
   - Generate / update `people/<alias>.md` using the template above.
   - **Weave ADO signal into the structured sections** — anchor `## Strengths` and `## Recent Topics & Projects` bullets to PR IDs / work item IDs (format: `[src: PR 1234567 / WIT 9876543]`). Populate `## Current focus` with the in-flight + current-sprint items. Use the ownership-snapshot to phrase Feature/Epic-level ownership claims.
   - **Preserve `## Notes` and `## Daily observations`** unconditionally — append, never overwrite. This is where Nir's hand-curated lines, `(code):` / `(ado):` enrichment, and the day-to-day signal log live; Cowork and the ADO sweep don't author them.
   - **Promote** patterns: when ≥3 daily observations point at the same trait (e.g., consistent emoji use, recurring growth edge, repeated PR-review pattern), surface it in the appropriate structured section (Strengths / Language & writing patterns / Comfort zone / Growth edge) — but keep the raw observations intact.
5. Regenerate `team-overview.md`: a single table with `alias | display name | role | focus | file`, plus a short "team shape" paragraph.
6. Report: `Refreshed N personas from <source path>. Added: a, b. Updated: c, d. Unchanged: e. ADO sweep: full=X, partial=Y, skipped=Z.`

## Lookup / Draft mode — steps
1. **Resolve the person.** Match the user's reference (display name, first name, alias, email) to a `people/<alias>.md`. If multiple matches, ask once which one.
2. **Lookup:** read the persona, give a 3–6 line summary covering role, focus, working style, current focus. End with: "Want the full notes or to draft something?"
3. **Draft:** compose the message in Nirvana's normal voice but tuned to the persona's preferences (length, formality, language, structure). Show a preview before any sending skill (`email-team` / `post-to-teams`) is invoked.
4. **Add new info on the fly:** if the user says "remember that <X>" or "add to <person>'s notes: <…>", append a date-stamped line to that persona's `## Notes` section. Confirm: `Noted on <name>'s persona.`

## Code-derived enrichment (driven by `codebase`)
The `codebase` skill is authorized to **append** to `people/<alias>.md` `## Daily observations` when it observes concrete signals from commits / PRs / code review of a known team member.

- Notes must be factual, neutral, and anchored to an artifact (commit SHA, PR id, file path).
- Format: `- YYYY-MM-DD (code): <observation> [src: PR 12345 / commit abc123 / path]`.
- Append-only — never overwrite earlier notes.
- Code-derived observations are still subject to the privacy rules above: they never appear in outgoing messages.

## Cross-skill enrichment (day-to-day learning loop)
Other Nirvana skills are authorized to **append** to `## Daily observations` when they observe a concrete, evidence-anchored signal about a known team member. Same append-only, artifact-anchored rules as code-derived enrichment.

- `inbox-watch` — sender phrasing, opening/closing patterns, emoji use, escalation tone, channel switches, response latency. Tag `(inbox)`.
- `email-team` / `agent-todos` (reply-mode) — when drafting *to* a person and the live thread shows a new pattern (e.g., they're asking for review pre-send, switching language mid-thread). Tag `(email)`.
- `sprint-report-daily` — commitment behavior, reaction to mid-sprint scope shifts, follow-through on assigned items. Tag `(sprint)`.
- `post-to-teams` — observed reactions / chat replies after a team-wide post. Tag `(teams)`.
- ADO sweep (any skill that runs WIQL / PR-list queries on a direct's behalf) — newly-opened PRs, completed PRs, work items just assigned, items just resolved, scope changes, churn patterns. Tag `(ado)`. Distinct from `(code)`, which is reserved for the `codebase` review/diff path. Format: `- YYYY-MM-DD (ado): <observation> [src: PR 1234567 / WIT 9876543 / iteration <name>]`.
- **Behavioral signals** (any skill, e.g., a stress-shift in tone, a pushback in a 1:1 chat, a change in cadence) — append with the `(behavioral)` tag in addition to the source-skill tag. Format: `- YYYY-MM-DD (behavioral, inbox): <neutral observation> [src: ...]`.

All other writes to persona files still require an explicit user instruction. During a `refresh` (`rebuild personas`), Nirvana **promotes** recurring patterns from `## Daily observations` into the structured sections — including the new behavioral sections (Motivations & drivers, Behavioral patterns, Decision-making style, Conflict & disagreement style, Recognition & feedback preferences, Stress & friction signals, Trust & psychological safety signals) — but keeps the raw daily log intact for traceability. Promotion thresholds:
- ≥3 dated observations of the same pattern → promote to a regular bullet in the matching section.
- 2 dated observations → keep in daily log, optionally surface as a `Hypothesis:` line.
- 1 observation → daily log only.
- A counter-signal (one clear contradicting observation) → keep both in the daily log, downgrade any promoted bullet back to `Hypothesis:` until reconfirmed.


- Don't paste persona content into outgoing messages.
- Don't share persona files with sub-agents that may upload context to external services unless the sub-agent is local and trusted (the built-in code/general-purpose agents are fine).
- Don't store HR-grade judgments ("low performer", "should be PIP'd"). If Nir says something like that, paraphrase neutrally ("Nir flagged a recent delivery concern on <date>").
- Don't refresh personas without explicit trigger. Stale notes are better than auto-rewrites that lose Nir's nuances.

## First-run behavior
- If `sources.txt` is missing → ask Nir once for the path, write it, then run a refresh.
- If `sources.txt` exists but `people/` is empty → run a refresh on first lookup/draft request, then proceed.
- If a persona is requested for someone with no file → say so plainly, offer to either (a) build one from the source files now, or (b) start a stub from what Nir tells me in this conversation.

## Contacts (non-directs)
Non-direct people who show up in Nir's daily surface — peers, peer managers, partner-team engineers, customers, external folks, leadership outside the immediate org — get a **lightweight** file at `contacts/<alias>.md`. Same alias convention as `people/` (kebab-case `firstname-lastname`).

The contacts file is intentionally smaller than a full persona because Nir doesn't manage these people; the goal is to remember **context** for when their name comes up again, not to build a coaching map.

```md
# <Display Name> (<alias>)

- **Role / org:** <e.g., "Microsoft, Senior SDE on Eventstream"; "Customer (LTIMINDTREE)">
- **Relationship to Nir:** <peer manager / partner team / customer / external / unknown>
- **First seen:** <YYYY-MM-DD>
- **Last seen:** <YYYY-MM-DD>
- **Last refreshed:** <YYYY-MM-DD>

## Snapshot
<2–4 lines: who they are, why they show up in Nir's world, what they tend to interact on>

## Recent interactions
<Append-only log; one line per signal. Same artifact-anchored format as personas' Daily observations, with `(daily)` tag for daily-summary-derived lines.>
- YYYY-MM-DD (daily): <neutral observation> [src: DailySummary_<date>.json]

## Notes
<Anything Nir has told me explicitly. Date-stamped lines preferred.>
```

Rules:
- **Append-only** for `## Recent interactions` and `## Notes`.
- **Promotion to direct persona:** if Nir says "X joined my team" or "X is now my direct", move `contacts/<alias>.md` to `people/<alias>.md` and Nirvana grows the file into the full persona template at the next refresh.
- **No behavioral coaching map** for contacts (no Motivations & drivers, Behavioral patterns, etc.) — those sections require sustained 1:1 signal that Nir doesn't have for non-directs.
- **Same privacy rules** as personas: never quote contact files in outgoing messages, no clinical labels, no manipulation framing.
- **Cleanup:** contacts that haven't been seen in >180 days can be archived under `contacts/_archive/` during a refresh. Don't delete — Nir may reference them later.

## Daily summary ingestion
Cowork drops a daily JSON at `C:\Users\youralias\OneDrive\YourAgent\DailySummary\DailySummary_<YYYY-MM-DD>.json`. Schema:

```json
{ "date": "YYYY-MM-DD", "owner": "Your Name", "format": "markdown", "content": "<markdown blob>" }
```

The markdown blob has these sections relevant to persona enrichment:
- **Top-Level Overview** — themes of the day, urgent items.
- **By Person** — `### <Display Name> — <Title / Org>` subsections, each with channel, time, bullet points of what happened, and a "Discussion topic" line.
- **Teams Channels / Group Chats Activity** — short bullets, may mention people in passing.

Importer (`run-daily-summary-import.ps1`, processed state in `daily-summary-state.txt`) does:

1. Find unprocessed `DailySummary_<date>.json` files in `Nirvana\DailySummary\`.
2. Parse the markdown content; extract every `### <Name> — ...` block under `## By Person`.
3. **Skip bots** by name pattern: `kopsMI`, `GitOps`, `Microsoft Security`, `Azure User Access Review`, `Incident Automation`, `Workflows`, `(bot)`, `Auto-restart`, `automation`, `service account`. Also skip distribution-list-style entries.
4. **Resolve alias** for each remaining person: kebab-case the display name (`Vincent-Philippe Lauzon` → `vincent-philippe-lauzon`).
   - If `people/<alias>.md` exists → it's a direct → append `(daily)` line to its `## Daily observations`.
   - Else → it's a contact → create or update `contacts/<alias>.md` (use the contact template above), append to `## Recent interactions`.
5. **Observation format:**
   `- YYYY-MM-DD (daily): <one-line summary derived from the bullets, neutral, factual> [src: DailySummary_<date>.json]`
   Keep it terse: prefer the "Discussion topic" line + the most signal-bearing bullet. Drop bot noise. Don't speculate.
6. **Behavioral signal extraction** (best-effort): when the bullets contain a clear behavioral signal for a direct (e.g., "Initiated conversation Friday morning ('Hi', 'Sorry to bother you on a Friday')" → social-aware; "Preference: phone calls beat Teams messages" → channel preference), append a separate line tagged `(behavioral, daily)` per the cross-skill enrichment rules. Apply only to directs (we don't build behavioral maps for contacts).
7. **Mark processed and clean up:** append the date to `daily-summary-state.txt`, then delete the source JSON (and the companion `DailySummary_<date>.md` stub if present) from `Nirvana\DailySummary\`. The state file is kept as a belt-and-suspenders idempotency guard if OneDrive ever re-pulls the file.
8. **Log** to `reports/logs/daily-summary-import-<YYYY-MM-DD>.log` and append a one-line summary to `sources.txt`.
9. **Email Nir a short summary** at the end of every run that processed at least one JSON file (or hit errors). Subject prefixed `[Nirvana]` so `inbox-watch` ignores it. Body lists dates processed, directs touched (with names), behavioral signal count, contacts touched / created, bot count, and a short joke per Nir's email-voice preference. Uses `_runner-email.ps1` helper.

Manual usage: `powershell -File <repo>\.copilot\skills\run-daily-summary-import.ps1`

Failure modes:
- Missing JSON → no-op, exit 0.
- Schema drift (no `content` field, content not markdown, no `## By Person`) → log a clear error, do **not** mark processed; exit 0 so the scheduler keeps retrying tomorrow.
- Person matches multiple aliases → log warning, route to the longest-match alias; do not silently pick wrong.


