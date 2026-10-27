---
name: worktree-work
description: How to behave when working inside a task worktree — staying isolated, committing, syncing with the base branch, and handing work back. Use whenever the session's cwd is under a `.worktrees/` directory, or the user asks to update/rebase/push a worktree or hand it back.
---

# Working inside a task worktree

Use this skill when you work inside a task worktree. You are inside one when both of these are true:

- The cwd is `<repo>/.worktrees/<name>`.
- `git rev-parse --abbrev-ref HEAD` prints `wt/<name>`.

Read and follow the [worktree rules](../../../.claude/TASKS.md#worktree-rules).
These rules cover isolation, branches, commits, dependencies, and removal.
Follow the [interactive command policy](../../../.claude/AGENTS.md#interactive-commands) in task sessions.

## Syncing with the base

The sidecar (the task's files under `<repo>/.git/wt/`) records the base branch, and `wt show <name>` prints it. Start from a clean tree.
The command below uses `origin/main`. If the recorded base is different, use the recorded base in its place:

```bash
git fetch origin && git rebase origin/main      # or the recorded base
```

If conflicts occur, resolve them inside the worktree. Then run `git rebase --continue`.

## Handing back

Follow the [GitHub write policy](../../../.claude/AGENTS.md#github-writes-and-publishing)
and the [reporting requirements](../../../.claude/TASKS.md#reporting).
The [approved command forms](../../../.claude/TASKS.md#run-approved-github-commands) cover authorized GitHub writes.
