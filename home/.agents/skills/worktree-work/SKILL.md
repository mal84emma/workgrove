---
name: worktree-work
description: How to behave when working inside a task worktree — staying isolated, committing, syncing with the base branch, and handing work back. Use whenever the session's cwd is under a `.worktrees/` directory, or the user asks to update/rebase/push a worktree or hand it back.
---

# Working inside a task worktree

You are inside one when the cwd is `<repo>/.worktrees/<name>` and `git rev-parse --abbrev-ref HEAD` prints `wt/<name>`. This is a convention, not a sandbox: nothing isolates the session for you, so the rules below are yours to keep.

## Rules while in a worktree

1. **Stay inside.** Edit only files under this worktree. Never `cd` into, edit, or run commands against the main checkout or other worktrees. Their paths are visible in `wt list`; treat them as read-only reference at most.
2. **Commit as you go**, on the worktree's own branch (`wt/<name>`). Small, described commits; the user reviews branches, not working trees.
3. **Do not switch branches** or run `git checkout <other-branch>` inside a worktree; the branch is the task's identity. Do not create nested worktrees.
4. **Dependencies and env** live per worktree. If something is missing, install it here (or suggest a `.wt-setup` script for the repo) rather than pointing at the main checkout.
5. **Do not remove the worktree yourself** when done. Report completion; the user (or `worktree-teardown`) decides.
6. **No interactive `wt attach`, `wt task` or `wt driver` from here.** Those belong to the user's own session on the Mac.

## Syncing with the base

The base branch is recorded in the sidecar and printed by `wt show <name>`. From a clean tree:

```bash
git fetch origin && git rebase origin/main      # or the recorded base
```

Resolve conflicts inside the worktree, then `git rebase --continue`.

## Handing back

Report the branch `wt/<name>` and what is on it. Never `git push`, `wt pr`, `gh pr create`, create a remote repository or publish unless the user explicitly asked for that action in this conversation; `wt pr <name>` only then.

## Finishing a task

End with a short summary: what changed (files/areas), commits made, tests run and results, anything left undone. Then stop. Mention that the work is on branch `wt/<name>` and can be inspected with `wt show <name>`.
