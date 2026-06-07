# Skill: code-task

## Purpose
The standing playbook for when Nir assigns a **coding task** in the Azure-Kusto-Service repo and wants the change made **and** a pull request opened. This is the *write* counterpart to `codebase` (which is read-only): use `codebase` to find and understand the code, then this skill to change it, commit, push, and raise the PR.

Typical trigger: Nir pastes an ADO work-item link (or describes a change) and says something like "do it and create a PR", "make this change and open a PR", "work on this task", "I created a branch — go".

## When to use
Trigger phrases (case-insensitive, partial match OK):
- "create a PR", "open a PR", "make a PR", "raise a PR"
- "work on this task", "do this task", "implement this", "fix this and PR it"
- "I created a branch", "this is under kusto codebase ... create a PR"

If Nir only wants understanding/answers (no edits), that's `codebase`, not this skill.

## The one rule Nir cares about most
> **Every PR targets the `dev` branch by default — never `master` — unless Nir explicitly says otherwise.**

The repo's reported `defaultBranch` is `master`, so this is *not* the natural default; you must set the PR target to `refs/heads/dev` deliberately. Only target a different branch (`master`, a feature/integration branch, a release branch) when Nir names it in the request.

## Fixed context
- **Skill source of truth (methodology):** For any Kusto codebase work, investigation, or general/Kusto coding, **load the matching skill from `c:\dev\Azure-Kusto-Service\.github\skills\<name>\SKILL.md` first and follow it.** That product-repo folder is the authoritative method source — scan it before improvising (e.g. `sre-dm-*` for investigations, `ado-pipeline-kusto-analysis` for build/pipeline analysis, `kql-expert`/`kusto-tools-mcp` for queries, `client-package-version-bump` for version bumps, `skill-master` for skill authoring). This skill stays the write/PR entrypoint; those provide the how. (Per Nir, 2026-06-01.)
- **Repo (working checkout):** `c:\dev\Azure-Kusto-Service` — always operate from the canonical main checkout, never a worktree.
- **ADO coordinates:** project `One`, repo `Azure-Kusto-Service` (repo id `ee7cfdfd-1873-48e0-a9fe-d07a3f15fb12`). Use the `ado-repo_*` / `ado-wit_*` tools for PR + work-item operations.
- **Default PR target:** `refs/heads/dev` (see the rule above).
- **Commit trailer:** every commit ends with the standard `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>` line (unless Nir says not to).
- This is a *write* skill — it intentionally overrides `codebase`'s read-only default, but only for the specific change Nir asked for.

## Steps

### 1. Understand the task
- If given an ADO work item, read it (`ado-wit_get_work_item`) to extract the exact ask, the feature-flag/symbol name, area path, and any context in the description/attachments.
- Use `codebase` (grep / `git grep` / view) to locate **every** reference before changing anything. `git grep -n -I -i "<symbol>"` from the repo root is fast and complete on this huge repo (plain `grep`/ripgrep tooling tends to time out).

### 2. Branch
- Check the current branch: `git -C c:\dev\Azure-Kusto-Service branch --show-current`.
- If Nir already created a branch (common — he'll say so), **use it as-is**. Don't rename or rebase it.
- If no branch exists, create one off `dev` with a descriptive name, e.g. `user/<alias>/<short-description>`.

### 3. Make the change
- Surgical, complete edits that fully satisfy the ask. Follow the conventions of the surrounding code and neighbors (see `codebase` review notes + `BestPractices.md`).
- When removing a feature flag and "treating it as always true" (a recurring ask): delete the flag constant, the field, the FF read, **and** the conditional guard so the previously-flagged branch runs unconditionally. Then chase the now-unused plumbing (constructor params, call sites, test args) so nothing is left dangling. Re-run `git grep -i "<flag>"` until it returns zero hits.
- Privacy: **never** send Kusto source to any external system (email, Teams, web, sub-agents that may upload). PR descriptions on ADO are fine.

### 4. Verify
- Re-grep to confirm the change is complete and no stale references remain.
- Review the full diff (`git --no-pager diff`) before committing.
- Builds/tests are **heavy** — don't run them automatically. Offer to kick one off and let Nir decide.

### 5. Commit + push
- Commit with a clear subject + body explaining the *why*, reference the work item id, and include the `Co-authored-by` trailer.
- `git push -u origin <branch>`.

### 6. Create the PR
- `ado-repo_create_pull_request` with `targetRefName = refs/heads/dev` (the default rule), a descriptive title, the work item linked via `workItems`, and a description written **in Nir's voice, on his behalf** (the agent speaks for Nir).
- Compose the description from any framing Nir gave (who to address, the backstory, why the change is safe). Keep it informative: what changed, why, and any reviewer call-to-action.
- Add reviewers Nir names with `ado-repo_update_pull_request_reviewers` (resolve identities via `ado-core_get_identity_ids`; cross-check `team-personas` for the right person + alias).

### 7. Report back
- Give Nir the PR link, a one-line summary of the change, the reviewers added, and whether a build was run. Flag anything you deliberately skipped (e.g. "didn't run the build — say the word").

## Hard rules
- **`dev` is the default PR target.** Re-read the headline rule before every `create_pull_request` call.
- **Don't modify ADO work items** beyond linking them to the PR, unless Nir asks.
- **Don't leak source code externally.**
- **Don't auto-run heavy builds/tests** — offer first.
- **Stay in `c:\dev\Azure-Kusto-Service`**; don't wander into other repos unless asked.

## Cross-skill composition
- `codebase` — find/understand the code first (read-only).
- `team-personas` — get the right reviewer's identity, alias, and voice when addressing them in the PR description.
- `pr-review-assistant` — if Nir later asks to review a PR, that's a separate skill.

