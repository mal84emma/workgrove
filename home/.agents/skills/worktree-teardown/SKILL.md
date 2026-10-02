---
name: worktree-teardown
description: Safely remove task worktrees and their branches, and clean up finished ones. Use when the user asks to remove/delete/clean up a worktree or task, tear down finished work, or free up merged branches.
---

# Tear down worktrees

Remove only when the user asks. Check for a live agent first; the agent in the worktree being removed is the one exception when it is carrying out the user's teardown request.

```bash
wt show <name>                       # row:, dirty files, commits vs base (pushed state is checked by
                                     # wt rm, not shown here)
wt -H <vm> show -r <repo> <name>     # VM: also "session: wt-<repo>-<name> (agent running|shell only|none)",
                                     # with ", detached" appended when no tmux client is attached
```

If another agent is still running there, do not remove it. Ask the user to finish or stop that agent first. Your own session may remove its worktree when the user asks.

```bash
wt rm <name>                         # removes worktree, its wt/<name> branch, sidecar and cmux row
wt rm <name> --keep-branch           # remove the directory but keep the branch for later
wt rm <name> --force                 # discard uncommitted or unmerged work (destructive; only when asked)
wt rm <name> --discard-commits       # discard only the branch's commits, keeping every other check (only when asked)
wt -H <vm> rm -r <repo> <name>       # the same on a VM: worktree, branch, row, then its tmux session
wt prune --dry-run                   # list worktrees whose branch is merged into base and whose tree is clean
wt prune                             # remove those
```

## Removing your own worktree

Inspect it with `wt show <name>` first. Tell the user the branch, commits, test results, and what will be removed **before** the final command: removing your own cmux row ends this agent session. Take the absolute `repo:` path from `wt show`, then run the following as one shell command so `wt rm` starts from that main checkout. Changing directory for this command is the exception to `worktree-work`'s stay-inside rule; do no task edits there.

```bash
cd <absolute-repo-path> && wt rm <name> -r <absolute-repo-path>
```

On a VM, run that command on the VM, not through `wt -H`. After removal, `wt` asks the Mac to close this task's row, then stop its tmux session. The tool call or agent may be cut off, so give the user the summary first. If `wt rm` refuses, the row stays open: report the reason and leave the worktree. If the session remains active after `wt rm` waits for the Mac hook, cleanup is incomplete even if it printed `removed`: report its warning and have the user close the named row and tmux session from the Mac. `wt -H <vm> rm` cannot retry once the worktree is gone.

## Safety contract (enforced by `wt rm`, exit code 3 on refusal)

`wt rm` refuses when the worktree has uncommitted changes, has commits that are neither merged into the base branch nor pushed, when a file copied in by `.wt-include` now differs from its source in the main checkout (an agent edited `.env`), or when it cannot compare the worktree against its base at all — the base ref was deleted, or a sidecar from an older `wt` records the literal `HEAD`, which resolves to the worktree's own tip and would make every other count read as nothing to lose. The refusal message names the reason and the file. `wt prune` applies the same checks.

"Merged" covers a squash merge: a branch whose commits are not ancestors of the base but whose every change is already in the base's tip (GitHub's "squash and merge", a rebase-merge, a cherry-pick into a branch that then merged) is merged, and `wt rm` removes it and its branch. `wt rm` fetches the base once (`origin/main` is stale right after a PR merges) before deciding. A refusal that reads `merging wt/x into origin/main would still change N path(s)` means some of the branch's work is NOT in the base: a commit made after the PR merged, or a squash the base later reverted in part; `would conflict` means the base edited the same lines again. Those are refused on purpose; report them and let the user decide.

## Rules

1. **Check liveness, then inspect.** `wt show <name>` (or `wt -H <vm> show -r <repo> <name>`) before anything, and tell the user what would be lost.
2. **Never pass `--force` or `--discard-commits` on your own initiative.** Use either only when the user has explicitly said to discard that worktree's work in this conversation. If `wt rm` refuses, report the reason and offer: report the branch and leave it, `--keep-branch`, discarding the commits alone with `--discard-commits` (when the refusal is only about commits — a squash the base then edited or reverted — the other checks still run), or discarding everything with `--force`. `wt pr <name>` only if the user asks for a PR.
3. **Never remove a worktree the user has not asked you to remove**, including ones you created yourself.
4. **Run `wt rm` outside the worktree being removed.** For your own task, change to the main checkout just for the teardown command as shown above.
5. `wt prune` is safe by construction (merged + clean only) and can be run when the user asks to "clean up".
6. If a worktree directory was deleted by hand, `git worktree prune` inside the repo (`wt prune` runs it) fixes the stale registration.
