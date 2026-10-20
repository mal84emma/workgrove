---
name: worktree-create
description: Create an isolated git worktree for a task, optionally with its own cmux workspace running a coding agent. Use when the user asks to start a task, work on something in parallel, spin off a sub-task, or try an approach without touching the main checkout.
---

# Create a task worktree

Use this skill to create a task: a worktree, and optionally a row with an agent in it.

Tool: `wt new` (see `wt help`). One task is:

- one worktree at `<repo>/.worktrees/<name>` on branch `wt/<name>`
- one cmux row titled `<name>`, whose second line reads `@local · <repo>` or `@<host> · <repo>`

## Command

```bash
wt new <name> -p "<complete task prompt>"            # worktree + cmux row running Claude on the prompt
wt new <name> -p "<prompt>" -a codex                  # ...running Codex instead
wt new <name> -p "<prompt>" -a claude -m <model>      # choose this task's model, also on later launches
wt new <name> --no-workspace                          # worktree only; no agent, no cmux row
wt new <name> -p "<prompt>" --head                    # branch from the current branch instead of the default one
wt new <name> -p "<prompt>" -b <ref>                  # branch from <ref> instead of the default one
wt new <name> -r <repo-name-or-path> -p "<prompt>"    # target another repo in $WT_REPOS_DIR
wt -H <vm> new <name> -r <repo> -p "<prompt>" --no-workspace  # prepare a VM task before opening its row
```

`wt new` prints the path, branch, repo, and session.

### Where to run it

- `wt new` runs from anywhere inside the repo, including from another worktree, because it always resolves the main checkout.
- In a driver session, you must pass `-r <repo>`. This is because the session's cwd (current working directory) is the first existing folder in `$WT_REPOS_DIR`, and that folder is not a repo.
- `wt` searches for a repo name along `$WT_REPOS_DIR`, which can hold several folders separated by `:`.
- If the same repo name is in two of these folders, `wt` refuses it. In that case, pass the path instead.

### Choose a model

When the user names a model, pass `-m <model>`. This works with Claude or Codex, locally or with `wt -H <vm> new`. On every launch, the stored choice overrides a model in `WT_AGENT_ARGS`. The `-m` option replaces staging `.claude/settings.local.json` through `.wt-include`.

## Task policy and brief

Follow the [task policy](../../../.claude/AGENTS.md#tasks-run-in-worktrees)
and the [reporting requirements](../../../.claude/AGENTS.md#reporting).
Use the [task-driver procedure](../task-driver/SKILL.md#driving-tasks-from-a-driver-session)
for a complete brief and VM preparation before launch.
If you omit the name, pass `-p` so `wt` can derive the name from the brief.

## On the VM itself

On a VM, `wt new` prepares the worktree and asks the Mac to open its row. Report these items:

- the row `<name>`, whose second line reads `@<host> · <repo>`
- the printed recovery command

For several tasks, or for a task on a VM from the Mac, see `task-driver`.

## Per-repo setup (once, on request)

Follow the [per-repo setup policy](../../../.claude/AGENTS.md#per-repo-setup). Each repo needs these files once.

- `.wt-include` in the repo root: gitignore-style patterns of ignored files to copy into each new worktree (for example, `.env` or local configs).
- `.wt-setup` executable in the repo root: runs inside every new worktree after creation (for example, `uv sync`, `npm ci`, or `conda env` activation notes).
