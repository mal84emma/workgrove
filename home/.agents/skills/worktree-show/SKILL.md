---
name: worktree-show
description: List task worktrees and show the user what a worktree contains — status, commits, diff, or the worktree opened in VS Code. Use when the user asks what tasks are running, what changed in a task, to see/review/open a worktree, or "show me" a branch's work.
---

# Show worktrees to the user

```bash
wt list                    # this repo: NAME BRANCH BASE AHEAD BEHIND DIRTY LAST
wt list --all              # every repo under $WT_REPOS_DIR
wt show <name>             # summary: path, repo, branch, row:, task prompt, commits vs base, diff --stat, status
wt -H <vm> list            # the same, on a VM (implies --all)
wt -H <vm> show -r <repo> <name>
```

On a VM, `wt show` also reports `session: wt-<repo>-<name> (agent running|shell only|none)`.

## Letting the user look at the code

"Show me the worktree code" / "open VS Code" → `wt open`. Never open VS Code unasked.

```bash
wt open                    # this session's worktree (the default; no name needed)
wt open <name>             # another task in this repo; a second call focuses the existing window
wt -H <vm> open -r <repo> <name>   # from the Mac, opens the VM folder over Remote-SSH
```

From inside a VM session, plain `wt open` asks the Mac to open the remote folder and prints the `wt -H <vm> open …` fallback line; report that line if the user sees nothing.

For a single file's changes, stay in the terminal:

```bash
git -C "$(wt path <name>)" diff <base>...HEAD -- <file>
```

## Rules

1. Start with `wt list` when the question is about tasks in general; `wt show <name>` when it is about one task.
2. Summarise in your own words after showing: what the task was, how far it is (commits, dirty files), whether it is merged or pushed. Do not paste the whole diff.
3. "Show me the code" = `wt open`; "what changed" = `wt show <name>` and a summary. If unsure, `wt show` first and offer to open it.
4. `wt list`, `wt show` and `wt open` change nothing; safe to run while the task's agent is still working.
