---
name: task-driver
description: Spawn and supervise task sessions from a driver session; use when the user asks to start, queue, check on, or open tasks, locally or on a named VM
---

# Driving tasks from a driver session

Use this skill in the driver session to start, watch, and report tasks on this Mac or on a VM.

The driver session runs in the row titled `driver` (second line `@local`, ⌃⌥⌘D) and starts and watches other sessions. Its cwd (current working directory) is the first existing folder in `$WT_REPOS_DIR`. That folder is not a repo, so every `wt new` needs `-r <repo>`.

`wt` hides the difference between local and remote:

- `wt <sub> …` is for this Mac.
- `wt -H <vm> <sub> …` is for a VM.

1. **Write the brief.** Turn the request into a self-contained brief. The new session has no memory of this conversation. Include these items:
   - the goal
   - the relevant files or areas
   - the done criteria
   - the constraints
   - the base branch, if it is not main

   For a VM task, if you will stage a brief file that carries task details, make the brief tell the agent to read that file.

   If the brief is in a local file, pass it to `new` with `--prompt-stdin < brief-file`. Do not shell-quote the file contents with `-p`.

2. **Start the task.** Pick a short kebab-case slug with no dots.
   - Locally, run `wt new <slug> -r <repo> -a <agent> -p "<brief>"`.
   - On a VM, run `wt -H <vm> new <slug> -r <repo> -a <agent> -p "<brief>" --no-workspace`.
   - When the user chooses a model, add `-m <model>`. The model stays with the task on restarts.
   - Start one task per independent unit of work. Do not split work that touches the same files.

   When the user gives machine requirements instead of a VM name, choose the host with these steps:

   1. Run `wt hosts --json` on the Mac immediately before you choose. The inventory shows hardware capacity, not currently free capacity.
   2. Convert each requested memory size to MiB:
      - Treat an unqualified "GB" as decimal: 1 GB = 10^9 bytes, about 953.7 MiB.
      - Use 1024 MiB for an explicit GiB.
   3. Consider only entries with `status == "available"` and with known `cpu_logical` and `memory_mib` values that meet the requested minimums.
   4. Compare the converted thresholds with the reported usable RAM and GPU memory. Do not apply a percentage tolerance. The reported usable memory must meet a stated usable-memory requirement in full.
   5. For a GPU request, the host must also meet all of these conditions:
      - `gpu_status == "ok"`.
      - `gpus` has at least the requested number of GPUs.
      - Each of these GPUs meets any requested model and memory minimum. A null GPU `memory_mib` cannot meet a memory minimum.
   6. If no host qualifies, report that and do not create a task. Otherwise, choose among the matching hosts with these preferences:
      - For a CPU-only task, prefer a host with `gpu_status == "none"`, then the least excess CPU and RAM.
      - For a GPU task, prefer the least excess matching GPU count and memory, then the least excess CPU and RAM.
      - Break ties by host name.
   7. Start the task on the selected host with the VM command above, with `<host>` in place of `<vm>`. `wt -H <host> new` does its own check for the repo.
      - If its preflight says that the repo is missing, try the next matching host. If no matching host is left, report that and do not create a task.
      - After any other `new` error, follow its inspection or recovery command before you select another host. SSH may have dropped after `new` created the worktree.

3. **Finish preparing the VM task before launch.** When there are no files to upload, go to sub-step 3 (attach) immediately after `new`. Otherwise, do all these steps:
   1. Find the absolute worktree path. `new` prints it, or you can run `wt -H <vm> path -r <repo> <slug>`.
   2. Upload any required brief, config, or input files into that worktree with `scp` or `rsync`. Stage `.claude/settings.local.json` only for per-task settings other than the model; set the model with `-m` on `new`. Verify the transfer. If the upload fails, do not attach.
   3. Run `wt -H <vm> attach -r <repo> <slug>`. This command opens the local row and starts the saved agent.

   If the upload or attach fails, do this:
   - If attach fails, inspect the task state before you retry.
   - In either case, keep the created worktree and report its path and recovery command. Do not create a duplicate task.

4. **Report each task** after its row opens. Give these items:
   - the name
   - the row title (`<slug>`, second line `@local · <repo>` or `@<vm> · <repo>`)
   - the branch
   - the path
   - on a VM, the tmux session

   If preparation stopped early, say in the report that the task exists but that its agent has not started.

5. **Progress on request.**
   - When the user asks for progress, use `wt list [--all]`, `wt show <name>`, `wt -H <vm> list`, and `wt -H <vm> show -r <repo> <name>`.
   - Open the code only when the user asks: `wt open <name>` / `wt -H <vm> open -r <repo> <name>`.

   **Recover an existing VM task.** Do not run recovery, `--reattach`, or `--restart-agent` yourself unless the user asks.
   - If the row is suspended after a network switch, or gone after a restart, tell the user to run `wt -H <vm> attach -r <repo> <name>`. That command stops the row's stale SSH relay on the VM. Then it reconnects the row and selects it.
   - After cmux reconnects, the wheel can type arrow keys, or paste or Shift+Enter can misbehave. In that case, point the user to the same attach command. It re-initializes an attached task's tmux client. If this replacement attach fails, it leaves the row at a shell prompt.
   - If a connected row shows a bare shell after a dropped connection, point the user to `--reattach`.
   - Point the user to `--restart-agent` only if attach refuses because a previously started task has no agent.

6. **Do not do the work here.** Never do a task's own coding in the driver session. Never remove worktrees unless the user asks. To remove one, use `wt rm <name>` / `wt -H <vm> rm -r <repo> <name>` under the `worktree-teardown` rules.

7. **First task per repo on a VM.** Tell the user to click the row once and accept the agent's trust prompt. This prompt comes once per repo, and worktrees inherit the trust. After a hook change, Codex asks once through `/hooks`.
