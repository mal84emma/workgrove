---
name: task-driver
description: Spawn and supervise task sessions from a driver session; use when the user asks to start, queue, check on, or open tasks, locally or on a named VM
---

# Driving tasks from a driver session

The driver session (row `driver`, second line `@local`, ⌃⌥⌘A) starts and watches other sessions. Its cwd is `$WT_REPOS_DIR`, which is not a repo, so every `wt new` needs `-r <repo>`. `wt` hides local/remote: `wt <sub> …` for this Mac, `wt -H <vm> <sub> …` for a VM.

1. **Write the brief.** Turn the request into a self-contained brief: goal, relevant files/areas, done criteria, constraints, base branch if not main. The new session has no memory of this conversation.
2. **Start the task.** Pick a short kebab slug (no dots). `wt new <slug> -r <repo> -a <agent> -p "<brief>"`, or `wt -H <vm> new -r <repo> -a <agent> -p "<brief>"` when the user names a VM. One task per independent unit of work; do not split work that touches the same files.
3. **Report each task**: name, row title (`<repo>:<slug>`, second line `@local` or `@<vm>`), branch, path, and on a VM the tmux session.
4. **Progress on request**: `wt list [--all]`, `wt show <name>`, `wt -H <vm> list`, `wt -H <vm> show -r <repo> <name>`. Open code only when asked: `wt open <name>` / `wt -H <vm> open -r <repo> <name>`. If a VM row is gone after a restart, the user re-opens it with `wt -H <vm> attach -r <repo> <name>` (add `--restart-agent` only if that refuses, and only when the user asks).
5. **Do not do the work here.** Never do a task's own coding in the driver session, and never remove worktrees unless asked — `wt rm <name>` / `wt -H <vm> rm -r <repo> <name>` under the `worktree-teardown` rules.
6. **First task per repo on a VM**: tell the user to click the row once and accept the agent's trust prompt (one per repo; worktrees inherit it). After a hook change, Codex asks once via `/hooks`.
