# Skill: pbi-assign-tasks

## Purpose
For every PBI (Product Backlog Item) in the current sprint of **Your Team**, propagate the PBI's assignee to its child Tasks that are still unassigned. Do not change any task that already has an assignee.

## Fixed context
- Organization: `your-ado-org`, Project: `One`, Team: `Your Team`

## Rules
- **Scope:** child Tasks (and Bugs linked as children) of each PBI in the current iteration.
- **Source assignee:** the PBI's `System.AssignedTo`. If the PBI itself has no assignee, **skip the whole PBI**.
- **Target filter:** only update tasks where `System.AssignedTo` is empty/null.
- **State filter:** also skip tasks in state `Closed`, `Resolved`, `Done`, or `Removed` (nothing to assign on done work).
- **Never overwrite** an existing assignee.

## Steps

1. Get current iteration via `ado-work_list_team_iterations` (timeframe=current).
2. Get all work items in that iteration via `ado-wit_get_work_items_for_iteration`. Fetch fields `System.Id, System.WorkItemType, System.State, System.AssignedTo` via `ado-wit_get_work_items_batch_by_ids`.
3. Collect all items with `WorkItemType = "Product Backlog Item"`.
4. For each PBI:
   - If `AssignedTo` is empty → record "skipped (PBI unassigned)" and continue.
   - Fetch the PBI's children (relations) via `ado-wit_get_work_item` with `expand=relations`. Child links use `System.LinkTypes.Hierarchy-Forward`.
   - For each child work item that is a Task or Bug:
     - Read its current `AssignedTo` and `State`.
     - If state ∈ {Closed, Resolved, Done, Removed} → skip.
     - If `AssignedTo` is non-empty → skip.
     - Otherwise update via `ado-wit_update_work_item` setting `/fields/System.AssignedTo` to the PBI's assignee unique name (email).
5. Write a markdown summary to `<repo>\reports\pbi-assign\<YYYY-MM-DD_HHmm>.md`:
   - Per PBI: id, title, assignee, # children scanned, # updated, # skipped-already-assigned, # skipped-done.
   - Grand totals at the top.
6. Echo one-line summary to stdout: `PBI assign: updated <X> tasks across <Y> PBIs in sprint <name>`.

## What NOT to do
- Do not create, delete, or re-parent work items.
- Do not change any field other than `System.AssignedTo`.
- Do not overwrite an existing assignee under any circumstance.
- Do not prompt the user.

