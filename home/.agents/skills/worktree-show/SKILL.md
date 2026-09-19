---
name: worktree-show
description: List task worktrees and show the user what a worktree contains — status, commits, diff, or the worktree opened in VS Code or a cmux diff pane. Use when the user asks what tasks are running, what changed in a task, to see/review/open a worktree, or "show me" a branch's work.
---

# Show worktrees to the user

```bash
wt list                    # this repo: name, branch, base, ahead/behind, dirty files, last commit, [cmux] if a workspace is open
wt list --all              # every repo under ~/Documents/Repositories
wt list --json             # machine-readable
wt show <name>             # summary: path, branch, task prompt, commits vs base, diff --stat, working-tree status
wt show <name> --json
```

## Letting the user look at the code

Only on request; never as a side effect of creating a task.

```bash
wt open <name>             # open the worktree folder in a new VS Code window   (= wt show <name> --code)
wt diff <name>             # open a cmux split-diff pane: branch vs its base   (= wt show <name> --diff)
git -C "$(wt path <name>)" diff <base>...HEAD -- <file>     # a specific file's diff inline
```

## Rules

1. Start with `wt list` when the question is about tasks in general; `wt show <name>` when it is about one task.
2. Summarise in your own words after showing: what the task was, how far it is (commits, dirty files), whether it is merged/pushed. Do not paste the whole diff.
3. "Show me" = `wt open` for reading code, `wt diff` for reviewing changes, plain `wt show` when the user is in the terminal. If unsure which, `wt show` first and offer the other two.
4. `wt open` / `wt diff` do not change anything; safe to run while the task's agent is still working.
