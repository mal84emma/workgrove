# Self-teardown after squash merges

This page preserves design constraints and anchors from the investigation before the runtime fix.
The [complete historical record](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775475035) preserves the original findings, diagnostics, recommendations, and validation.
The archive's code citations identify the reviewed investigation revision.
Use [safe task teardown](task-teardown.md) for implemented behavior and current acceptance limits.

## Result and incident evidence

The missing-base refusal and its exact objects belong to the [archived incident](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775475035).
That refusal established neither socket access nor session termination.

### Runtime instruction drift

Installed instructions can differ from tracked instructions until installation updates them.
The [archived comparison](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775475035) preserves the observed difference; it did not explain the missing-base refusal.

## Comparison and metadata trace

Creation provenance and the effective landing destination have different purposes.
The [destination contract](task-teardown.md#select-and-validate-a-destination) preserves creation metadata while validating current Git evidence.

### What the safety functions prove

Commit ancestry proves commit preservation; a no-op content merge proves current net content preservation.
The [current checks](task-teardown.md#select-and-validate-a-destination) reject unknown comparisons and refresh remote evidence before deletion.

## Reproduction and local probes

The [archived probes](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775475035) characterize earlier defects, including unchecked Git errors and stale publication evidence.
They are historical observations, not acceptance requirements for current behavior.

## Recommended comparison design

Candidate selection cannot manufacture a preservation verdict.
The [implemented destination design](task-teardown.md#select-and-validate-a-destination) separates provenance, current candidate selection, and Git proof.

### Select candidates without guessing

A missing parent does not justify an arbitrary `origin/main` fallback or a guessed creation object.
The [destination rules](task-teardown.md#select-and-validate-a-destination) require an unambiguous qualified candidate.

### Validate content and publication

A merged pull request or deleted remote head alone cannot authorize deletion.
The [preservation rules](task-teardown.md#select-and-validate-a-destination) validate the complete current task tip and retain a local copy for publication-only proof.

### Preserve stacked provenance

Parent landing does not prove child landing, and a commit name in JSON does not protect its object from garbage collection.
The [current metadata and recovery refs](task-teardown.md#select-and-validate-a-destination) define the implemented preservation boundary.

## Permissions and caller identity

User authorization, operating-system approval, Git preservation, and session ownership are separate checks.
Follow [safe self-removal](task-teardown.md#remove-your-own-task); never clear `CODEX_SANDBOX` to bypass its guard.

### Existing identity checks

Inherited caller context alone cannot establish exclusive ownership.
The [current ownership contract](task-teardown.md#verify-the-requesting-session) requires generation-bound launch and process evidence.

## Clean shutdown design

Worktree, branch, sidecar, command, session, and row cleanup require separate recorded outcomes.
The [current recovery contract](task-teardown.md#recover-incomplete-cleanup) distinguishes Git removal from confirmed completion.

### Proposed finite cleanup operation

Cleanup must retain private durable intent before deletion and verify identity again at each destructive boundary.
The [implemented finite operation](task-teardown.md#recover-incomplete-cleanup) defines locks, receipts, conditional deletion, and observer acknowledgments.

### Partial-failure recovery

Recovery must reject changed branches, task generations, processes, rows, and sessions.
The [implemented recovery procedure](task-teardown.md#recover-incomplete-cleanup) remains usable after worktree registration disappears.

## Focused implementation sequence

The [archived sequence](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775475035) is a historical proposal, superseded by the [implemented guide](task-teardown.md).
A comparison fallback alone cannot establish file preservation or complete shutdown.

## Regression and acceptance requirements

Fixture success cannot establish real provider cancellation, socket authentication, or terminal shutdown.
The [current acceptance procedure](task-teardown.md#manual-acceptance-requires-separate-authorization) keeps those live checks separate.

### Separately authorized manual acceptance

A historical investigation does not authorize a live shutdown test.
Use the [current authorization and acceptance procedure](task-teardown.md#manual-acceptance-requires-separate-authorization).

## Validation record

The [archived validation record](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775475035) retains commands, counts, timings, unavailable Ruff, and platform limits.
Those checks concern the investigation revision, not current acceptance.
