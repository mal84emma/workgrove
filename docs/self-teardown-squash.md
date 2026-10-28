# Self-teardown after squash merges

This investigation explains a removal refusal after a stacked task's pull request (PR) merged through a squash.
It recommends a bounded design for safe comparison and session closure.
The design is proposed, not implemented.
Changes add fixtures, this report, and its entry in the development layout; production behavior remains unchanged.

## Result and incident evidence

The incident was a missing creation base, not a general failure to recognize squash merges.
The escalated removal command executed and returned status `3`.
Automatic approval review did not reject that command.
No removal or session cleanup occurred.
The attempt establishes nothing about later socket access or session termination.

The incident brief records these objects:

| Object | Commit |
|---|---|
| Parent task head | `18ec1d2c664d31a1e79abd7b29e2ea303b6eed70` |
| Parent squash, PR #174 | `106bb8ae22729da5b9e4e6f9908ff45e32394a7a` |
| Child task head | `651233ccc300bda2e60831d3b966a0e4fecfac5d` |
| Child squash, PR #177 | `2eb478068162dfee690c94054f425e8c6c0b6066` |

Read-only local checks confirm equal trees for each head and its squash.
The parent local ref is absent.
The child sidecar still records `base: wt/issue-111-docs-drift`.
The brief reports PR #177 merged into `main` after retargeting.
No new GitHub lookup was necessary; the remote merged state remains evidence from the brief.
No existing task sidecar changed.

The following incident output is redacted only for machine-specific context:

```text
wt: refusing to remove issue-122-language-design: base 'wt/issue-111-docs-drift' cannot be compared with wt/issue-122-language-design (gone, or the literal HEAD)
```

The investigated checkout starts at the child squash above.
Function names below identify the inspected code, independently of changing line numbers.

### Runtime instruction drift

The installed and checked-in worktree-work and worktree-teardown skills match exactly.
Both teardown copies require a pre-close summary and an escalated Codex command from outside the target worktree.
Both permit authorized self-removal and prohibit closing another running agent through routine teardown.
No skill required a permission question for a validated comparison-base selection.

The installed task-driver recovery paragraph differs from [this checkout's copy](../home/.agents/skills/task-driver/SKILL.md).
The installed copy describes suspended rows, stale Secure Shell (SSH) relay cleanup, reconnection, and row selection.
This checkout instead describes a missing row and first start when both session and started marker are absent.
Runtime recovery instructions therefore must come from the installed copy until installation catches up.
This difference does not explain the missing-base refusal.
No installed skill, configuration, or permission policy changed during this investigation.

## Comparison and metadata trace

Sidecars store task metadata as JavaScript Object Notation (JSON).

| Component | Current behavior | Consequence |
|---|---|---|
| [`cmd_new`](../bin/wt) | Chooses `-b`, `--head`, or `default_base`; canonicalizes expressions; stores `base`. | A named parent remains a mutable ref name. No creation object or stack root is saved. |
| [`default_base`](../lib/workgrove/task.sh) | Tries `origin/HEAD`, then remote/local `main` and `master`, then the current branch or commit. | It is a creation convenience, not a reliable repair policy. |
| `cmd_show`, `wt_status` | Read the saved base; compare offline; report unknown counts when resolution fails. | JSON show succeeds with null counts and `merged: "?"`. |
| `cmd_pr` | Pushes to `origin`; passes the saved base, without `origin/`, to `gh pr create`. | It stores no PR identity or subsequent PR base. |
| `cmd_sync` | Reads the same base; fetches only `origin/*`; rebases or merges. | It neither discovers retargeting nor changes the saved base. |
| `cmd_rm` | Reads the base; calls `rm_reasons` before sandbox and row checks. | A missing parent causes exit `3` before deletion. |
| `cmd_prune` | Runs `rm_reasons` per task, then calls `cmd_rm` for candidates. | Dry runs retain this child for the same reason. |
| [`meta_load`, `meta_set`](../lib/workgrove/task.sh) | Cache parsed JSON; preserve unknown fields; write through a temporary file and rename. | Current writes are atomic replacements, not dependency migration or concurrent transactions. |

Sidecars contain JSON, a brief, and a started marker under `<repo>/.git/wt/`.
Creation records include hashes and setup output after their corresponding steps finish.
`cmd_run` writes the started marker; Claude uses it to resume, while Codex restarts from the brief.
Attach can change agent, model, title, or brief.
Removal deletes only the target's three sidecars after worktree and branch handling.
It neither updates dependent sidecars nor retains a completion record.
Deleting the parent's sidecar therefore removes possible stack context without repairing the child.

GitHub retargeting changed GitHub's PR record.
Neither `gh pr edit` nor a normal Git merge calls `meta_set`.
No inspected command subscribes to PR changes.
The saved creation base and the current PR base therefore diverged without any synchronization mechanism.

### What the safety functions prove

[`rm_reasons`](../lib/workgrove/safety.sh) first checks unexplained working-tree changes.
It rejects the literal `HEAD` and a base that cannot resolve to a commit.
A missing base prevents both ancestry and squash-content checks.
Changing the effective base requires selection and validation; `fetch_base` cannot select it.

`fetch_base` recognizes a remote from the first component of a shorthand such as `origin/main`.
It refreshes that branch only after the offline content check fails.
It caches success or failure for the command.
A local `wt/parent` normally has no matching remote named `wt`, so fetching cannot repair it.

A deleted remote-tracking base also fails before `fetch_base` runs if its local ref is absent.
Custom fetch mappings can leave only `FETCH_HEAD` updated; the function does not validate the compared ref's refreshed object.
Its SSH connection timeout does not bound every transport or the complete fetch duration.

`branch_landed` computes a common ancestor and checks for an empty net change.
It rejects an empty net change when its initial `diff-tree --quiet` command succeeds.
It then compares the simulated merge tree with the candidate base tree.

Git 2.38 or later uses `merge-tree --write-tree`.
Older Git uses a temporary index and a stricter file-level comparison.
The modern check can write Git objects, although it does not edit a working tree or its index.
A no-op merge proves current net content preservation, not publication of every historical commit.

`branch_landed` rejects failed merge-base, base-tree resolution, and merge-tree operations.
It rejects a reverted squash when merging would restore changes.
An ordinary ancestry merge takes a separate fast path, including when the base later reverts its content.
That path proves commit preservation, not current content equivalence.
Neither path makes a deleted remote head proof of landing.

The initial `diff-tree --quiet` guard does not distinguish changed content from a command error.
An empty-net-change branch can therefore appear landed when that comparison fails but the later simulated merge succeeds.
The dry-run comparison fixture records this unchecked error without deleting the branch or its worktree.

A missing head branch is a different failure from a missing base.
The expected `wt/<name>` must resolve before any preservation verdict.
Current `rm_reasons` does not explicitly require that resolution.
It substitutes zero when `rev-list` fails, which can suppress the commit refusal.
A missing checkout can also bypass the detached/wrong-branch checks.
The proposed design must reject unknown states instead of treating them as empty states.

`branch_pushed` checks the cached upstream's commits, then asks whether the remote has a same-named branch.
It does not compare the advertised object with the task tip.
It also assumes the remote branch has the local branch's name, rather than reading its configured merge ref.
A rewritten remote branch can therefore satisfy the current check without preserving the task's commits.
The new dry-run fixture demonstrates this limitation without deleting its worktree.

## Reproduction and local probes

Run these commands from this checkout:

```bash
bash test/wt-smoke.sh --scenario scenario_stacked_squash_base
bash test/wt-smoke.sh --scenario scenario_teardown_evidence_limits
bash test/wt-smoke.sh --scenario scenario_squash_merge
```

The scenarios use the existing scratch-root guards, isolated homes, fake cmux, and local bare remotes.
`GIT_ALLOW_PROTOCOL=file` prevents fixture Git operations from contacting a network service.
The Mac path uses a `uname` shim; this is not a Linux execution result.
No fixture addresses an existing task row or agent session.

`scenario_stacked_squash_base` creates a parent and child, then performs these operations:

1. Squash the parent into the fake remote's default branch.
2. Delete its remote head and remove the parent normally with `wt rm`.
3. Confirm that parent removal preserves the child's sidecar exactly.
4. Merge the landed parent into the child without rewriting its history.
5. Squash the child into the default branch, representing a retargeted PR.
6. Delete its remote head and prune both remote-tracking heads.
7. Confirm unknown JSON status, prune retention, and removal refusal with status `3`.
8. Confirm that this refusal precedes the sandbox guard.
9. Probe `branch_landed` against the fetched default branch without editing metadata.
10. Add an unpublished commit and confirm that the same content probe refuses it.

The direct content probe demonstrates sufficiency of a valid candidate for this graph.
It does not implement a base resolver or a teardown workaround.
The existing squash scenario retains ordinary successful removal, reverts, conflicts, post-merge work, and old-Git coverage.

`scenario_teardown_evidence_limits` records four current behaviors through dry runs:

| Setup | Current result | Required change |
|---|---|---|
| Cached upstream holds task tip; remote branch rewinds | Prune says it would remove the task. | Validate the current remote object's ancestry. |
| Cached base contains squash; remote base reverts it | Prune accepts the cached positive comparison. | Refresh remote candidates before positive decisions. |
| `rev-list` fails with status `128` | Prune treats the count as zero. | Preserve the error and refuse deletion. |
| `diff-tree --quiet` fails on an empty-net-change branch | Prune accepts the later no-op merge as preservation evidence. | Distinguish command errors from changed content before continuing. |

These assertions characterize limitations; they must change when production fixes land.
They are not acceptance criteria for the proposed implementation.
The probes retain all affected worktrees until the disposable fixture root is cleaned up.

## Recommended comparison design

Introduce one shared comparison resolver for status, removal, and pruning.
Keep creation provenance separate from the effective comparison target.
Do not silently change the base used by `sync` or PR creation.
Expose candidate source, resolved objects, refresh status, proof type, and refusal reason in status output.

Offline status must label cached evidence and must not imply a destructive decision.
Preserve existing JSON fields and add a structured comparison result rather than silently changing their meaning.
For example, retain `base` as saved metadata and report the selected ref and proof under a new `comparison` object.

The resolver should return `landed`, `published`, or `unknown`, with explicit proof objects.
`landed` permits normal task removal and verified branch deletion.
`published` preserves current pushed-only behavior after validating the actual remote object.
`unknown` blocks removal unless a separately authorized discard policy applies.
A clean worktree alone never supplies commit preservation evidence.

| Alternative | Assessment |
|---|---|
| Save only a creation commit | It preserves provenance but cannot identify where later squash content landed. |
| Replace every missing base with `origin/main` | It chooses an arbitrary remote and branch and can conceal stale evidence. Reject this policy. |
| Trust only current merged-PR state | It excludes other providers and misses post-merge commits or subsequent reverts. Require Git validation. |
| Recreate a deleted parent or edit `base` manually | It hides the original state and makes routine cleanup depend on an arbitrary repair. Reject this workflow. |
| Follow parent completion records only | It identifies candidate destinations but cannot prove child landing. Validate the complete child separately. |
| Separate provenance, candidate selection, and Git proof | It supports legacy tasks and optional provider evidence while retaining conservative refusal. Use this design. |

### Select candidates without guessing

1. Use the saved comparison ref when it remains meaningful and resolvable.
2. For stacked tasks, consider the saved stack root and validated parent completion records.
3. Consider the current PR base only when its repository and head identity match the task.
4. Consider a verified repository default only when its remote is unambiguous.
5. Refuse unresolved or conflicting candidate identities and explain the required repository configuration.

Candidate discovery must not manufacture a positive verdict.
Resolve full refs and freeze commit object identifiers before comparison.
Reject the target's own branch as a landing base.
Do not recreate the parent branch, choose the creation commit as its replacement, or overwrite the saved `base`.
A live parent can also be unsuitable after child retargeting; missing refs are not the only trigger for discovery.

For multiple remotes, prefer recorded provenance or an explicit repository landing target.
Do not assume `origin` owns the PR because a remote with that name exists.
Validate remote URLs and PR repository identity without exposing credentials in reports.

A remote's advertised symbolic `HEAD` can establish its current default branch.
An old `origin/HEAD` alone cannot establish a renamed default.
Fetch the selected branch explicitly and verify the object used for comparison.
Remote deletion, fetch success without the expected object, and stale tracking refs are insufficient.

For local-only repositories, use an explicit landing ref or an unambiguous saved local root.
A current local branch can supply Git evidence without GitHub.
Do not infer a landing base from whichever branch a different checkout happens to have selected.

Non-GitHub remotes use the same Git checks; no provider lookup is required.
On failed fetches, retain the task when the proof depends on remote freshness.
Independent local ancestry evidence can still establish commit preservation.
Cached squash evidence cannot establish the remote's current content after a possible revert.

### Validate content and publication

Require successful head resolution, base resolution, history comparison, tree creation, and tree comparison.
Never turn an error or missing count into zero.
Reject unrelated histories, ambiguous merge bases, conflicting merges, and empty net changes lacking separate preservation proof.
Use the complete current task tip, including commits made after a reported PR merge.
Retain the stricter old-Git fallback and report its limitation.

Current PR evidence can identify a destination and a landed squash object.
A `MERGED` assertion alone cannot authorize deletion.
Validate the repository, PR head, squash object, destination reachability, and task content against the current candidate.
Recheck the current task tip even when the assertion names an earlier reviewed head.
A reverted squash or subsequent unpublished work must still block content-based deletion.

Available Git evidence suffices when validated ancestry or a nonempty no-op merge proves preservation against a qualified candidate.
GitHub is optional in that case.

For pushed-only proof, read the configured remote and `branch.<name>.merge` ref.
Obtain its current object, fetch it into an isolated verification ref, and prove that it contains the frozen task tip.
Ref existence alone is insufficient.

For published-only proof, retain a local recovery ref under a documented retention policy.
Do not release the final local copy during the same operation; the remote head can disappear after verification.
List that intentional retained ref in the pre-close summary and receipt.
Do not automatically delete any remote branch during teardown.

### Preserve stacked provenance

At creation, add a metadata version, task generation identifier, creation ref, creation commit, parent generation, and landing-root provenance.
A task generation identifies one instance of a task name through an immutable random identifier.
An object name in JSON does not protect it from Git garbage collection.
Use narrow workgrove-owned anchor refs for objects that must remain available.
Document their retention and remove them only when no dependent task needs them.

Parent completion should retain a small record containing the verified parent tip, landing target, landing object, and proof type.
Copy the root provenance into the child at creation, so parent removal needs no dependent-sidecar rewrite.
Validate each parent transition and detect cycles or missing generations.
A parent landing does not prove that the child's additional work landed.
Always validate the complete child against the effective destination.
A historical parent receipt does not override a later revert or destination change.

For legacy sidecars, preserve `base` exactly and mark creation objects unknown.
Do not invent a creation commit from today's mutable parent ref.
Resolve a legacy task through independent, current Git evidence when that evidence is sufficient.
Otherwise retain it and report the missing provenance or ambiguous landing target.
Write additive migration fields atomically under a task lock, preserving unknown keys and all include/setup records.
Do not scan and rewrite unrelated task sidecars during teardown.

## Permissions and caller identity

The user's request authorizes routine safe removal and closure of that task's own session and row.
It does not authorize discarding work or closing another task's session.
Operating-system permission review remains separate from that authorization and from Git preservation checks.
The Mac runs cmux; a virtual machine (VM) hosts remote tasks.

| Operation | Possible boundary | Current handling |
|---|---|---|
| Read status and metadata | Repository readability | A missing comparison produces unknown status or a refusal. |
| Simulate a merge or fetch | Git common-directory writes; network and credentials | Content simulation can write objects before the sandbox guard. |
| Remove directory and registration | Worktree filesystem and main `.git/worktrees` | Changing directories does not expand sandbox write access. |
| Delete branch, sidecars, or prune | Main `.git/refs`, packed refs, logs, and `.git/wt` | These paths can lie outside the task's writable root. |
| Query or close a local row | cmux socket and authenticated process ancestry | Checked before removal; close can still fail afterward. |
| Query or stop a VM session | tmux socket; SSH transport; session termination | Native and hook paths have different close ordering. |
| Close the caller's own row | Agent/session termination review | The incident never reached this operation. |

`cmd_rm` rejects a nonempty `CODEX_SANDBOX` before destructive removal, even when no row exists.
The marker is a conservative application guard, not an operating-system permission probe.
Do not unset it to bypass the guard or modify installed approval policy.
An authorized Codex caller should submit one narrowly described escalated teardown command.
Automatic review can still deny it; denial must leave the task intact and receive an accurate report.
Do not request another user decision merely to replace a validated effective base.

[OpenAI's security documentation](https://learn.chatgpt.com/docs/agent-approvals-security) separates sandbox enforcement from approval policy.
The [command-line interface (CLI) reference](https://learn.chatgpt.com/docs/cli/reference) documents automatic review and the interactive exit command.
Installed `codex-cli 0.164.0` help confirms `--approve-for-me`, sandbox modes, and shared app-server sessions.
`codex agents --help` offers browsing; `codex archive --help` describes archiving saved sessions.
No inspected help establishes that archiving stops a running turn or that terminal closure cancels daemon work.
Those properties need acceptance evidence before claiming complete Codex shutdown.
Do not stop the shared Codex daemon or delete session history as part of task cleanup.

The [App Server documentation](https://learn.chatgpt.com/docs/app-server) defines cancellation through `turn/interrupt` with exact thread and turn identifiers.
It defines archiving separately and marks background-terminal cleanup methods experimental.
Schema generation from installed CLI `0.164.0` confirms `turn/interrupt`, `thread/archive`, and `thread/unsubscribe` without contacting a daemon.
This supplies a possible targeted cancellation mechanism, not evidence of terminal-close behavior.
An independent cleanup caller could request cancellation and wait for the matching `turn/completed` event before confirming provider shutdown.
Its authenticated connection, task-to-thread binding, background-command ownership, and behavior during self-removal still require fixture and live validation.

### Existing identity checks

[`check_row_removal`](../lib/workgrove/cmux.sh) enumerates every window with validated row data.
It checks matches by task title and description, unclaimed title, and local worktree directory.
It refuses another running agent and unknown status.
A row found only by its directory is never selected for closure.
A missing CLI or socket is tolerated only under specific outside-cmux conditions.
An access-denied response is not equivalent to an absent socket.

`row_agent` uses `cmux top` and its caller workspace identity.
A matching caller workspace is `self`; another row with coding-agent processes is `busy`.
The [Codex follow-up](codex-self-teardown.md) reproduces a stale caller environment that misclassifies this investigation's own row.
That report also distinguishes environment-supplied identity from verified session ownership.

This compares advertised row context; it does not prove session membership or exclusive process ownership.
It does not compare a saved task process identifier (PID) with the calling shell's PID.
Multiple agents in one caller row require additional checks before claiming safe exclusive shutdown.

VM self-removal compares `tmux display-message -p '#S'` with the deterministic task session name.
The command currently relies on the client's default target and does not pin a verified caller pane or PID chain.
Other-session removal uses `tmux_agent`, which scans pane terminals for exact `claude|codex` process names.
Unknown tmux or process-query results refuse removal.
A matching session bypasses that scan, so another agent in the same session needs new coverage.
Daemon-backed agents also require evidence beyond terminal process names.

## Clean shutdown design

Keep worktree removal, branch cleanup, sidecar cleanup, session exit, and row closure as separate recorded outcomes.
The current `removed` line confirms worktree removal; it precedes terminal cleanup.
Local row-close failure returns nonzero after the worktree and sidecars are gone.
Legacy VM cleanup can warn about an open session yet return success.
Some branch and tmux deletion errors are ignored.
There is no durable transaction or restartable cleanup command today.

`cmd_run` keeps a foreground provider process under `wt`; an ordinary provider exit leaves the row's shell available.
Local removal requests terminal closure instead of explicitly invoking a provider exit command.
Changing the removal shell's directory does not change the provider's directory or any background command's directory.
Loaded shell functions can survive source deletion, but later executable lookup, hooks, or library reads can still fail.
Current removal does not preflight that every later executable remains available outside the target.

| Path | Current order | Evidence and limit |
|---|---|---|
| Local Claude or Codex | Check row; remove Git state and sidecars; close own row with cmux `--force`. | Fake rows test both agents. Terminal/process exit remains untested here. |
| Native VM self-removal | Check session marker; remove Git state; kill exact tmux session. | `WT_CMUX_CLOSE_ON_EXIT=1` selects this path. `tmux_cmd` executes its client so terminal exit closes the Mac row. |
| Older VM self-removal | Check relay; remove Git state; request `wt-close`; wait. | Mac hook checks absence, closes the requesting row, then stops tmux. Unanswered requests leave cleanup incomplete. |
| Mac removing an idle VM task | Check row and remote agent; remote removal; close Mac row; stop session. | Running remote agents refuse. This is not the self-removal path. |

The [Mac hook](../bin/cmux-hook) authenticates native notification ownership and checks task/host/repository identity.
It verifies remote worktree absence through the result protocol before closing.
Closing a legacy SSH row before stopping tmux prevents that row from recreating the session.
The [recovery helpers](../lib/workgrove/recovery.sh) check prompt and client identity before reattachment.
Existing recovery cannot retry removal after the worktree registration disappears.

### Proposed finite cleanup operation

The intended interface remains one ordinary `wt rm <name> -r <repo>` command from outside the target worktree.
For sandboxed Codex, submit that complete command through the authorized escalation path once.
The command must select and validate its effective base without a separate sidecar-edit permission question.

1. Print the branch, commits, tests, exact cleanup scope, and expected interruption before self-closure.
2. Run from a stable directory outside the target, using an executable and libraries outside the target.
3. Acquire a per-task lock and identify the repository, task generation, registration, branch, caller, row, and session.
4. Preflight required executables, sockets, receipt storage, transport, and the cleanup route before any removal.
5. Freeze and validate the head, effective base, working state, include hashes, and preservation proof.
6. Write a durable private receipt outside the removed worktree before deleting anything.
7. Revalidate identity and work immediately before removal; stop on any changed state.
8. Remove the worktree, then delete only the verified branch object and target sidecars.
9. Record completed Git cleanup before requesting session and row closure.
10. Close the verified session and row through the appropriate existing transport.
11. Confirm absence from an independent observer, or record closure as pending rather than complete.

Use `<repo>/.git/wt/teardown/<generation>.json` for receipts and a private directory mode.
Store paths, exact object names, proof source, component states, failure diagnostics, and recovery identity.
Never store copied private-file contents, credentials, or the full task brief.
Use atomic writes and explicit flushes where crash durability is required.
Refuse deletion if the receipt cannot be persisted.
Keep incomplete receipts until recovery finishes; define bounded retention for completed records.

Use compare-and-delete semantics for branch refs, with the verified old object as the expected value.
If a ref changes, retain it and report partial cleanup.
Do not hide branch deletion failures behind a successful `removed` message.
Retain anchors needed by dependent tasks and leave their metadata unchanged.
Reject ref/path reuse by requiring the task generation, not just its name.

A lock prevents two cooperating `wt` commands from removing the same generation.
It cannot prevent an editor or unrelated Git process from writing during cleanup.
Drain task-owned background commands and verify exclusive agent ownership before the final snapshot.
Recheck files, index, refs, registration, and session identity at the deletion boundary.
Retain a recovery ref through that boundary and use expected-object deletion.

Do not claim that these checks atomically exclude arbitrary external filesystem writers.
A strict no-loss guarantee under concurrent uncooperative writes requires preserving a final directory snapshot or refusing cleanup.
Snapshot retention and private-file handling need explicit design before that stronger guarantee is advertised.

A self-closure tool call may disappear before returning.
Mark `close_requested` durably before the final close request.
The initiating process cannot reliably record its own confirmed death afterward.
Extend the existing Mac hook or an explicitly invoked finite observer to record confirmed row/session absence.
Preserve the hook's authenticated process ancestry; its comments document failure when detached children lose that authorization.
Do not introduce a new persistent daemon, broad process killer, or arbitrary shell-command relay.

A local hook extension would need a distinct authenticated request with task generation and receipt identity.
It must validate a local row instead of reusing the current VM-only event validation unchanged.
For native VM closure, a Mac observer must confirm terminal exit and independently verify the VM session's absence.
Without that observer, receipts remain pending until a later status/recovery invocation verifies them.
Transport loss must never imply successful closure.

Capture caller process start identity, terminal, pane/session identity, and provider session identity when supported.
A row UUID or inherited environment value alone is insufficient to kill a process.
Do not send `/exit` into an agent prompt while it might interpret input as another instruction.
Use a supported provider exit mechanism only after its target and command completion semantics are established.
Otherwise use the existing verified terminal-close path and keep provider shutdown explicitly unverified until acceptance passes.
Preserve unrelated daemon sessions and provider transcripts.

If provider cancellation stops the initiating tool, the independent cleanup caller must already own the durable cleanup operation.
Otherwise interruption could leave partially removed Git state or an open row.
Do not interrupt the caller first and expect its tool command to finish cleanup afterward.

### Partial-failure recovery

A proposed status/resume interface should accept the receipt generation even when the worktree is absent.
Its name is not defined by this investigation.
Recovery should verify each remaining component and retry only incomplete authorized cleanup.
It must refuse to close a reused row or session, or delete a branch whose object changed.
An absent component is complete only when its identity and absence are verifiable.
Missing socket access, uncertain processes, or unavailable executables retain the pending receipt with a concrete recovery command.

Preserve exit `3` for work-preservation refusals.
Reserve a distinct nonzero outcome for cleanup that failed after removal, alongside component states in the receipt.
Report status `0` as complete only when required components are confirmed absent.
If self-closure prevents a command result, the observer or later receipt query supplies that confirmation.

A failure before removal leaves the task intact.
A failure after worktree removal reports that success separately from retained branch, sidecar, session, or row cleanup.
An interrupted cleanup preserves its receipt and recovery refs.
The next invocation must inspect current state rather than replay destructive steps blindly.

## Focused implementation sequence

1. Make Git checks fail closed; validate pushed objects and fresh remote comparison objects.
2. Add the shared resolver and additive metadata, without changing sync or PR targets implicitly.
3. Add parent provenance and completion records with dependency-aware anchor retention.
4. Add locked receipts, conditional ref deletion, and restartable partial cleanup.
5. Strengthen caller ownership and preflight, then add observed shutdown completion through the existing hook.
6. Update JSON/status documentation and teardown instructions for one authorized command and precise pending outcomes.
7. Run the full suite, lint checks, and separately authorized live acceptance before advertising complete self-shutdown.

Keep each step reviewable and test its failure paths before integrating the next step.
Fixing only the missing-base fallback would leave the independently reproduced preservation gaps intact.
Manual sidecar edits and broad discard flags should not become the routine path.
An explicit landing-target configuration is preferable when repository evidence remains ambiguous.

## Regression and acceptance requirements

The existing scenario registry discovers the new tests through the same local and CI runner.
Existing fixtures cover many refusal and transport paths, but they do not establish every requirement below.

| Case | Existing evidence | Required acceptance |
|---|---|---|
| Ordinary squash; remote head deleted | `scenario_squash_merge` | One authorized teardown removes all target components. |
| Parent then child squash; both heads deleted | New stacked fixture | Resolve destination without sidecar edits or repeated questions. |
| Tracked edits and untracked files | Refusal and include/setup scenarios | Refuse before any removal or close request. |
| Changed copied files and new private include files | Include/setup scenarios | Preserve bytes, including after main-checkout source changes. |
| Arbitrary ignored private files | Current policy treats unlisted ignored files as disposable output. | Document that limit; do not imply universal private-file protection. |
| Unpublished post-merge commits | Squash scenario and new content probe | Preserve branch, worktree, and session. |
| Detached HEAD or wrong branch | Refusal scenario | Refuse, regardless of a landed expected branch. |
| Missing head, unreadable status, comparison error | New count-error dry run exposes a gap. | Refuse unknown state; preserve registration and sidecars. |
| Unrelated or ambiguous histories, empty net changes | Squash coverage is partial. | Reject unrelated histories and ambiguous candidates, even with equal trees. |
| Reverted squash or later conflicting edit | Squash scenario | Compare current content; reject stale positive evidence. |
| Failed fetch, offline mode, custom fetch mapping | Existing squash coverage is partial. | Retain remote-dependent tasks unless independent preservation proof exists. |
| Local-only, non-GitHub, multiple remotes, renamed default | New design only | Prove deterministic selection or explicit ambiguity refusal. |
| Stale upstream or rewritten remote head | New dry-run evidence fixture | Require advertised object containment, not name existence. |
| Another agent or uncertain process state | Local/VM refusal fixtures | Refuse another agent, including another agent in the caller row/session. |
| Missing socket or approval denial | Socket failures and sandbox marker fixtures | Denied approval must invoke no destructive command; fake markers cannot prove this. |
| Row close or tmux termination failure | Local close failure and legacy wait fixtures | Persist partial outcomes and permit receipt-based recovery. |
| Interrupted cleanup and reused task name | Temporary-file signal tests cover only part. | Inject interruption after every destructive step; reject identity reuse. |
| Concurrent ref/file changes | No complete current coverage | Freeze, revalidate, conditionally delete, and preserve recovery evidence. |
| Unrelated rows, sessions, branches, main changes, dependents | Existing row fixtures cover part. | Assert exact preservation of every unrelated component and dependent sidecar. |

The three flags named `--force` serve different purposes.
User-facing `wt rm --force` discards preservation checks and requires explicit authorization.
Internal `git worktree remove --force` removes ignored output after workgrove checks.
cmux `--force` skips confirmation only for a verified own row or newly created row.
Internal squash branch deletion requires validated landing evidence; it is not user authorization to discard work.

### Separately authorized manual acceptance

This investigation does not authorize any live shutdown test.
Use newly created disposable tasks only after a separate request authorizes the exact test tasks and their closure.
Do not use an existing task as a substitute.

1. Prepare disposable ordinary and stacked squash tasks with deleted remote heads.
2. Record unrelated rows, sessions, branch objects, dependent sidecar hashes, and main-checkout changes.
3. Give one teardown request to each task's own agent, first for local Claude and local Codex.
4. Repeat on a VM through a current native row and a supported legacy cleanup route.
5. Confirm the pre-close summary appears before the row closes.
6. Confirm the worktree directory, Git registration, intended branch, and target sidecars are absent.
7. Confirm the exact agent's running commands end and its provider session no longer runs a turn.
8. Confirm the target tmux session and row are absent and remain absent after reconnect opportunities.
9. Confirm a durable completed receipt or a truthful pending receipt with a working recovery command.
10. Compare unrelated components and dependent metadata with their recorded values.
11. Repeat with a controlled cleanup failure and verify safe recovery after the worktree disappears.

Approval-denial acceptance requires a controlled denied command and must show that no deletion ran.
Do not change installed approval policy to manufacture that result.
Provider daemon behavior, real socket authentication, terminal exit, and VM shutdown need live evidence.
A fake successful close response cannot establish them.

## Validation record

This record describes the initial investigation; the [Codex follow-up](codex-self-teardown.md#validation) records the later checks.

The final checks ran on the Mac with Bash `5.3.20`, Apple Git `2.39.3`, Python `3.9.6`, and ShellCheck `0.11.0`.

| Check | Final result |
|---|---|
| `bash test/run.sh` | All 79 tasks across 22 suites passed. |
| `bash test/run.sh test/wt-smoke.sh` | All 21 worktree scenario tasks passed. |
| `ONLY='6[bcd].*' WT_BASH=/bin/bash bash test/run.sh test/wt-smoke.sh` | All three squash scenarios passed through the Bash 3.2 startup handoff. |
| Full repository ShellCheck command from `.github/workflows/tests.yml` | Passed with `shellcheck -x`. |
| `bash test/docs-smoke.sh` | All six documentation assertions passed. |
| Documentation guide's nine required `grep` commands | Each printed at least one line. |
| `git diff --check` and `git diff --cached --check` | Passed. |
| Changed-prose checklist, sentence/paragraph review, and relative links | Reviewed; local links and anchors passed the documentation suite. |
| `ruff check --select F,E9 lib test` | Not run: Ruff is unavailable. No Python files changed. |

The clean full run ended with this exact output:

```text
total wall time: 149.384 s; 79 tasks, 0 failed
```

CI also runs suites on Ubuntu 22.04, Ubuntu 24.04, and Python 3.9, with separate ShellCheck and Ruff checks.
No result in this document represents a live session closure, a Linux run, or a CI run.
The official ASD-STE100 Issue 9 download returned HTTP `403` during review.
The repository writing checklist remains applicable; this document does not claim full standard conformity.
