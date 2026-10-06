---
name: worktree-teardown
description: Safely remove task worktrees and their branches, and clean up finished ones. Use when the user asks to remove/delete/clean up a worktree or task, tear down finished work, or free up merged branches.
---

# Tear down worktrees

Use this skill to remove task worktrees and their branches safely. Remove a worktree only when the user asks.

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

1. Inspect the worktree with `wt show <name>`.
2. Tell the user the branch, the commits, the test results, and what the command will remove.
3. Take the absolute `repo:` path from the `wt show` output.
4. Run the command below as one shell command, so that `wt rm` starts from that main checkout.

```bash
cd <absolute-repo-path> && wt rm <name> -r <absolute-repo-path>
```

This change of directory is the exception to the stay-inside rule of `worktree-work`. Do no task edits in the main checkout.

If `wt rm` refuses, the row stays open. Report the reason and leave the worktree.

### On a VM

Run that command on the VM, not through `wt -H`.
After the removal, `wt` asks the Mac to close the row of this task and then to stop its tmux session.
Closing the row and stopping the session can cut off the tool call or the agent, so give the user the summary first.

`wt rm` waits for the Mac hook. If the session is still active after that wait, the cleanup is incomplete, even if `wt rm` printed `removed`.
In this case, report its warning. Tell the user to close the named row and tmux session from the Mac. `wt -H <vm> rm` cannot retry after the worktree is gone.

## Safety contract (enforced by `wt rm`, exit code 3 on refusal)

`wt rm` refuses to remove a worktree in these conditions:

- The worktree has uncommitted changes.
- The worktree has commits that are neither merged into the base branch nor pushed.
- A file that `.wt-include` copied in now differs from its source in the main checkout. For example, an agent edited `.env`.
- `wt rm` cannot compare the worktree with its base at all. This occurs in two cases:
  - The base ref was deleted.
  - A sidecar (the task's files under `<repo>/.git/wt/`) from an older `wt` records the literal `HEAD`. `HEAD` resolves to the worktree's own tip, so every other count would read as nothing to lose.

The refusal message names the reason and the file. `wt prune` applies the same checks.

### Squash merges count as merged

"Merged" includes a squash merge. A branch is merged when every change in it is already in the tip of the base. This is true even if its commits are not ancestors of the base.
Examples are GitHub's "squash and merge", a rebase-merge, and a cherry-pick into a branch that then merged.
`wt rm` removes such a worktree and its branch.

Before `wt rm` decides, it fetches the base once, because `origin/main` is stale right after a pull request (PR) merges.

### Refusals about the base

Two refusal messages have these meanings:

| Refusal | Meaning |
|---|---|
| `merging wt/x into origin/main would still change N path(s)` | Some of the branch's work is NOT in the base. For example, a commit made after the PR merged, or a squash that the base later reverted in part. |
| `would conflict` | The base edited the same lines again. |

`wt rm` refuses these on purpose. Report them and let the user decide.

## Rules

1. **Check liveness, then inspect.** Run `wt show <name>` (or `wt -H <vm> show -r <repo> <name>`) before anything else. Tell the user what the removal would lose.
2. **Never pass `--force` or `--discard-commits` on your own initiative.** Use either flag only when the user has explicitly said to discard that worktree's work in this conversation.
   If `wt rm` refuses, report the reason and offer these choices:
   - Report the branch and leave it.
   - Use `--keep-branch`.
   - Discard the commits alone with `--discard-commits`. Offer this when the refusal is only about commits, for example a squash that the base then edited or reverted. With `--discard-commits`, `wt rm` still runs the other checks.
   - Discard everything with `--force`.

   Use `wt pr <name>` only if the user asks for a PR.
3. **Never remove a worktree that the user has not asked you to remove.** This includes the worktrees that you created yourself.
4. **Run `wt rm` outside the worktree that you remove.** For your own task, change to the main checkout only for the teardown command, as shown above.
5. `wt prune` is safe by construction, because it removes only merged and clean worktrees. You can run it when the user asks to "clean up".
6. If someone deleted a worktree directory by hand, `git worktree prune` inside the repo fixes the stale registration. `wt prune` runs it.
