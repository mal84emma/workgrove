# Working conventions for coding agents

These apply in every repository under `$WT_REPOS_DIR` (`~/Documents/Repositories` by default) and in every terminal inside cmux, on the Mac and on every VM.

## Tasks run in worktrees

Each unit of work that changes code is a **task** and lives in its own git worktree, created and managed with the `wt` command (`wt help`). Never do task work directly in a repository's main checkout unless the user explicitly asks for a quick edit there.

- **Starting work the user describes as a task, feature, fix, or experiment** → create a worktree first (`wt new <name> -p "<brief>"`), or, if you are already inside a worktree, work there. See the `worktree-create` skill.
- **Several independent things at once** → one worktree per thing, each with its own agent session in cmux (`wt new ... -p ...`). Only split work that will not touch the same files. Driving several tasks, or tasks on a VM, from one session: see the `task-driver` skill.
- **Inside a worktree** (cwd under `.worktrees/<name>`) → stay inside it, commit on its `wt/<name>` branch, never touch the main checkout or sibling worktrees. See the `worktree-work` skill.
- **The user wants to see progress or changes** → `wt list`, `wt show <name>`; open VS Code (`wt open`) only when asked. See the `worktree-show` skill.
- **Finishing or cleaning up** → report the branch. Remove worktrees only through `wt rm` / `wt prune`, and only when the user asks; never `--force` without the user saying so in this conversation. See the `worktree-teardown` skill.

These are conventions, not a sandbox: a session launched with its cwd inside `.worktrees/<name>` is not isolated by Claude's own worktree isolation. Staying inside the worktree is your responsibility.

Never `git push`, `wt pr`, `gh pr create`, create a remote repository or publish unless the user explicitly asked for that action in this conversation; report the branch instead.

## Layout and naming

- Worktrees: `<repo>/.worktrees/<name>` (git-ignored globally). Branches: `wt/<name>`. Base: `origin/main` unless `--head` or `-b <ref>` was given.
- Names are short kebab-case slugs describing the task; no `.` in a name.
- Each task has a cmux row titled `<repo>:<name>`, whose second line reads `@local` or `@<host>`, and, on a VM, a tmux session `wt-<repo>-<name>`; `wt show <name>` reports them.
- Per-repo hooks: `.worktreeinclude` (ignored files to copy in) and `.wt-setup` (runs in each new worktree).

## Local and remote

`wt` owns the difference. The same subcommands run locally, run inside a VM session, or are sent to a VM from the Mac as `wt -H <vm> <sub> …` (`show`, `rm`, `path`, `open`, `attach` need `-r <repo>`). Every row's second line reads `@local` or `@<host>`, so the sidebar always says where a session runs.

Never run interactive `wt attach`, `wt task` or `wt driver` from a task session; they belong to the user's own session on the Mac.

## cmux

Each task worktree normally has a cmux row showing its branch, agent state and notifications. Use `cmux` commands only for creating, inspecting, or closing task workspaces; do not rearrange the user's other workspaces. Never steal focus: `wt new` creates workspaces unfocused by default.

## Reporting

When you create tasks, list them: name, row title, branch, path, and the brief given — plus the tmux session for a task on a VM. When you finish a task, summarise changes, commits, tests run, and anything left undone, then stop.
