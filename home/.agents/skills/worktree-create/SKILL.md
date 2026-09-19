---
name: worktree-create
description: Create an isolated git worktree for a task, optionally with its own cmux workspace running a coding agent. Use when the user asks to start a task, work on something in parallel, spin off a sub-task, or try an approach without touching the main checkout.
---

# Create a task worktree

Tool: `wt new` (see `wt help`). One task = one worktree at `<repo>/.worktrees/<name>` on branch `wt/<name>`.

## Command

```bash
wt new <name> -p "<complete task prompt>"            # worktree + cmux workspace running Claude on the prompt
wt new <name> -p "<prompt>" -a codex                  # ...running Codex instead
wt new <name> --no-workspace                          # worktree only; no agent, no cmux workspace
wt new <name> -p "<prompt>" --head                    # branch from the current branch instead of origin/main
wt new <name> -r <repo-name-or-path> -p "<prompt>"    # target another repo under ~/Documents/Repositories
```

`wt new` prints the path, branch and cmux workspace. It runs from anywhere inside the repo, including from another worktree (it always resolves the main checkout).

## Rules

1. **Name** = short kebab-case slug of the task (`fix-login-redirect`, `paper-figures-v2`). Omit it only if you pass `-p`; the slug is then derived from the prompt.
2. **Prompt is the whole brief.** The new session has no memory of this conversation. Include: goal, constraints, files or areas involved, and how to know it is done (tests, expected behaviour, deliverable). Mention that the session is already inside its worktree and must not `cd` to the main checkout.
3. **Independence.** Only split work that will not touch the same files as another running task. Overlapping work belongs in one session.
4. **Do not open VS Code or diffs unless asked.** Creation is silent apart from the cmux workspace. The user asks for `wt show`/`wt open` when they want to look (see `worktree-show`).
5. **Report back** the worktree name, path, branch and what the agent was told to do. Do not wait on or poll the new session.

## Per-repo setup (once, on request)

- `.worktreeinclude` in the repo root: gitignore-style patterns of ignored files to copy into each new worktree (`.env`, local configs).
- `.wt-setup` executable in the repo root: runs inside every new worktree after creation (`uv sync`, `npm ci`, `conda env` activation notes, etc.).
