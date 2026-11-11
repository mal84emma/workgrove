# Codex self-teardown and caller identity

This page preserves design constraints and anchors from the investigation before the runtime fix.
The [complete historical record](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) preserves the original findings, diagnostics, recommendations, and validation.
The archive's code citations identify the reviewed investigation revision.
Use [safe task teardown](task-teardown.md) for implemented behavior and current acceptance limits.

## Findings

The [archived findings](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) distinguish caller mismatch, a masked prune refusal, and a close failure after Git cleanup.
They describe behavior before the runtime fix.

## Live reproduction without teardown

The [read-only reproduction](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) preserves the stale context, permission boundary, unavailable evidence, and limits.
It did not identify the unavailable original error or prove shutdown behavior.

## Exact code path

Cmux socket authorization does not establish provider ownership from inherited environment values.
The [current ownership checks](task-teardown.md#verify-the-requesting-session) require independent launch and process evidence.

### Why the previous tests missed this

Tests that inject a matching caller identity cannot establish correct identity propagation through a real provider.
The [archived analysis](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) records the earlier fake limitation; live acceptance remains separate.

## Failure reporting also needs repair

Git worktree removal and complete session cleanup are separate outcomes.
The [current receipt contract](task-teardown.md#recover-incomplete-cleanup) reports pending cleanup after a later failure.

### A successful prune status can conceal a refusal

The [historical prune reproduction](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) preserves the misleading successful status and exact refusal.
The [current pruning contract](task-teardown.md#recover-incomplete-cleanup) distinguishes ordinary preservation skips from failed removal attempts.

### A removed line can precede a close failure

The `removed` message confirms Git worktree removal, not complete session cleanup.
The [archived late-close reproduction](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) preserves the failure output; [current recovery](task-teardown.md#recover-incomplete-cleanup) uses a durable receipt.

## Recommended bounded fix

The [current teardown guide](task-teardown.md) defines the implemented runtime, ownership, preservation, and recovery contracts.
The [archived recommendations](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) retain alternatives that the investigation did not validate.

### Prefer a task-owned local runtime

A foreground client above a shared server cannot prove exclusive ownership through ancestry alone.
The [current launcher](task-teardown.md#verify-the-requesting-session) requires supported `--no-daemon` mode and propagates provider failure.

### Bind context at task launch

Validated Mac launch context belongs to one invocation; VM relay context remains dynamic after reattachment.
The [launch contract](task-teardown.md#verify-the-requesting-session) preserves sandbox and approval settings without global configuration changes.

### Verify ownership instead of trusting an echoed hint

A selected row, directory match, provider name, or shared-server ancestor alone cannot establish ownership.
The [current ownership contract](task-teardown.md#verify-the-requesting-session) rejects unknown and competing processes.

### Report component outcomes and preserve recovery

A later close refusal must preserve pending cleanup and must not trigger an unverified forced retry.
The [current recovery contract](task-teardown.md#recover-incomplete-cleanup) keeps component progress after Git removal.

## Reproduction and acceptance

The [archived scenarios and acceptance proposal](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) preserve the initial investigation scope and unperformed checks.
Use the [maintained acceptance procedure](task-teardown.md#manual-acceptance-requires-separate-authorization) for a changed implementation.

## Validation

The [archived validation](https://github.com/mal84emma/workgrove/pull/180#issuecomment-6775477731) retains the original commands, assertion counts, timings, unavailable Ruff, and platform limits.
It establishes no current live acceptance.
