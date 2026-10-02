---
name: worktree-create
description: Create an isolated git worktree for a task, optionally with its own cmux workspace running a coding agent. Use when the user asks to start a task, work on something in parallel, spin off a sub-task, or try an approach without touching the main checkout.
---

# Create a task worktree

Tool: `wt new` (see `wt help`). One task = one worktree at `<repo>/.worktrees/<name>` on branch `wt/<name>`, one cmux row titled `<repo>:<name>` whose second line reads `@local` or `@<host>`.

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

`wt new` prints the path, branch, repo and session. It runs from anywhere inside the repo, including from another worktree (it always resolves the main checkout). In a driver session, whose cwd is the first existing folder in `$WT_REPOS_DIR` and not a repo, `-r <repo>` is required. A repo name is searched along `$WT_REPOS_DIR` (several folders, separated by `:`); if the same name sits in two of them, `wt` refuses it and you pass the path.

When the user names a model, pass `-m <model>` with either Claude or Codex, locally or with `wt -H <vm> new`. The stored choice overrides a model in `WT_AGENT_ARGS` on every launch. This replaces staging `.claude/settings.local.json` through `.wt-include`.

## Rules

1. **Name** = short kebab-case slug of the task (`fix-login-redirect`, `paper-figures-v2`), no `.`. Omit it only if you pass `-p`; the slug is then derived from the prompt.
2. **Prompt is the whole brief.** The new session has no memory of this conversation. Include: goal, constraints, files or areas involved, and how to know it is done (tests, expected behaviour, deliverable). Mention that the session is already inside its worktree and must not `cd` to the main checkout.
3. **Independence.** Only split work that will not touch the same files as another running task. Overlapping work belongs in one session.
4. **Do not open VS Code unless asked.** Launch opens a cmux row and nothing else. The user asks for `wt show` or `wt open` when they want to look (see `worktree-show`).
5. **Report back** the worktree name, row title, branch, path and what the agent was told to do — plus the tmux session on a VM. For deferred creation, report the row only after attach succeeds. Do not wait on or poll the new session.

## VM tasks from the Mac

Use `wt -H <vm> new <name> -r <repo> -a <agent> -p "<complete task prompt>" --no-workspace`, adding `-m <model>` when chosen. For a brief already in a local file, use `--prompt-stdin < brief-file` instead of `-p`. This records the brief, agent and model on the VM without opening a row or starting the agent. Use the absolute worktree path printed by `new` (or `wt -H <vm> path -r <repo> <name>`) as the destination for any task-specific files sent with `scp` or `rsync`. Verify that required files arrived before launching. If a staged brief file carries task details, make the saved prompt tell the agent to read it. Use `-m` for a model and stage `.claude/settings.local.json` only when other per-task settings are needed.

Then run `wt -H <vm> attach -r <repo> <name>` from the Mac. For a task that has never started, plain `attach` opens the local cmux row and starts the agent with its saved brief. If file transfer or attach fails, leave the worktree intact and report its path and the attach command so the user can recover without creating it again. Report the row only after attach succeeds.

## On the VM itself

On a VM, `wt new` prepares the worktree and asks the Mac to open its row; report the row `<repo>:<name>`, whose second line reads `@<host>`, and the printed recovery command. For several tasks, or a task on a VM from the Mac, see `task-driver`.

## Per-repo setup (once, on request)

- `.wt-include` in the repo root: gitignore-style patterns of ignored files to copy into each new worktree (`.env`, local configs).
- `.wt-setup` executable in the repo root: runs inside every new worktree after creation (`uv sync`, `npm ci`, `conda env` activation notes, etc.).
