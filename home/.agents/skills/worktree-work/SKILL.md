---
name: worktree-work
description: How to behave when working inside a task worktree — staying isolated, committing, syncing with the base branch, and handing work back via a PR. Use whenever the session's cwd is under a `.worktrees/` directory, or the user asks to update/rebase/push a worktree or open a PR from it.
---

# Working inside a task worktree

Check where you are first:

```bash
wt current        # "worktree: <path> / branch wt/<name> / main: <main checkout>"  or  "main checkout: ..."
```

## Rules while in a worktree

1. **Stay inside.** Edit only files under this worktree. Never `cd` into, edit, or run commands against the main checkout or other worktrees. Their paths are visible in `wt list`; treat them as read-only reference at most.
2. **Commit as you go**, on the worktree's own branch (`wt/<name>`). Small, described commits; the user reviews branches, not working trees.
3. **Do not switch branches** or run `git checkout <other-branch>` inside a worktree; the branch is the task's identity. Do not create nested worktrees.
4. **Dependencies and env** live per worktree. If something is missing, install it here (or suggest a `.wt-setup` script for the repo) rather than pointing at the main checkout.
5. **Do not remove the worktree yourself** when done. Report completion; the user (or `worktree-teardown`) decides.

## Syncing and handing back

```bash
wt sync <name>              # rebase this branch onto its base (origin/main by default); requires a clean tree
wt sync <name> --merge      # merge instead of rebase
wt pr <name> [--draft]      # push wt/<name> and open a GitHub PR against the base with gh
```

Resolve conflicts inside the worktree, then `git rebase --continue` or `git merge --continue`.

## Finishing a task

End with a short summary: what changed (files/areas), commits made, tests run and results, anything left undone. Then stop. Mention that the work is on branch `wt/<name>` and can be inspected with `wt show <name>`.
