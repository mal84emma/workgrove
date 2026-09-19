---
name: worktree-teardown
description: Safely remove task worktrees and their branches, and clean up finished ones. Use when the user asks to remove/delete/clean up a worktree or task, tear down finished work, or free up merged branches.
---

# Tear down worktrees

```bash
wt rm <name>                 # removes worktree, its wt/<name> branch, and its cmux workspace
wt rm <name> --keep-branch   # remove the directory but keep the branch for later
wt rm <name> --force         # discard uncommitted or unmerged work (destructive)
wt prune --dry-run           # list worktrees whose branch is merged into base and whose tree is clean
wt prune                     # remove those
```

## Safety contract (enforced by `wt rm`, exit code 3 on refusal)

`wt rm` refuses when the worktree has uncommitted changes, or has commits that are neither merged into the base branch nor pushed. The refusal message says why.

## Rules

1. **Inspect before destroying.** Run `wt show <name>` first and tell the user what would be lost (dirty files, unpushed commits).
2. **Never pass `--force` on your own initiative.** Use it only when the user has explicitly said to discard that worktree's work in this conversation. If `wt rm` refuses, report the reason and offer: `wt pr <name>` (push and open a PR), `wt sync` + merge, `--keep-branch`, or discarding with `--force`.
3. **Do not tear down a task whose agent is still running** (a `[cmux]` marker in `wt list` and an active session). Ask the user to finish or stop it first.
4. **Cannot run from inside the worktree being removed**; `cd` to the main checkout first (`wt current` shows it).
5. `wt prune` is safe by construction (merged + clean only) and can be run when the user asks to "clean up".
6. If a worktree directory was deleted by hand, `git worktree prune` inside the repo (`wt prune` runs it) fixes the stale registration.
