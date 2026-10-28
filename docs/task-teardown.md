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

Git ancestry uses the original objects, with grafts and replacement refs disabled for preservation checks.
A separate temporary object view performs content comparisons without source merge drivers, filters, or attributes.
Its attributes require Git's built-in text merge, which cannot use a configured replacement driver.
These checks do not alter source configuration, refs, index entries, or object files.
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
An ancestry-check error refuses removal even when the reported ahead count is zero.
Only explicit discard flags can produce a discard decision.
Independent publication evidence can preserve commits without proving that their content landed.
Tracked changes, unexplained untracked files, changed included private files, detached HEAD, and another checked-out branch retain their protections.
Old Git versions retain the stricter whole-file merge comparison.

`wt show --json` preserves its original `base`, counts, and merge-status fields.
Its additive `comparison` object labels the candidate and proof as cached.
Status never fetches and cannot authorize deletion by itself.

## Preserve working files

Removal enumerates all untracked files and submodule changes, regardless of status display settings.
It disables filesystem-monitor caching for these checks.
Assume-unchanged and skip-worktree index flags refuse removal because they can hide modified tracked files.
Workgrove does not clear those flags or change global Git configuration.

Clean filters can hide raw working bytes from Git status and the index.
New tasks capture raw fingerprints for filtered tracked files after setup.
Removal accepts unchanged creation or setup bytes, exact index blob bytes, or an independent identical main-checkout copy.
Otherwise, it refuses removal and requires inspection or an external copy.
Legacy tasks lack creation fingerprints and use the remaining proofs conservatively.
Workgrove does not archive private raw bytes into Git objects.
An incomplete filtered-file snapshot blocks removal.

Private-file snapshots compare bytes independently of filename escaping.
Link fingerprints start with `L` and hash the link target text without following it.
An unchanged setup link remains removable; retargeting it does not match identical target contents.
New private dangling links remain protected when current include patterns cover them.

New task metadata keeps `includes_status` pending until copying and fingerprint capture finish.
Failed reads, copies, hashes, or unsupported filename encoding leave that status pending and block removal.
Older sidecars without this field remain unchanged.
Explicitly empty or null copy status refuses removal; it does not mean completion.
The reader normalizes valid escaped digests from older hash commands in memory.
Malformed or unverified snapshot records refuse comparison.
Older content-only link records can require inspection because they do not establish link identity.

Creation records protect copied files after include patterns change or disappear.
Newly created ignored files depend on the current `.wt-include` patterns.

## Verify the requesting session

Codex task launches on the Mac and VMs require command-line interface (CLI) support for `--no-daemon`.
This mode keeps the runtime beneath the task's foreground process instead of reusing another terminal's shared server.
Workgrove preserves model, brief, profile arguments, sandbox settings, and approval settings.
It refuses explicit remote-server arguments for this local task mode.
Unsupported launch options and provider failures return nonzero statuses.

When launch context names a cmux row, attributed process membership normally verifies the launching `wt run` process.
An idle row can lack process attribution before its first provider starts.
A unique physical terminal can establish launch ownership through UUID surface identity and the launcher's terminal and process start identity.
This launch check does not replace later session-removal ownership checks.
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
Mac task rows start through noninteractive Bash, which executes the normal `wt run` launcher.
Cmux recognizes this nested-shell command and stops its sibling Git watcher before launching the provider.
The outer terminal shell remains available after normal provider exit.
Existing rows with independent shell watchers can require a task-owned restart.
A complete native parent graph can establish ownership of a sampled child that exits before validation.
The operating system must positively confirm that child's absence.
Unreadable processes, live PID reuse, incomplete graphs, and unverified vanished ancestors do not qualify.
Unattributed terminal PIDs remain part of self-ownership checks and cannot establish an idle row.
Unproven vanished processes trigger at most three fresh samples before refusal.
The check does not trust cmux's environment-derived caller identity.

Unknown samples, unreadable processes, and unverified shared-server ownership keep the task.
Legacy shared-server sessions can require a task-owned restart.
Workgrove never stops a shared Codex daemon as a teardown workaround.

VM self-removal pins the caller pane and verifies its process ancestry and exclusive agent ownership before accepting the named session.
An agentless shell can request its own removal when every pane process belongs to that cleanup command's ancestry or descendants.
A sibling background command or another pane prevents this shell exception.
Shell recovery records process start identities and cannot adopt arbitrary later shell descendants.
A retry can refresh the cleanup caller chain only beneath the original verified shell.
Native terminal exit and legacy Mac-hook cleanup retain their existing transport paths.
The legacy path returns failure when the hook does not finish cleanup.
Receipts bind the tmux session ID, creation time, socket, server PID, and server start identity.
Recovery rejects replacement sessions even when their names match.
Pane and window queries use the exact session-qualified target `=<session>:`.
A bare session string is unsafe for commands that expect a pane or window target.
The qualified target also prevents same-named windows from hiding another session's provider.

Exclusive ownership covers every window and pane, including independent commands.
These fixtures do not establish real provider cancellation or terminal shutdown.

## Recover incomplete cleanup

A per-task operating-system lock prevents cooperating removal commands from deleting the same generation concurrently.
A finite coordinator holds the lock through Git cleanup.
Only the coordinator holds its descriptor; Git commands and hooks inherit a control channel.
Detached hook children cannot retain the lock after the coordinator exits.
The coordinator isolates its command group and stops remaining commands before releasing the lock.
The lock file records that group and its process and boot identities while Git cleanup runs.
Stale identities cannot block an unrelated group after process reuse or restart.
Malformed lock records refuse recovery before mutation.
After unexpected coordinator death, retries refuse while its command group remains active.
The coordinator releases it before an independent session-cleanup callback runs.
Later receipt writes acquire the lock and reject a different generation.
Process exit also releases the lock, including interrupted self-closure.

The private `<name>.lock` file remains beside the receipt and can serve later generations.
Before deletion, workgrove writes a private receipt under `<repo>/.git/wt/teardown/<name>.json`.
Atomic replacement and filesystem synchronization preserve each recorded stage.
The receipt records object identities and component progress, without copying private file contents or task briefs.

Before deleting sidecars, workgrove persists the `sidecars_removing` stage and their fingerprints.
Retries accept a recorded sidecar's absence after that intent, while refusing changed replacements.
Observation cannot report completion while any sidecar remains.
Older receipts acquire missing sidecar snapshots only before deletion, while their original metadata still matches.
Recovery removes only the target registration; it does not prune unrelated missing worktrees.
The registration reader supports Git 2.34 porcelain output, including quoted paths.

Only the most recent receipt for each task name is retained.
A completed receipt can be replaced when another generation finishes.

Removal rechecks work, refs, metadata fingerprints, and local row ownership after preflight.
Branch deletion rechecks the frozen landing object or a direct preservation anchor.
Changed preservation evidence retains the branch and metadata.
It deletes the branch with its verified old object as the expected value.
The receipt freezes local branch configuration before directory removal.
A durable `branch_config_removing` stage precedes configuration cleanup under Git's configuration and task-ref locks.
Changed configuration remains pending; unrelated configuration and kept-branch configuration remain intact.
Retries accept already-absent configuration after intent.
Private hard-link anchors record each cleanup lock's inode before workgrove exposes it as a standard Git lock.
Generation and process start records let retries reclaim verified stale cleanup locks after hard interruptions.
Unknown Git locks and replacement inodes remain untouched.
Configuration replacement synchronizes the Git directory before cleanup advances.
Legacy receipts cannot delete remaining configuration without an original snapshot; `--keep-branch` preserves it explicitly.
A changed branch, branch-deletion failure, or changed sidecar retains the remaining state and reports incomplete cleanup.
Use `--keep-branch` during recovery to preserve a branch that changed after directory removal.
It does not silently discard the unexpected object or metadata.

The `removed` message confirms Git worktree removal, not complete session cleanup.
Local row absence must be confirmed before `teardown complete` is reported.
Self-closure can terminate the caller after the durable `close_requested` stage and before its final response.
Preflight checks directly invoked cleanup utilities and their selected paths before removal.
A task-local executable path refuses removal even when its symlink target is outside the task.
A surviving caller reports failure when row closure fails.

Repeat the original `wt rm` command to resume pending cleanup after the worktree registration is gone.
Recovery rechecks row identity and running-agent ownership before closing anything.
A completed receipt makes another retry harmless.
Creation can reconcile already-absent local rows without closing anything.
The Mac can reconcile an absent VM row and session before retrying a requested task name.
Otherwise, pending cleanup blocks reuse of the task name.

Mac-controlled removal defers session cleanup until it confirms row closure.
The controller then acknowledges row absence to the VM, which validates and stops only the recorded session and its original process owners.
Legacy hooks validate the recorded VM owner before closing their authenticated requesting row.
They refresh row identity and require a complete local process sample containing only the SSH transport tree.
Local agents, independent commands, and uncertain samples prevent forced closure.
The hooks use the same acknowledgment after row closure.
They independently confirm row absence before acknowledging it to the VM.
They require the VM's `teardown-receipts` capability before closing it.
A failed acknowledgment remains pending and can be retried from the Mac.
Failure notices print the safe receipt retry instead of a raw session-name kill command.
Recovery can finish the recorded original agent after a lost callback.
An added agent, independent command, or replacement session still blocks closure.

The controller flags are narrow cleanup operations:

- `--defer-close` completes Git cleanup while leaving session cleanup to the Mac.
- `--row-closed` acknowledges independently observed Mac row absence and validates the recorded VM session.
- `--observe-only` reconciles verified absence without deleting Git work or closing sessions.

These flags never waive work-preservation checks or authorize another running agent's closure.

A lock does not exclude arbitrary editors or external Git writers.
The deletion-boundary checks narrow that race but cannot atomically exclude uncooperative filesystem changes.
Stop task-owned writers before requesting teardown.
No daemon, background service, unrelated process termination, or automatic remote-branch deletion is added.

## Live acceptance on October 28, 2026

The user authorized disposable live tasks on the Mac and one Ubuntu VM.
Both hosts used cmux 0.65.1.
The VM used tmux 3.2a and a dedicated test server for the final matrix.
The tests used this candidate without updating either installed workgrove copy.

| Host | Provider | Ordinary squash | Stacked squash |
|---|---|---|---|
| The Mac | Claude 2.1.312 | Passed | Passed |
| The Mac | Codex 0.164.0 | Passed | Passed |
| Ubuntu VM | Claude 2.1.306 | Passed | Passed |
| Ubuntu VM | Codex 0.164.0 | Passed | Passed |

Each case used a disposable bare remote and actual squash commits.
The ordinary case deleted its remote head after merging.
The stacked case removed its landed parent before merging the child, then deleted both remote heads.
The child's sidecar retained its deleted creation base.

Each provider started background work through its real command tool, then waited for an independent observer.
The observer recorded provider ancestry, process start identities, session identity, and the background process before releasing teardown.
Each provider saved its pre-close summary and invoked its own safe removal from outside the worktree.
Codex used interactive sessions, workspace-write sandboxing, on-request approval, and the escalated complete removal command.
The temporary VM Codex installation included its matching official command host.
The user authorized trust entries only for the four disposable Codex repositories.
The entries were removed after acceptance; all other parsed settings remained unchanged.

The observer confirmed absence of the worktree, registration, branch, branch configuration, sidecars, row, and recorded processes in all eight cases.
The VM observer also confirmed task-session absence and survival of an independent sentinel session.
The main-checkout ref and working status remained unchanged in every test repository.
Observation-only acknowledgments completed receipts after independently verified row absence.
The controller did not issue the initial removal for these passing cases.

Claude used print mode with real Bash tools and automatic permission handling.
These cases establish actual Claude tool and process cleanup, but do not establish interactive Claude terminal behavior.
Legacy VM transport, denial of approval, and interrupted cleanup retain fixture coverage and require separate live acceptance.

An earlier shared-server probe caused tmux 3.2a to crash and closed three existing VM rows.
Their task worktrees remained intact; teardown had not started.
A dedicated-server reproduction confirmed that an unqualified pane target could trigger the crash.
Task-scoped pane and window commands now use the qualified `=session:` target.
A real Linux regression checks a colliding window name from another session on a private server.
The user authorized restoration of two verified original provider sessions, which resumed successfully.
The third row's identity remained uncertain, so it stayed closed.
The final matrix used a dedicated server to protect existing sessions.

## Manual acceptance requires separate authorization

Disposable fixtures establish Git decisions, process-check branches, and cleanup ordering.
Fixtures alone cannot establish real Codex cancellation, cmux terminal exit, or socket approval behavior.
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
