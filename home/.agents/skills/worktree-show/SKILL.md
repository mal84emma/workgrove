---
name: worktree-show
description: Show the user a task worktree — open its code in VS Code, or report status, commits and diff. Use when the user says "show me the code", "show me the worktree", "open the worktree", "let me see it", "open it in VS Code", or asks what tasks are running, what changed in a task, or how far a task is.
---

# Show worktrees to the user

Use this skill to show a task worktree to the user. Find the user's intent first. Then run one command.

## Choose the command

| The user says | Run | Then |
|---|---|---|
| "show me the code", "show me the worktree (code)", "open the worktree", "let me see it", "open VS Code" | `wt open` | If the exit code is 0, report `opened in VS Code` locally, or `requested VS Code on the Mac` from a VM. Otherwise, see [Check the result of `wt open`](#check-the-result-of-wt-open). |
| "what changed", "how far is it", "status of <task>" | `wt show <name>` | Summarize in a few sentences. |
| "what tasks are running", "list the worktrees" | `wt list` | Summarize. |

Follow the [display and status policy](../../../.claude/TASKS.md#task-lifecycle).

## Commands

```bash
wt open                    # this session's worktree (no name needed); a repeat call focuses the window
wt open <name>             # another task in this repo
wt -H <vm> open -r <repo> <name>   # from the Mac, opens the VM folder over Remote-SSH

wt show <name>             # path…last: (branch, merged:, dirty:, …), model: if set, session: on a VM; commits, diff --stat, working tree
wt list                    # this repo: NAME BRANCH BASE AHEAD BEHIND MERGED DIRTY LAST
wt list --all              # every repo in every folder of $WT_REPOS_DIR
wt -H <vm> list            # the same, on a VM (implies --all)
wt -H <vm> show -r <repo> <name>
```

## Check the result of `wt open`

Follow the [app launch policy](../../../.claude/AGENTS.md#opening-apps) for escalation and success reporting.

On the Mac, `wt open` prints `opened in VS Code` only when `code` succeeds.
A nonzero exit means that no window opened.
In Codex's sandbox, `wt open` refuses before calling `code`.
From a VM, the command also prints a manual Mac command for a missing window or relay failure.
For any failure, report the error and the printed recovery command.

## Read the session line on a VM

On a VM, `wt show` also reports `session: wt-<repo>-<name> (agent running|shell only|none)`.
It appends `, detached` when no tmux client is attached.
So `agent running, detached` means that the agent is alive, but no row is holding its session.

## Show the changes in one file

For the changes in a single file, stay in the terminal. Use `cd` and then `git diff`. Do not use `git -C`, for these reasons:

- The permission rules deny `Bash(git -c *)`.
- Bash patterns are matched case-insensitively, so `git -C` matches that deny rule too.
- A deny rule beats an allow rule.

The `cd … && git diff` form below is allowed: a compound command is split on `&&`, and `cd` and `git diff` are both allowed.

```bash
cd "$(wt path <name>)" && git diff <base>...HEAD -- <file>
```

## Report the changes

After `wt show`, summarize in your own words. Do not paste the whole diff. Tell the user:
- What the task was.
- How far it is: the commits compared with the base, and the dirty files.
- Whether it is merged. Read the `merged:` line:
  - `yes`: every commit is in the base.
  - `squash (…)`: the commits are not in the base, but every change is. This is a squash merge.
  - `no (…)`: the line gives the reason. It is the same reason that `wt rm` would refuse with.

`wt list` shows the same value in its `MERGED` column.
Both commands are offline, so they do not fetch the base. Right after a pull request merges, they read `no` until something fetches the base.
`wt show` does not print the pushed state; `wt rm` is the command that checks it.
`wt list`, `wt show` and `wt open` change nothing. They are safe to run while the task's agent is still working.
