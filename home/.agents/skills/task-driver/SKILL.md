---
name: task-driver
description: Spawn and supervise task sessions from a driver session; use when the user asks to start, queue, check on, or open tasks, locally or on a named VM
---

# Driving tasks from a driver session

The driver session (row `driver`, second line `@local`, ⌃⌥⌘D) starts and watches other sessions. Its cwd is the first existing folder in `$WT_REPOS_DIR`, which is not a repo, so every `wt new` needs `-r <repo>`. `wt` hides local/remote: `wt <sub> …` for this Mac, `wt -H <vm> <sub> …` for a VM.

1. **Write the brief.** Turn the request into a self-contained brief: goal, relevant files/areas, done criteria, constraints, base branch if not main. The new session has no memory of this conversation.
2. **Start the task.** Pick a short kebab slug (no dots). `wt new <slug> -r <repo> -a <agent> -p "<brief>"`, or `wt -H <vm> new -r <repo> -a <agent> -p "<brief>"` when the user names a VM. One task per independent unit of work; do not split work that touches the same files.
   When the user gives machine requirements instead of a VM name, run `wt hosts --json` on the Mac immediately before choosing. Consider only `status == "available"` entries with known `cpu_logical` and `memory_mib` meeting the requested minimums. A GPU request also requires `gpu_status == "ok"` and a matching GPU in `gpus` (model and memory in MiB). These are installed capacities, not free capacity. For a CPU-only task, prefer a host with `gpu_status == "ok"` and no GPUs, then the least excess CPU and RAM; for a GPU task, prefer the least excess matching GPU memory, then CPU and RAM; break ties by host name. Check that the requested repo exists with `wt -H <host> repos <repo>` before creating the task; try the next matching host if it does not. If none qualifies, report that and do not create a task. Do not retry on another host after `wt -H <host> new` starts: it may have created the worktree before a row failure.
3. **Report each task**: name, row title (`<repo>:<slug>`, second line `@local` or `@<vm>`), branch, path, and on a VM the tmux session.
4. **Progress on request**: `wt list [--all]`, `wt show <name>`, `wt -H <vm> list`, `wt -H <vm> show -r <repo> <name>`. Open code only when asked: `wt open <name>` / `wt -H <vm> open -r <repo> <name>`. If a VM row is gone after a restart, the user re-opens it with `wt -H <vm> attach -r <repo> <name>` (add `--reattach` when the row shows a bare shell after a dropped connection, or `--restart-agent` only if attach refuses, and only when the user asks).
5. **Do not do the work here.** Never do a task's own coding in the driver session, and never remove worktrees unless asked — `wt rm <name>` / `wt -H <vm> rm -r <repo> <name>` under the `worktree-teardown` rules.
6. **First task per repo on a VM**: tell the user to click the row once and accept the agent's trust prompt (one per repo; worktrees inherit it). After a hook change, Codex asks once via `/hooks`.
