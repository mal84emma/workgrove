# Safe task teardown

`wt rm` removes a task after checking work preservation and session ownership.
This page describes the runtime fix developed from the [squash investigation](self-teardown-squash.md) and [Codex investigation](codex-self-teardown.md).
The historical investigation reports describe the earlier behavior.

## Remove your own task

A user's teardown request authorizes routine safe removal and closure of that task's own session and row.
Discarding work and closing another task's running agent still require explicit authorization.
Operating-system approval remains separate from these checks.

1. Inspect the task with `wt show <name> --json`.
2. Report the branch, commits, test results, and removal scope before closure.
3. Change directories outside the task, using an installation outside that task.
4. Run `wt rm <name> -r <repo>`.

For sandboxed Codex, submit the complete removal command through escalation.
Do not clear `CODEX_SANDBOX` or change global approval policy.
An approval denial leaves the task intact.

## Select and validate a destination

The sidecar's `base` remains the creation comparison ref.
PR retargeting does not rewrite it.
New tasks use metadata version 3 and record creation objects, a generation, and inherited landing-root provenance.
A generation identifies one instance of a task name.
Parent removal does not edit dependent sidecars.

Removal first checks the saved base or the repository's explicit `wt.landingRef` Git configuration.
A missing or unsuitable stacked parent can trigger a separate landing-destination check.
Saved local roots support local-only repositories.

Remote discovery uses creation provenance, the configured upstream remote, or the repository's sole remote.
It queries that remote's advertised symbolic `HEAD`, then fetches the selected branch explicitly.
This supports non-GitHub remotes and renamed default branches without assuming `origin/main`.
Canonical resolution rejects symbolic aliases of the task branch and mutable revision expressions.
Full remote names can contain slashes.

Overlapping remote names require version-3 provenance or explicit `wt.landingRemote` Git configuration.
Older metadata remains unchanged and uses only unambiguous remote mappings.
Ambiguous or unavailable destinations keep the task.
An explicit landing ref still requires preservation proof.

Git ancestry can establish preservation of the task commits.
Otherwise, a nonempty, conflict-free simulated merge must leave the destination tree unchanged.
The comparison covers the complete current task tip and its inherited parent changes.
Deleted remote branches and merged-PR assertions alone establish neither proof.
The implementation needs no GitHub lookup or parent completion chain when this complete Git comparison succeeds.

Published-only removal fetches the configured upstream ref into an isolated verification ref.
Its current object must contain the task tip.
Removal retains a local recovery ref at `refs/wt/preserved/<generation>`.
These refs remain until explicitly reviewed and removed; teardown does not expire the last local copy automatically.
Pinned object bases also retain a recovery ref.
Creation object fields are audit metadata, rather than independent preservation proofs or garbage-collection anchors.

Remote comparisons refresh before accepting cached success and again before deletion.
Failed fetches and invalid counts refuse removal.
Failed comparisons, unrelated histories, and ambiguous merge bases cannot establish content preservation.
Independent publication evidence can preserve commits without proving that their content landed.
Tracked changes, unexplained untracked files, changed included private files, detached HEAD, and another checked-out branch retain their protections.
Old Git versions retain the stricter whole-file merge comparison.

`wt show --json` preserves its original `base`, counts, and merge-status fields.
Its additive `comparison` object labels the candidate and proof as cached.
Status never fetches and cannot authorize deletion by itself.

## Verify the requesting session

Codex task launches on the Mac and VMs require command-line interface (CLI) support for `--no-daemon`.
This mode keeps the runtime beneath the task's foreground process instead of reusing another terminal's shared server.
Workgrove preserves model, brief, profile arguments, sandbox settings, and approval settings.
It refuses explicit remote-server arguments for this local task mode.
Unsupported launch options and provider failures return nonzero statuses.

When launch context names a cmux row, its process sample must contain the launching `wt run` process.
A generation-bound record saves the validated owner, launcher process identifier (PID), process start identity, provider, and runtime mode.
Self-removal must verify this record against the live launcher and its process ancestry.

A foreground client above a shared server cannot supply that proof by ancestry alone.
Per-invocation environment overrides carry validated Mac row context into Codex commands.
VM relay context remains dynamic and is not frozen by these overrides.
No global configuration changes are required.

During removal, cmux process attribution identifies the agents in the target row.
Operating-system process ancestry must connect the requesting command to that agent tree.
Every attributed row process must belong to that tree or its ancestor chain before forced self-closure is permitted.
A second independent agent or command prevents that exception.
The check does not trust cmux's environment-derived caller identity.

Unknown samples, unreadable processes, and unverified shared-server ownership keep the task.
Legacy shared-server sessions can require a task-owned restart.
Workgrove never stops a shared Codex daemon as a teardown workaround.

VM self-removal pins the caller pane and verifies its process ancestry and exclusive agent ownership before accepting the named session.
Native terminal exit and legacy Mac-hook cleanup retain their existing transport paths.
The legacy path returns failure when the hook does not finish cleanup.
Receipts bind the tmux session ID, creation time, socket, server PID, and server start identity.
Recovery rejects replacement sessions even when their names match.

Exclusive ownership covers every window and pane, including independent commands.
These fixtures do not establish real provider cancellation or terminal shutdown.

## Recover incomplete cleanup

A per-task operating-system lock prevents cooperating removal commands from deleting the same generation concurrently.
A finite child command holds the lock through Git cleanup.
The command releases it before an independent session-cleanup callback runs.
Later receipt writes acquire the lock and reject a different generation.
Process exit also releases the lock, including interrupted self-closure.

The private `<name>.lock` file remains beside the receipt and can serve later generations.
Before deletion, workgrove writes a private receipt under `<repo>/.git/wt/teardown/<name>.json`.
Atomic replacement and filesystem synchronization preserve each recorded stage.
The receipt records object identities and component progress, without copying private file contents or task briefs.

Only the most recent receipt for each task name is retained.
A completed receipt can be replaced when another generation finishes.

Removal rechecks work, refs, and local row ownership after preflight.
It deletes the branch with its verified old object as the expected value.
A changed branch, branch-deletion failure, or changed sidecar retains the remaining state and reports incomplete cleanup.
Use `--keep-branch` during recovery to preserve a branch that changed after directory removal.
It does not silently discard the unexpected object or metadata.

The `removed` message confirms Git worktree removal, not complete session cleanup.
Local row absence must be confirmed before `teardown complete` is reported.
Self-closure can terminate the caller after the durable `close_requested` stage and before its final response.
A surviving caller reports failure when row closure fails.

Repeat the original `wt rm` command to resume pending cleanup after the worktree registration is gone.
Recovery rechecks row identity and running-agent ownership before closing anything.
A completed receipt makes another retry harmless.
Creation can reconcile already-absent local rows without closing anything.
The Mac can reconcile an absent VM row and session before retrying a requested task name.
Otherwise, pending cleanup blocks reuse of the task name.

Mac-controlled removal defers session cleanup until it confirms row closure.
The controller then acknowledges row absence to the VM, which validates and stops only the recorded session and its original process owners.
Legacy hooks use the same acknowledgment after closing their authenticated requesting row.
They require the VM's `teardown-receipts` capability before closing it.
A failed acknowledgment remains pending and can be retried from the Mac.

The controller flags are narrow cleanup operations:

- `--defer-close` completes Git cleanup while leaving session cleanup to the Mac.
- `--row-closed` acknowledges independently observed Mac row absence and validates the recorded VM session.
- `--observe-only` reconciles verified absence without deleting Git work or closing sessions.

These flags never waive work-preservation checks or authorize another running agent's closure.

A lock does not exclude arbitrary editors or external Git writers.
The deletion-boundary checks narrow that race but cannot atomically exclude uncooperative filesystem changes.
Stop task-owned writers before requesting teardown.
No daemon, background service, broad process killer, or automatic remote-branch deletion is added.

## Manual acceptance requires separate authorization

Disposable fixtures establish Git decisions, process-check branches, and cleanup ordering.
They cannot establish real Codex cancellation, cmux terminal exit, or socket approval behavior.
Use separately authorized disposable tasks for these checks:

1. Launch local Claude and Codex tasks through the updated installation.
2. Record their provider process trees and row identities from an independent terminal.
3. Squash-merge a task and delete its remote branch.
4. Request its safe teardown once and preserve its pre-close summary.
5. Confirm absence of its directory, registration, branch, sidecars, provider processes, and row from the independent terminal.
6. Repeat with a child whose parent squash-merges first and whose parent and child remote refs disappear.
7. Verify that unrelated rows, sessions, branches, sidecars, and main-checkout changes remain intact.
8. Repeat with native and legacy VM transports on Linux.
9. Test approval denial, then confirm that the task remains intact.
10. Interrupt a cleanup, then verify recovery through its saved receipt.

Confirm that a shared-server legacy session refuses uncertain ownership without stopping unrelated threads.
Confirm that actual terminal closure cancels task-owned background work before claiming full shutdown acceptance.
