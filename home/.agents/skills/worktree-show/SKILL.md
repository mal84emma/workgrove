---
name: worktree-show
description: Show the user a task worktree — open its code in VS Code, or report status, commits and diff. Use when the user says "show me the code", "show me the worktree", "open the worktree", "let me see it", "open it in VS Code", or asks what tasks are running, what changed in a task, or how far a task is.
---

# Show worktrees to the user

Decide the intent first, then run one command:

| The user says | Run | Then |
|---|---|---|
| "show me the code", "show me the worktree (code)", "open the worktree", "let me see it", "open VS Code" | `wt open` | exit 0: report the printed `opened in VS Code: <path>` line, nothing else; otherwise see below |
| "what changed", "how far is it", "status of <task>" | `wt show <name>` | summarise in a few sentences |
| "what tasks are running", "list the worktrees" | `wt list` | summarise |

"Show me the code" means open it in VS Code, not print files in the terminal, and not the source of `wt`. Inside a task session "the worktree" is the one you are in.

```bash
wt open                    # this session's worktree (no name needed); a repeat call focuses the window
wt open <name>             # another task in this repo
wt -H <vm> open -r <repo> <name>   # from the Mac, opens the VM folder over Remote-SSH

wt show <name>             # path, repo, branch, row:, task prompt, commits vs base, diff --stat, status
wt list                    # this repo: NAME BRANCH BASE AHEAD BEHIND DIRTY LAST
wt list --all              # every repo in every folder of $WT_REPOS_DIR
wt -H <vm> list            # the same, on a VM (implies --all)
wt -H <vm> show -r <repo> <name>
```

`wt open` prints `opened in VS Code` only when `code` succeeded; a non-zero exit means no window opened. Inside Codex's sandbox it refuses up front, because app launches are blocked there and `code` would exit 0 anyway: rerun the same `wt open` with escalation (see `AGENTS.md`, Opening apps). Any other failure: report the error it printed.

From inside a VM session, plain `wt open` asks the Mac to open the remote folder and prints the `wt -H <vm> open …` fallback line; report that line if the user sees nothing. On a VM, `wt show` also reports `session: wt-<repo>-<name> (agent running|shell only|none)`, with `, detached` appended when no tmux client is attached — so `agent running, detached` means the agent is alive but no row is holding its session.

For a single file's changes, stay in the terminal. Use `cd` then `git diff`, not `git -C`: the permission rules deny `Bash(git -c *)`, Bash patterns are matched case-insensitively, so `git -C` matches that deny too, and deny beats allow. A compound command is split on `&&`, and `cd` and `git diff` are both allowed.

```bash
cd "$(wt path <name>)" && git diff <base>...HEAD -- <file>
```

## Rules

1. One command per request; do not chain `wt open` with `wt show`.
2. Never open VS Code for a status question, and never answer "show me the code" with a status summary or pasted files.
3. After `wt show`, summarise in your own words: what the task was, how far it is (commits vs base, dirty files) and whether it is merged (`+0` vs base). Pushed state is not printed by `wt show`; `wt rm` is what checks it. Do not paste the whole diff.
4. `wt list`, `wt show` and `wt open` change nothing; safe to run while the task's agent is still working.
