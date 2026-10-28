# Codex self-teardown and caller identity

This follow-up investigates a Mac Codex session that could not recognize its own task during teardown.
The original error is unavailable.
A read-only live check reproduces a caller-context mismatch in this investigation's session.
Disposable fixtures reproduce the resulting refusal and two separate reporting problems.
This investigation adds evidence and tests; it does not change production teardown or installed configuration.

## Findings

| Finding | Evidence | Consequence |
|---|---|---|
| Shell caller context can identify another task. | The investigation's shell reported a different row from the row matching its task title and path. | `row_agent` classified the investigation's row as `busy`. |
| cmux caller context comes from environment values. | The installed cmux version's source reads `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` into the request. | A successful socket request can carry stale task identity. |
| Workgrove calls a mismatch another agent. | `row_agent` tests caller equality, then positive process counts. | Missing or stale context produces a misleading refusal. |
| Pruning can report success after that refusal. | A disposable candidate remains intact while `wt prune` returns `0`. | Exit status alone does not establish cleanup completion. |
| Row closure can fail after Git cleanup. | A fixture returns `confirmation_required` after `removed late`. | The worktree is gone, but the command still fails and its row remains pending. |

These findings reproduce concrete failure mechanisms.
They do not establish which mechanism produced the unavailable historical error.
The earlier [squash investigation](self-teardown-squash.md) concerns a different refusal that stopped before row checks.

## Live reproduction without teardown

The check used installed cmux `0.65.1`, build `110`, revision `8a853dcc9`, with the Codex command-line interface (CLI) `0.164.0`.
It queried row metadata and process status; it did not call removal, close a row, or send terminal input.
Machine paths, row identifiers, unrelated task names, and process identifiers are omitted here.

The shell's working directory remained this investigation's worktree.
Its inherited `CMUX_WORKSPACE_ID` instead identified an older task's row.
Its `CMUX_SURFACE_ID` also identified that older row's terminal.
The row matching this investigation's title and directory had another identifier.
Changing the command's directory does not change those environment values.

A direct call to the existing `row_agent` function returned:

```text
target_classification=busy
environment_matches_task_row=false
```

The process ancestry included a Codex App Server without a terminal, under an older Codex client with a terminal.
This supports shared-server environment inheritance as a source of the mismatch.
It does not prove when the stale values entered the server, thread, or command environment.
No per-thread snapshot existed at the conventional shell-snapshot path checked during this investigation.
The session-record lookup returned no matching record, so it did not establish an independent thread-to-row binding.

The focused row differed from the inherited caller row during inspection.
The scoped `top` response retained the inherited caller identity despite that focus difference.
Focus is therefore not evidence of the requesting task's identity.

A sandboxed socket query failed with an operating-system permission error.
The same read-only query succeeded through escalation and exposed the identity mismatch.
Socket permission and caller identity are separate boundaries.
This reproduction did not receive an automatic approval denial.

## Exact code path

[`cmd_run`](../bin/wt) launches Codex with its model, profile arguments, and brief.
It does not currently pin local cmux identity in Codex's per-session shell configuration.
The [baseline config](../home/.codex/config.base.toml) uses `shell_environment_policy.inherit = "all"`.
Inheriting an environment does not establish that its values belong to the current thread's terminal.

In the installed cmux revision, `treeCallerContextFromEnvironment` reads the two cmux identity variables.
`buildTopPayload` sends that caller context separately from the target workspace.
The [version-pinned CLI source](https://github.com/manaflow-ai/cmux/blob/8a853dcc9/CLI/cmux.swift) defines both functions.
A target workspace argument chooses the inspected row; it does not repair caller context.
This explains how a correctly targeted query can report an unrelated caller.

[`row_agent`](../lib/workgrove/cmux.sh) performs these checks:

1. Query `cmux top --workspace <target> --json`.
2. Require nonnegative coding-agent process counts.
3. Return `self` when `.caller.workspace_id` equals the target.
4. Otherwise return `busy` when any coding-agent process count exceeds zero.
5. Otherwise return `idle`.

A missing caller and a stale caller both fail step 3.
Step 4 does not distinguish either case from a verified external caller.
For a matched task row, `check_row_removal` then emits this fixture diagnostic:

```text
wt: another agent is running in cmux row requester-row; kept the worktree
```

The guard keeps the worktree, branch, registration, and sidecar.
That conservative behavior is correct while ownership remains uncertain.
Calling the blocker another agent overstates the evidence and can prompt unnecessary permission questions.
The requesting agent is not offered a separate state for unverified caller context.

Conversely, stale context that names the target can satisfy the self check from another requesting thread.
The equality test alone therefore supports both false refusals and mistaken self attribution.
cmux socket authorization does not convert environment-supplied row identity into verified provider-session ownership.
Do not repair this by setting the caller to whichever task the removal command names.

A positive process count establishes detected processes, not a count of independent agent conversations.
A client and its server can contribute multiple processes.
The follow-up does not infer another user session merely from a count greater than one.

### Why the previous tests missed this

The existing self-removal tests inject `CMUX_STUB_CALLER=own-<agent>` before expecting success.
[`fake_top`](../test/fakes/rows.sh) writes that supplied identity directly into `.caller.workspace_id`.
The tests correctly check the branch that handles a matching identity.
They do not model a shared server that retains a different terminal's environment.
They also do not verify that Codex's command environment receives the new terminal's identity.

`scenario_codex_caller_context` now records the mismatch, missing caller, and corrected-context cases.
The corrected case proves which workgrove decision changes when context is accurate.
It does not prove that a proposed Codex launch configuration repairs a real shared server.

## Failure reporting also needs repair

### A successful prune status can conceal a refusal

[`cmd_prune`](../bin/wt) first identifies a clean, preserved candidate.
It calls `cmd_rm` in a subshell.
When `cmd_rm` refuses because the row appears busy, pruning prints a keep message and continues.
Its final `git worktree prune` can return `0`, which becomes the command's status.

The fixture sees status `0` and this exact line:

```text
keep requester (removal refused above)
```

An agent that checks only the status can incorrectly report successful teardown.
A dry-run candidate result also does not establish that the later row guard will permit removal.
Normal skipped tasks and failed removal attempts need distinct machine-readable outcomes.

### A removed line can precede a close failure

`cmd_rm` prints `removed <name>` after Git cleanup but before closing the local row.
`close_row` supplies cmux's confirmation override only when the caller is classified `self` or `new`.
If status sampling misses an agent, or another process requires confirmation, an unverified caller receives no override.
cmux can then refuse closure after the worktree, branch, and sidecars disappear.

The fixture returns status `1` with these exact output lines:

```text
removed late
wt: could not close cmux row late-row: Error: confirmation_required: Workspace has a running process; retry with --force
on the Mac: cmux workspace close late-row
```

That is successful worktree removal followed by failed row cleanup.
It is not the earlier busy-row refusal, which preserves the worktree.
A normal `wt rm` retry cannot recover this state because the registration is already gone.
The fixture confirms that retry fails with `no worktree named 'late'`.

The new confirmation fixture separates agent discovery from close confirmation.
Previously, `prepare_cmux` derived confirmation requirements only from the same agent count used during discovery.
That coupling hid disagreement between the two observations.

## Recommended bounded fix

### Prefer a task-owned local runtime

First evaluate launching local workgrove Codex tasks with the installed CLI's `--no-daemon` mode.
That mode avoids reusing a background server belonging to an earlier terminal.
It also fits `cmd_run`'s existing expectation that its foreground provider process belongs to the task row.
The shared-server path needs additional ownership and shutdown integration beyond environment repair.
No custom daemon or service is needed for this candidate fix.

Preflight CLI support before launch and before creating the started marker.
Do not silently ignore an unsupported option or stop an existing shared server.
Preserve existing model, brief, profile, sandbox, and approval arguments.
Treat an explicit remote-server profile as a separate supported mode, not an implicitly task-owned runtime.
Validate the resulting command environment and real shutdown behavior before changing the default launcher.

Propagate provider launch failures; `cmd_run` currently warns about a provider failure and returns `0`.
Include unsupported flags and provider startup failures in launcher acceptance coverage.

### Bind context at task launch

For local Codex tasks, capture the validated terminal's row, surface, and socket in `cmd_run` before starting the provider.
Confirm that the row identifies the intended repository and task generation.
Pass those values as per-invocation `shell_environment_policy.set` overrides.
Do not write them into global configuration or a shared profile.
Do not replace existing environment exclusions or alter sandbox and approval settings.

[OpenAI's configuration documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#shell-environment-policy) defines explicit environment values and their filter precedence.
The same document supports dotted `-c` command-line overrides.
A prototype launcher should build separate argument-array entries, with correctly encoded TOML strings.
For example, `shell_environment_policy.set.CMUX_WORKSPACE_ID` supplies the launch row to spawned commands.
Surface and socket values need equivalent per-invocation treatment.
A configured include allowlist can still remove those values, so validate the resulting command context.

The installed CLI also supports `--no-daemon` for running without the shared background server.
The [CLI reference](https://learn.chatgpt.com/docs/cli/reference) documents command-line configuration; installed help establishes this version's `--no-daemon` option.
Per-session injection is an alternative for retaining shared-server operation, provided its ownership and shutdown contracts also pass acceptance.
It does not authorize stopping an existing shared daemon.
No real provider launch was performed to validate either alternative in this investigation.

Keep this first change local to Mac task launch.
Workgrove refreshes relay identity on a virtual machine (VM) during reattachment through separate helpers.
Do not freeze VM relay fields using a local-only fix.

### Verify ownership instead of trusting an echoed hint

Launch-time injection addresses accidental inheritance but does not itself establish session ownership.
Record a task generation, validated row/surface, provider session identity, and process start identity when the provider starts.
Bind later self-teardown requests to that generation and provider session.
Verify the row still contains the intended session and no unrelated agent that closure would terminate.
Do not use the selected row, directory match, provider name, or an ancestor of a shared server as sole ownership proof.

Expose distinct `self`, `other`, `unknown`, and `idle` states.
When a detected agent needs a self exception and context is missing or contradictory, keep the task and name the uncertainty.
If another session is verified, retain the current prohibition on closing it through routine teardown.
Only a verified self request may use cmux's confirmation override without another permission question.
The user's existing teardown request already authorizes that narrow self closure.

For sessions started before this binding exists, retain conservative refusal when no independent ownership proof is available.
Do not repair existing sidecars with a guessed caller identity.
A capability for one task generation must not authorize another generation or a reused row.

### Report component outcomes and preserve recovery

Return explicit removal and closure outcomes to agents.
For a preflight refusal, report `worktree_removed=false` and a reason such as `caller-context-unverified`.
For a later close failure, report `worktree_removed=true`, `row_closed=false`, and `cleanup_incomplete`.
Do not let the earlier removed line imply full teardown completion.

For attempted prune removals that fail, preserve the error in an aggregate result and return a nonzero status.
Keep ordinary skipped tasks separate from failed attempts.
Add regression assertions for the new status contract before changing it.
Document the contract change for callers that currently treat pruning as unconditional best effort.

Use the [durable cleanup receipt design](self-teardown-squash.md#partial-failure-recovery) to recover after registration removal.
Preflight the authenticated close route before deleting work.
A later confirmation refusal must preserve its pending receipt and must not trigger an unverified forced retry.
Preserve the pre-close user summary because successful self closure can end the command and agent session.

Update the checked-in teardown skill with these outcome distinctions after the runtime interface exists.
Installed skills will retain their current behavior until explicitly updated through the normal installation workflow.
This investigation changed no installed skill or permission policy.

## Reproduction and acceptance

Run the new disposable scenarios from this checkout:

```bash
ONLY='8[cd].*' bash test/run.sh test/wt-smoke.sh
```

The scenarios use isolated repositories, homes, a Mac shim, and the existing fake cmux.
They do not address a live row or provider session.
The first scenario checks preservation on refusal, unchanged behavior after `cd`, masked prune failure, and corrected-context self closure.
The second checks a late confirmation failure, completed Git cleanup, lack of an unsafe forced close, and failed normal retry.

A separately authorized live acceptance run must use disposable tasks and preserve all existing sessions.
Start a Codex task in row A, then another in row B while A's server remains available.
From both tasks, compare launch bindings with command context before any teardown.
Exercise normal and escalated command execution without changing focus as a repair.
Verify that B receives B's context and cannot claim A through the shared server.
Then authorize B's self-teardown once and confirm its row, commands, and provider turn terminate while A remains intact.

Repeat after starting a fresh server and after reconnecting or resuming a client.
Check include-filter behavior and supported shell-snapshot behavior.
Check an actual different requester, missing context, multiple agents in one row, and stale task generations through fixtures first.
Use receipts to test a controlled close failure and recovery after the worktree disappears.
No result here establishes real terminal shutdown, Linux behavior, or a CI result.

## Validation

All checks ran locally on the Mac.
The two new scenarios make 35 assertions across caller-context and late-close behavior.
The full runner includes existing local Claude, local Codex, VM, socket-failure, and native-relay fixtures.
Those fixtures do not establish live provider shutdown.

| Check | Result |
|---|---|
| `bash test/run.sh` | All 81 tasks across 22 suites passed. |
| `ONLY='8[cd].*' bash test/run.sh test/wt-smoke.sh` | Both new scenarios passed; 35 assertions passed. |
| `ONLY='8[cd].*' WT_BASH=/bin/bash bash test/run.sh test/wt-smoke.sh` | Both passed through the Bash 3.2 startup handoff. |
| Full repository ShellCheck command from `.github/workflows/tests.yml` | Passed. |
| `bash test/docs-smoke.sh` | All six documentation assertions passed. |
| Documentation guide's nine required `grep` commands | Each printed at least one line. |
| Changed prose, relative links, anchors, and Git whitespace checks | Reviewed and checked. |
| Ruff | Unavailable; no Python files changed. |

The full run ended with this exact output:

```text
total wall time: 155.882 s; 81 tasks, 0 failed
```

No existing task sidecar, provider configuration, permission policy, or running session changed.
The proposed launcher and ownership fixes remain unimplemented and require separately authorized live acceptance.
