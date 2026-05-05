# Skill: codebase

## Purpose
Make Nirvana fluent in the **Azure-Kusto-Service** codebase so it can:
1. **Answer questions** about architecture, where things live, how flows work ("where is X?", "how does Y work?", "what calls Z?").
2. **Onboard / refresh knowledge** by maintaining a small persistent **codebase map** that lists key directories, solution-filter (`.slnf`) groupings, hosts, services, and ownership cues.
3. **Review diffs / PRs** against codebase conventions when explicitly asked ("review this diff", "review PR ...").

DM-first when ambiguous (the user manages the **Your Team**), but the whole repo is in scope.

## Fixed context
- Repo root: `c:\dev\Azure-Kusto-Service`
- Primary language mix: C#, C++, Rust, TypeScript, PowerShell, Python
- Persistent knowledge map: `<repo>\.copilot\skills\codebase\codebase-map.md`
- Solution: `Kusto.sln` (huge); use `.slnf` solution-filter files for focused subsets.
  Notable filters: `DM.slnf`, `Engine.slnf`, `CM.slnf`, `CMRP.slnf`, `RP.slnf`, `GW.slnf`, `Clients.slnf`, `Bridge.slnf`, `ControlPlane.slnf`, `Trident.slnf`, `Copilot.slnf`, `kuiper.slnf`, `kusto-minimal.slnf`, `linux.slnf`, `NetCore.slnf`, `KCP.slnf`, `GrpcLoadTest.slnf`.
- Top-level dirs of interest: `Src/` (production code), `Test/` (tests), `Doc/`, `KE/` (Kusto Explorer), `KustoWebApps/`, `Tools/`, `.pipelines/`.

## Trigger → action mapping
| User intent | Action |
|---|---|
| "ask kusto …", "in the codebase …", "where is X", "where does X live", "how does Y work" | **Q&A mode** — answer using the persistent map first, then targeted `grep`/`view` in the repo. |
| "find the docs for X", "what's the command for X", "how do I X (operationally)", "find the doc about X" — or another skill calling in for an exact command/snippet | **Find-docs sub-mode** — see below. |
| "kusto codebase refresh", "rebuild the codebase map", "reindex kusto" | **Refresh mode** — regenerate `codebase-map.md` from current repo state. |
| "review this diff", "review PR <id>", "review my changes against the codebase" | **Review mode** — read the diff, then evaluate against repo conventions, neighbors, and `BestPractices.md`. |
| "kusto codebase" (alone) | Show a short summary of what the skill does + when the map was last refreshed. |

## Hard rules
- **Read-only by default.** This skill never writes to the Azure-Kusto-Service repo. No file edits, no commits, no PRs.
- **Stay inside `c:\dev\Azure-Kusto-Service`** when searching/reading code. Don't cross into other repos unless the user explicitly asks.
- **Don't dump raw code unless asked.** The user is a manager — give a high-level answer first (file paths + 1–3 sentence summary), then offer to drill in.
- **Don't share code externally.** Never include Kusto source in emails, Teams posts, web requests, or any 3rd-party tool. If the user asks to "email this answer", strip code blocks down to file paths + summaries.
- **No build/test runs** unless the user explicitly asks. The repo's builds are heavy.
- **Don't modify ADO work items** as part of this skill.

## Find-docs sub-mode — steps
Triggered when another skill (or the user) asks for an **exact command, recipe, or operational doc** rather than a code-architecture answer.

Search order (stop at first strong hit; don't fall back to the wider repo if a `Doc/` match is found):
1. **`Doc/InternalKusto/<area>/control-commands/*.md`** — DM/CM/engine control-command reference docs. This is the canonical home for `.process …`, `.show …`, `.alter …` operational commands. Common subareas:
   - `Doc/InternalKusto/dataManagement/control-commands/` — DM commands: dead-letter queue (`deadletterqueue-commands.md`), ingestion sources, EventHub diag, blob/storage management, settings.
   - `Doc/InternalKusto/clusterManagement/control-commands/` — CM commands.
   - `Doc/InternalKusto/engine/control-commands/` — engine commands.
2. **`Doc/InternalKusto/**/*.md`** — broader internal docs (concepts, engineering, KustoSRE, productionAccess).
3. **`Doc/DesignDocs/`** — for "why does this work this way" questions.
4. **`Doc/**/*.md`** — public/general docs.
5. **`*.md` repo-wide** (root: `README.md`, `BestPractices.md`, `Migrating-From-IngestV1-to-IngestV2.md`, etc.) — last resort.

How to search (keywords from the request):
```powershell
$root = 'c:\dev\Azure-Kusto-Service\Doc\InternalKusto'
Get-ChildItem $root -Recurse -Filter *.md | Select-String -Pattern 'dead.?letter|dlq|reprocess|importer' -List
```
Then `view` the top hits and extract the **exact command syntax** (preserve braces, quotes, case, parameter names — these are executed verbatim by humans).

Output format when invoked by another skill:
- **File path** (absolute) of the matched doc.
- **Exact command** in a fenced code block, copied verbatim.
- **One-line context** — what the command does, key parameters.
- (Optional) Caveats or related commands from the same doc.

Privacy: command syntax from internal docs is shareable inside Microsoft (the docs themselves are internal but the commands are routinely shared in tickets/emails to other Microsoft folks). Do **not** include surrounding source code, only the command itself + doc path reference.

## Q&A mode — steps
1. **Check the persistent map first** (`codebase-map.md`). If the answer is in there or it points to the right area, use it.
2. **Targeted search in the repo:**
   - Prefer `grep` with a `glob` filter (e.g., `*.cs`, `*.csproj`, `*.cpp`) over un-scoped searches.
   - For symbol lookups, search for `class X`, `interface IX`, `void X(` etc. with a language-appropriate glob.
   - For "where is feature X used?" — grep for the public type/method name in `Src/` first, then `Test/`.
   - For ownership / area routing — check `owners.txt`, `.azuredevops/`, and any `OWNERS`/`CODEOWNERS` files in the area.
3. **Compose the answer:**
   - Lead with a 1–3 sentence summary in plain English.
   - List the **2–5 most relevant files** with absolute paths and a one-line note for each.
   - If the question is architectural, add a short "how the pieces fit" paragraph.
   - End with: "Want me to dig into <specific file> or <related question>?"
4. **If the question is ambiguous**, ask one focused clarifying question before searching (e.g., "Do you mean ingestion in the engine, or in DM?").
5. **If you didn't find a confident answer**, say so explicitly; don't guess. Suggest the next probe (e.g., "I see references in `Src/DataManagement/...` but no clear entry point — want me to follow the call graph from `XController.cs`?").

## Refresh mode — steps
Regenerate `codebase-map.md` with the current state of the repo. Keep the map **small and scannable** (target < 400 lines). It is an *index*, not documentation.

Sections to include:
1. **Header** — last refreshed timestamp + repo HEAD commit (short SHA + subject).
2. **Top-level layout** — one line per top-level dir (purpose).
3. **Solution filters (`.slnf`)** — table of name → purpose → notable projects (max 5 each).
4. **Hosts / services** — entries under `Src/Hosts/` (one line each: name → what it runs).
5. **Production source areas** — for each significant `Src/` subdir, one line of purpose. Highlight DM-relevant ones with a `(DM)` tag.
6. **Test layout** — main test roots (`Test/UT`, `Test/E2E`, `Test/Kusto.DM.UT`, `Test/Kusto.DM.IntegrationTests`, perf, etc.).
7. **Build entry points** — list of `build-*.cmd` scripts at repo root with one-line purpose.
8. **Docs & conventions** — pointers to `README.md`, `BestPractices.md`, `CONTRIBUTING.md`, `Migrating-From-IngestV1-to-IngestV2.md`, `Doc/`, `Doc/DesignDocs/` (if present), `Doc/Diagrams/`.
9. **Ownership pointers** — `owners.txt`, any `.azuredevops/` config, plus a note on how to find area owners.
10. **Known gotchas** — short bullets the agent has learned (start empty; append over time).

How to gather:
- `Get-ChildItem` for directory listing (don't recurse beyond depth 2 for the map).
- Read `*.slnf` files at root to summarize their projects.
- Use `git -C c:\dev\Azure-Kusto-Service log -1 --pretty=format:"%h %s"` for HEAD.
- Don't include file contents — just paths and one-line purposes.

After writing, report: `Codebase map refreshed: <N> sections, <M> entries, HEAD <sha>.`

## Review mode — steps
1. Get the diff:
   - "review this diff" with no PR → run `git -C c:\dev\Azure-Kusto-Service diff` (and `--staged`) to capture local changes.
   - "review PR <id>" → use the ADO repo tools (`ado-repo_get_pull_request_changes`) against the matching repo in `your-ado-org/One`. Ask for the repo name if unclear.
2. For each changed file, look up its area in `codebase-map.md` and read **neighbor files** (same folder, related interfaces) to understand conventions before commenting.
3. Cross-check against `BestPractices.md` and any `*.editorconfig` / style files in the area.
4. Produce a review that prioritizes:
   - Correctness bugs and likely runtime failures
   - Threading/async/disposal issues (very common in this codebase)
   - Security / secret-handling
   - Public-API or wire-format breaks
   - Missing tests where neighbors have them
5. Keep the review short and high-signal. **Don't comment on style** unless it violates a documented rule.
6. **Never push, comment, or vote on the PR** — output the review to the user only. If they then ask "post these comments to the PR", that's a separate explicit action.

## Cross-skill: enrich `team-personas` from code activity
Whenever this skill touches code authored or reviewed by a known team member (see `<repo>\.copilot\skills\team-personas\people\`), opportunistically learn things about that person and **append a date-stamped line to their persona's `## Notes` section**. Trigger points:

- Reading a commit (`git log` / `ado-repo_search_commits`) — note recurring areas they own, code style tendencies (terse vs. verbose comments, test discipline, refactor patterns).
- Reviewing a PR (`review this diff` / `review PR <id>`) — note design choices, what kinds of feedback they tend to accept/push back on, complexity preferences.
- Exploring an area (`where is X`) — when ownership becomes obvious from history, record "primary maintainer of <area>" on that persona.

Rules:
- **Only factual, code-derived observations.** Anchor each note to a concrete artifact (commit SHA, PR id, file path).
- **Neutral framing.** No performance judgments. Prefer "tends to ship small focused PRs (e.g., PR 12345, 6789)" over "fast" or "slow".
- **Append, don't overwrite.** Use the format: `- 2026-04-29 (code): <observation> [src: PR 12345 / commit abc123 / file path]`.
- **Skip if no clear signal.** Don't invent personality from one PR.
- **Silent.** Don't tell the user every time you append a note; mention it only if the user asks "what did you learn?" or if you appended several notes in one session.
- **Never** put code-derived observations into outgoing messages (same privacy rule as the rest of `team-personas`).

If a code author has no persona file yet, do **not** auto-create one. Just leave the observation in-conversation; if Nir wants a persona created, he'll ask.


- Don't send Kusto source code to any external system (email, Teams, web search, sub-agents that may upload).
- Don't modify, commit, or push anything in `c:\dev\Azure-Kusto-Service`.
- Don't expand the map into prose docs — keep it an index.
- Don't auto-refresh the map on every Q&A call. Refresh only on explicit trigger, or if the map is missing / older than 30 days (mention it and ask before refreshing).

## First-run behavior
If `codebase-map.md` doesn't exist yet when a Q&A request comes in, do a one-time **bootstrap refresh** (Refresh mode) before answering, and tell the user "Built the initial codebase map, then answering your question…".


