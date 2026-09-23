---
name: worktree-teardown
description: Safely remove task worktrees and their branches, and clean up finished ones. Use when the user asks to remove/delete/clean up a worktree or task, tear down finished work, or free up merged branches.
---

# Tear down worktrees

Remove only when the user asks, and check for a live agent first.

```bash
wt show <name>                       # row:, dirty files, commits vs base (pushed state is checked by
                                     # wt rm, not shown here)
wt -H <vm> show -r <repo> <name>     # VM: also "session: wt-<repo>-<name> (agent running|shell only|none)",
                                     # with ", detached" appended when no tmux client is attached
```

An agent still running means: do not remove. Ask the user to finish or stop it first.

```bash
wt rm <name>                         # removes worktree, its wt/<name> branch, sidecar and cmux row
wt rm <name> --keep-branch           # remove the directory but keep the branch for later
wt rm <name> --force                 # discard uncommitted or unmerged work (destructive; only when asked)
wt -H <vm> rm -r <repo> <name>       # the same on a VM: worktree, branch, row, then its tmux session
wt prune --dry-run                   # list worktrees whose branch is merged into base and whose tree is clean
wt prune                             # remove those
```

## Safety contract (enforced by `wt rm`, exit code 3 on refusal)

`wt rm` refuses when the worktree has uncommitted changes, has commits that are neither merged into the base branch nor pushed, when a file copied in by `.wt-include` now differs from its source in the main checkout (an agent edited `.env`), or when it cannot compare the worktree against its base at all — the base ref was deleted, or a sidecar from an older `wt` records the literal `HEAD`, which resolves to the worktree's own tip and would make every other count read as nothing to lose. The refusal message names the reason and the file. `wt prune` applies the same checks.

## Rules

1. **Check liveness, then inspect.** `wt show <name>` (or `wt -H <vm> show -r <repo> <name>`) before anything, and tell the user what would be lost.
2. **Never pass `--force` on your own initiative.** Use it only when the user has explicitly said to discard that worktree's work in this conversation. If `wt rm` refuses, report the reason and offer: report the branch and leave it, `--keep-branch`, or discarding with `--force`. `wt pr <name>` only if the user asks for a PR.
3. **Never remove a worktree the user has not asked you to remove**, including ones you created yourself.
4. **Cannot run from inside the worktree being removed**; `cd` to the main checkout first (its path is in `wt list`).
5. `wt prune` is safe by construction (merged + clean only) and can be run when the user asks to "clean up".
6. If a worktree directory was deleted by hand, `git worktree prune` inside the repo (`wt prune` runs it) fixes the stale registration.
