# Check workgrove after a cmux update

Use this checklist before marking a cmux release as verified.
The Mac probe checks the command and JSON contracts.
The VM checks require a reachable VM and a task with a running agent.

1. On the Mac, run `wt doctor`.
   Each failed check prints a repair command.
   The probe requires only methods that workgrove calls.
   It does not require `workspace.remote.reconnect`.

   A version warning names the verified release.
   Its repair command installs that release from its versioned disk image.
   Quit cmux before running the installer command, then run `wt doctor` again.
   workgrove supports one verified release at a time.
   Older and newer versions require verification.
2. From the Mac, run `wt -H <vm> doctor`.
   Both cmux-tui agent hooks must show `installed`.
   The VM protocol must match the Mac protocol.
   The Mac requires a doctor result record.
   A missing record fails the check and names `wt -H <vm> update`.
3. Start a disposable task with `wt -H <vm> new cmux-check -r <repo>`.
   Confirm that its row shows `@<vm> · <repo>` on the second line.
4. On the VM, run `wt open cmux-check -r <repo>`.
   Confirm that VS Code opens the VM worktree.
   If no window appears, run the Mac command that `wt open` prints.
5. Use a separate VM shell whose terminal a Mac native SSH row mirrors.
   An ordinary SSH shell can have relay variables without a Mac mirror.
   Choose an unused disposable row name, such as `step5-shell`.
   On the Mac, run `cmux ssh <vm> --name step5-shell --json --id-format uuids`.
   Record `.workspace_id` from the creation response as `<shell-row-uuid>`.
   Before the request, record the `cmux-check` row UUID from `cmux workspace list --json` on the Mac.
   Record the row count in each window that contains test rows.
   In the new shell row, run `wt attach cmux-check -r <repo>`.
   Confirm that cmux selects the recorded UUID and creates no additional row.
   Check the row count again in each test window.
   On the Mac, run `cmux workspace close <shell-row-uuid>`.
   Confirm that only that disposable shell row closes.
6. Send the agent a brief that requires a tool call.
   Confirm that its row shows Running during the call and Idle after completion.
   Repeat this check with Claude and Codex.
7. This check requires an existing native task row at a bare VM shell prompt naming `user@host`.
   The row reaches this state after `remote session was lost; starting a new shell`.
   No safe, repeatable setup for this state has been verified.
   If this state is unavailable, record step 7 as **not run: requires a lost remote session**.
   Do not stop shared SSH transports or unrelated rows to produce it.
   When the prerequisite holds, run `wt -H <vm> attach cmux-check -r <repo> --reattach` from the Mac.
   Confirm that the task resumes and its status returns to Idle after another turn.

   Detaching tmux closes a native task row because `tmux attach` is its only command.
   Detachment does not produce the bare shell that `--reattach` requires.
   To check plain-attach recovery separately, detach only the disposable task's tmux client with `Ctrl-b d`.
   Confirm that its row closes.
   From the Mac, run `wt -H <vm> attach cmux-check -r <repo>` without `--reattach`.
   Confirm that one new row attaches to the existing session.
   Send another agent turn and check Running, then Idle.
   [Issue #199](https://github.com/mal84emma/workgrove/issues/199) records this recovery behavior and the step 7 limit.
8. Check both removal cases below with clean, disposable tasks.
   Use an installed `wt` outside the worktree that you remove.
   In the expected output, `<task>` names the target task and `<repo>` is its absolute repository path.
   Output examples use placeholders; personal details are redacted.
   For a remote base, expect this fetch notice once per command:

   ```text
   wt: fetching <base> from <remote> to verify current landing content
   ```

   - Remove the task from its own session.
     Stop the agent in `cmux-check` and keep its worktree clean.
     In that task's VM shell, run `cd <repo>`, then `wt rm cmux-check -r <repo>`.
     Confirm that the task row closes and its tmux session ends.
     The command prints this line before session cleanup:

     ```text
     removed <task>
     ```

     Self-closure can end the command before it returns or prints a completion line.
     A surviving caller exits nonzero with the pending output below.
     Its receipt remains at `close_requested` until independent observation confirms closure.
     Run the printed Mac command even when the row appears closed.
     Then reuse the name with `wt -H <test-vm> new cmux-check -r <repo>`.
     Confirm that creation succeeds after independent Mac confirmation.

   - Remove another task from a separate VM shell.
     From the Mac, create it with `wt -H <test-vm> new cmux-check-other -r <repo>`.
     Stop its agent and keep its worktree clean.
     From a separate VM shell, run `wt rm cmux-check-other -r <repo>`.
     Confirm that the worktree and branch are absent, while the row and tmux session remain open.
     The command exits nonzero and prints these lines:

     ```text
     removed <task>
     wt: Git cleanup completed; Mac row or tmux session closure is unverified; cleanup is pending
     wt: on the Mac: wt -H <test-vm> rm <task> -r <repo>
     wt: receipt: <repo>/.git/wt/teardown/<task>.json
     ```

     On the Mac, run the printed retry: `wt -H <test-vm> rm <task> -r <repo>`.
     Expect these lines:

     ```text
     Git cleanup complete; Mac controller must finish session cleanup
     teardown complete <task>
     ```

     Confirm that the task row closes and its tmux session ends.
9. On the Mac, run `wt doctor --record test/fixtures`.
   The command writes redacted responses below `test/fixtures/cmux-<version>/`.
   It reads one retained `notification.created` event without sending a notification.
   If no event exists, retry after an agent notification.
10. Review the fixtures for personal information before committing them.
    Delete the previous release's fixture folder in the same change.
    Keep any file that the fake cmux still reads from it, such as the SSH creation capture `ssh.json`.
11. After every check passes, update `WG_CMUX_SUPPORTED` in `lib/workgrove/cmux.sh`.
    Add one row to the [cmux compatibility log](cmux-integration.md#cmux-compatibility-log) with the build, the date, the status, and a link to the pull request.
    Record each check's result in the pull request description, not in the repository.
    Open an issue for each defect that the checks find, and link it from the description.

`wt doctor` returns zero when every check passes.
It returns nonzero for failures and version warnings, while reporting the remaining checks.
Hook checks support static commands, environment assignments, shell script arguments, and command separators.
Dynamic expansions or unsupported shell syntax produce a warning instead of a passing result.
Changes to executable lookup, shell initialization, or the working directory also produce a warning.
Interactive, login, restricted, and stdin shell modes require an executable helper file.
Move such code into an executable helper file, then use its path as the hook command.
The probe never executes hook commands.

`--record` runs only on the Mac and requires a writable destination.
Recording keeps JSON types and contract fields but replaces free text and identities with placeholders.
The `REDACTED.txt` file marks the fixture folder as redacted.

For relay behavior, see [VM requests after cmux 0.65](vm-open-relay.md).
For the agent hooks, see [Agent status in VM rows](vm-agent-status.md).
