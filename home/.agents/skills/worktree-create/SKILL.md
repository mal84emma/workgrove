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

## Rules

1. **Name** = a short kebab-case slug of the task (`fix-login-redirect`, `paper-figures-v2`), with no `.`. Omit the name only if you pass `-p`. In that case, `wt` derives the slug from the prompt.
2. **Prompt is the whole brief.** The new session has no memory of this conversation. Include these items:
   - the goal
   - the constraints
   - the files or areas involved
   - how to know that it is done (tests, expected behavior, deliverable)

   In the prompt, say that the session is already inside its worktree and must not `cd` to the main checkout.
3. **Independence.** Only split work that will not touch the same files as another running task. Overlapping work belongs in one session.
4. **Do not open VS Code unless asked.** Launching a task opens a cmux row and nothing else. When the user wants to look, they ask for `wt show` or `wt open` (see `worktree-show`).
5. **Report back** these items:
   - the worktree name
   - the row title
   - the branch
   - the path
   - what you told the agent to do (the brief)
   - on a VM, the tmux session

   Deferred creation means that `new` prepares the task without a row and a later `attach` opens the row, as in "VM tasks from the Mac". For deferred creation, report the row only after attach succeeds. Do not wait on or poll the new session.

## VM tasks from the Mac

Create the task on the VM first, send its files, and then attach.

1. Run `wt -H <vm> new <name> -r <repo> -a <agent> -p "<complete task prompt>" --no-workspace`.
   - When the user chose a model, add `-m <model>`.
   - For a brief that is already in a local file, use `--prompt-stdin < brief-file` instead of `-p`.
   - If you will stage a brief file that carries task details, make the brief tell the agent to read that file.

   This command records the brief, agent, and model on the VM. It does not open a row or start the agent.
2. Send any task-specific files with `scp` or `rsync`. Stage `.claude/settings.local.json` only when per-task settings other than the model are necessary; use `-m` for a model. Use the absolute worktree path as the destination. `new` prints this path, or you can get it with `wt -H <vm> path -r <repo> <name>`.
3. Before launch, verify that the required files arrived.
4. Run `wt -H <vm> attach -r <repo> <name>` from the Mac. For a task that has never started, plain `attach` opens the local cmux row and starts the agent with its saved brief.

If the file transfer or attach fails, do this:

- Leave the worktree intact.
- Report its path and the attach command. With these, the user can recover without creating the task again.

Report the row only after attach succeeds.

## On the VM itself

On a VM, `wt new` prepares the worktree and asks the Mac to open its row. Report these items:

- the row `<name>`, whose second line reads `@<host> · <repo>`
- the printed recovery command

For several tasks, or for a task on a VM from the Mac, see `task-driver`.

## Per-repo setup (once, on request)

Add these files to a repo only when the user asks. Each repo needs them once.

- `.wt-include` in the repo root: gitignore-style patterns of ignored files to copy into each new worktree (for example, `.env` or local configs).
- `.wt-setup` executable in the repo root: runs inside every new worktree after creation (for example, `uv sync`, `npm ci`, or `conda env` activation notes).
