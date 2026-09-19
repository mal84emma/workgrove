# Working conventions for coding agents

These apply in every repository under `~/Documents/Repositories` and in every terminal inside cmux.

## Tasks run in worktrees

Each unit of work that changes code is a **task** and lives in its own git worktree, created and managed with the `wt` command (`wt help`). Never do task work directly in a repository's main checkout unless the user explicitly asks for a quick edit there.

- **Starting work the user describes as a task, feature, fix, or experiment** → create a worktree first (`wt new <name> -p "<brief>"`), or, if you are already inside a worktree, work there. See the `worktree-create` skill.
- **Several independent things at once** → one worktree per thing, each with its own agent session in cmux (`wt new ... -p ...`). Only split work that will not touch the same files.
- **Inside a worktree** (check with `wt current`) → stay inside it, commit on its `wt/<name>` branch, never touch the main checkout or sibling worktrees. See the `worktree-work` skill.
- **The user wants to see progress or changes** → `wt list`, `wt show <name>`; open VS Code (`wt open`) or a cmux diff pane (`wt diff`) only when asked. See the `worktree-show` skill.
- **Finishing or cleaning up** → hand back with `wt pr <name>` or report the branch. Remove worktrees only through `wt rm` / `wt prune`, and only when the user asks; never `--force` without the user saying so in this conversation. See the `worktree-teardown` skill.

## Layout and naming

- Worktrees: `<repo>/.worktrees/<name>` (git-ignored globally). Branches: `wt/<name>`. Base: `origin/main` unless `--head` or `-b <ref>` was given.
- Names are short kebab-case slugs describing the task.
- Per-repo hooks: `.worktreeinclude` (ignored files to copy in) and `.wt-setup` (runs in each new worktree).

## cmux

Each task worktree normally has a cmux workspace (sidebar row) showing its branch, agent state and notifications. Use `cmux` commands only for creating, inspecting, or closing task workspaces; do not rearrange the user's other workspaces. Never steal focus: `wt new` creates workspaces unfocused by default.

## Reporting

When you create tasks, list them: name, path, branch, and the brief given. When you finish a task, summarise changes, commits, tests run, and anything left undone, then stop.
