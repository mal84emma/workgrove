# Check workgrove after a cmux update

Use this checklist before marking a cmux release as verified.
The Mac probe checks the command and JSON contracts.
The VM checks require a reachable VM and a task with a running agent.

1. On the Mac, run `wt doctor`.
   Each failed check prints a repair command.
   A version warning names the verified release.
   Its repair command installs that release from its versioned disk image.
   Quit cmux before running the installer command, then run `wt doctor` again.
   workgrove supports one verified release at a time.
   Older and newer versions require verification.
2. From the Mac, run `wt -H <vm> doctor`.
   Both cmux-tui agent hooks must show `installed`.
   The VM protocol must match the Mac protocol.
3. Start a disposable task with `wt -H <vm> new cmux-check -r <repo>`.
   Confirm that its row shows `@<vm> · <repo>` on the second line.
4. On the VM, run `wt open cmux-check -r <repo>`.
   Confirm that VS Code opens the VM worktree.
   If no window appears, run the Mac command that `wt open` prints.
5. From a separate VM shell, run `wt attach cmux-check -r <repo>`.
   Confirm that cmux selects the existing row without creating another row.
6. Send the agent a brief that requires a tool call.
   Confirm that its row shows Running during the call and Idle after completion.
   Repeat this check with Claude and Codex.
7. From the Mac, run `wt -H <vm> attach cmux-check -r <repo> --reattach`.
   Confirm that the task resumes and its status returns to Idle after another turn.
8. Stop the agent and keep the disposable worktree clean.
   From a separate VM shell, run `wt rm cmux-check -r <repo>`.
   Confirm that the task row closes and its tmux session ends.
9. On the Mac, run `wt doctor --record test/fixtures`.
   The command writes redacted responses below `test/fixtures/cmux-<version>/`.
   It reads one retained `notification.created` event without sending a notification.
   If no event exists, retry after an agent notification.
10. Review the fixtures for personal information before committing them.
    Record the cmux build and the VM results in the README compatibility log.
    After every check passes, update `WG_CMUX_SUPPORTED` in `lib/workgrove/cmux.sh`.

`wt doctor` returns zero when every check passes.
It returns nonzero for failures and version warnings, while reporting the remaining checks.
Hook checks support static commands, environment assignments, shell script arguments, and command separators.
Dynamic expansions or unsupported shell syntax produce a warning instead of a passing result.
Changes to executable lookup, shell initialization, or the working directory also produce a warning.
Move such code into an executable helper file, then use its path as the hook command.
The probe never executes hook commands.

`--record` runs only on the Mac and requires a writable destination.
Recording keeps JSON types and contract fields but replaces free text and identities with placeholders.
The `REDACTED.txt` file marks the fixture folder as redacted.

For relay behavior, see [VM requests after cmux 0.65](vm-open-relay.md).
For the agent hooks, see [Agent status in VM rows](vm-agent-status.md).
