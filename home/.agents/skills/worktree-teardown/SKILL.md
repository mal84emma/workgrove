---
name: worktree-teardown
description: Safely remove task worktrees and their branches, and clean up finished ones. Use when the user asks to remove/delete/clean up a worktree or task, tear down finished work, or free up merged branches.
---

# Tear down worktrees

Use this skill to remove task worktrees and their branches.
Read and follow the [removal rules](../../../.claude/TASKS.md#worktree-rules)
and the [GitHub write policy](../../../.claude/AGENTS.md#github-writes-and-publishing).

## Check for a live agent first

Before you remove a worktree, check if an agent is still running in it.
A running agent blocks the removal, with one exception: the agent inside that worktree may remove it when it carries out the user's teardown request.

```bash
wt show <name>                       # row:, dirty files, commits vs base (wt rm checks the pushed state; wt show does not show it)
wt -H <vm> show -r <repo> <name>     # VM: also "session: wt-<repo>-<name> (agent running|shell only|none)",
                                     # with ", detached" appended when no tmux client is attached
```

- If another agent is still running in the worktree, do not remove the worktree. Ask the user to finish or stop that agent first.
- Your own session may remove its worktree when the user asks.
- `wt rm` checks the row or tmux session before removal and refuses another running agent, even with `wt rm --force`.
- If `wt rm` cannot verify the row or session status, it keeps the worktree.

## Commands

```bash
wt rm <name>                         # removes the worktree, its wt/<name> branch, the sidecar and the cmux row
wt rm <name> --keep-branch           # removes the directory, but keeps the branch for later
wt rm <name> --force                 # discards uncommitted or unmerged work (destructive; only when asked)
wt rm <name> --discard-commits       # discards only the branch's commits and keeps every other check (only when asked)
wt -H <vm> rm -r <repo> <name>       # the same on a VM: worktree, branch, row, then its tmux session
wt prune --dry-run                   # lists worktrees whose branch is merged into the base and whose tree is clean
wt prune                             # removes those worktrees
```

## Removing your own worktree

**Warning:** `wt rm` removes your own cmux row, and that ends this agent session. Give the user the summary in step 2 **before** you run the command in step 4.

Do these steps in this order:

1. Inspect the worktree with `wt show <name>`. Read its metadata with `wt show <name> --json`.
2. Tell the user the branch, the commits, the test results, and what the command will remove.
3. Take the absolute repository path from the JSON `repo` field (`jq -r '.repo'`).
4. Run the command below as one shell command, so that `wt rm` starts from that main checkout.

```bash
cd <absolute-repo-path> && wt rm <name> -r <absolute-repo-path>
```

This change of directory is the exception to the stay-inside rule of `worktree-work`. Do no task edits in the main checkout.

If Codex runs in a sandbox, run the teardown command with escalation.
The sandbox can block the cmux and tmux sockets even after you change directories.
`wt rm` refuses sandboxed removal before it deletes the worktree, so you can retry with escalation.

`wt rm` verifies local ownership through cmux process attribution and operating-system process ancestry.
Inherited cmux caller variables do not prove ownership.
Unknown ownership keeps the worktree and reports the uncertainty.
New local Codex launches use `--no-daemon` to keep their runtime in the task process tree.
Older shared-server sessions can require a task-owned restart before teardown.
Never replace their caller variables with guessed row identifiers.

`wt rm` uses cmux's `--force` only for the verified caller's own row.
That flag skips cmux's running-process confirmation. It does not discard Git work or waive `wt rm` safety checks.
If Claude's automatic approval review rejects self-removal, report the rejection and leave the task intact.
If `wt rm` refuses for another reason, the row stays open. Report the reason and leave the worktree.
If row closure fails after removal, report that Git cleanup succeeded and session cleanup remains pending.
Retry the same `wt rm` command with escalation when needed.
The receipt under `<repo>/.git/wt/teardown/` retains the remaining cleanup operation.
A completed receipt makes repeated removal harmless.

### On a VM

Run that command on the VM, not through `wt -H`.
For native cmux rows, `wt rm` stops its own tmux session after removal.
That row runs the tmux client directly, so the terminal exits and its Mac row closes.
If `wt rm` reports that a native row predates this change, it keeps the worktree and prints an attach command.
Close that row on the Mac, run the attach command, then retry self-removal.

For older cmux rows, `wt` asks the Mac hook to close the row and then stop its tmux session.
Closing the row and stopping the session can cut off the tool call or the agent, so give the user the summary first.

For these older rows, `wt rm` waits for the Mac hook.
If the session stays active after that wait, the cleanup is incomplete.
The `removed` message confirms only worktree removal.
In this case, report its warning and cleanup receipt.
The command returns a failure status when the hook does not finish cleanup.
Retry from the same session or inspect the named row and tmux session from the Mac.
Do not close another running agent during recovery.

## Safety contract (enforced by `wt rm`, exit code 3 on refusal)

`wt rm` refuses to remove a worktree in these conditions:

- The worktree has uncommitted changes.
- The worktree has commits that are neither merged into the base branch nor pushed.
- A file that `.wt-include` copied in now differs from its source in the main checkout. For example, an agent edited `.env`.
- `wt rm` cannot compare the worktree with its base at all. This occurs in two cases:
  - The base ref was deleted, and no qualified replacement passes the preservation checks.
  - A sidecar (the task's files under `<repo>/.git/wt/`) from an older `wt` records the literal `HEAD`. `HEAD` resolves to the worktree's own tip, so every other count would read as nothing to lose.

The refusal message names the reason and the file. `wt prune` applies the same checks.

### Squash merges count as merged

"Merged" includes a squash merge. A branch is merged when every change in it is already in the tip of the base. This is true even if its commits are not ancestors of the base.
Examples are GitHub's "squash and merge", a rebase-merge, and a cherry-pick into a branch that then merged.
`wt rm` removes such a worktree and its branch.

Before removal, `wt rm` refreshes remote evidence and checks it again at the deletion boundary.
The cached base can be stale after a pull request (PR) merges or its squash commit is reverted.

When a stacked parent disappears, `wt rm` can validate the saved root or an unambiguous remote's current default.
It preserves the creation base in the sidecar.
It validates the complete task tip, including unpublished post-merge work.
Failed fetches and failed comparisons keep the task.
For published-only removal, it retains the tip under `refs/wt/preserved/<generation>` and reports that ref.

### Refusals about the base

Two refusal messages have these meanings:

| Refusal | Meaning |
|---|---|
| `merging wt/x into origin/main would still change N path(s)` | Some of the branch's work is NOT in the base. For example, a commit made after the PR merged, or a squash that the base later reverted in part. |
| `would conflict` | The base edited the same lines again. |

`wt rm` refuses these on purpose. Report them and let the user decide.

## Removal policy and refusals

Before removal, inspect the task with `wt show <name>` or `wt -H <vm> show -r <repo> <name>`.
Report what removal would lose.

If `wt rm` refuses, report its reason and the applicable choices:

- Leave the task and report its branch.
- Keep the branch with `--keep-branch`.
- Discard commits with `--discard-commits` when only commits block removal. All other checks still apply.
- Discard all work with `--force`.

Run removal outside the target worktree, as the procedure above shows.
`wt prune` removes only merged, clean worktrees. Use it for an authorized cleanup.
If someone deleted a directory by hand, `wt prune` also removes stale Git registrations.
