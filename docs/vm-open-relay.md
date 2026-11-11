# VM requests after cmux 0.65

This page explains how VM tasks request VS Code windows and task rows on the Mac.
It records the cmux 0.65 regression and the verified fix.
[Agent status in VM rows](vm-agent-status.md) covers the status that a VM row shows.

The [cmux integration contract](cmux-integration.md) lists the commands, fields, and measured behavior.
The [Mac–VM protocol](vm-protocol.md) defines remote commands, records, requests, and the tmux environment.

Use the [cmux update checklist](cmux-checklist.md) after each cmux update.

## Cause

cmux 0.65.0 (108), commit `dda24fbd2`, uses `cmux-tui` for new SSH rows.
Those rows supply `CMUX_TUI_SOCKET` and `CMUX_TUI_TERMINAL_ID` instead of the old TCP relay variables.
Before native request support, the `wt` sender accepted only TCP sockets.
It stopped before sending a notification:

```text
wt: no cmux relay socket in this session; run the line below on the Mac
```

The [original diagnostic evidence](https://github.com/mal84emma/workgrove/pull/20#issuecomment-6775483639) identifies the installed TCP-only sender and its checksum.

Sending through `cmux-tui notify` reaches the Mac's notification list.
However, that delivery path bypasses `notifications.hooks` in cmux 0.65.
[CloudNotificationLocalDelivery.swift](https://github.com/manaflow-ai/cmux/blob/v0.65.0/Sources/Cloud/CloudNotificationLocalDelivery.swift) calls `addNotification` without resolved hooks.
[TerminalNotificationStore.swift](https://github.com/manaflow-ai/cmux/blob/v0.65.0/Sources/TerminalNotificationStore.swift) substitutes an empty hook array for a remote origin.

At that time, local notifications ran `cmux-hook` through the repository's `notifications.hooks` configuration.
They supplied the `CMUX_NOTIFICATION_*` fields and a version-1 JSON envelope.
The [0.65 schema](https://raw.githubusercontent.com/manaflow-ai/cmux/v0.65.0/web/data/cmux.schema.json) still accepts the existing notification hook configuration.
The hook's event names and configuration did not cause this failure.

A second identity problem occurs when tmux starts new panes from an existing server.
The pane can inherit another row's `CMUX_TUI_TERMINAL_ID`.
The fix records the current row's native identity in its task's tmux session before attachment.

## Fix

`wt` sends native requests with `cmux-tui`, the explicit socket, and the current session's terminal ID.
TCP relay rows are no longer supported.
Each native attachment clears obsolete TCP session variables before binding the current row.
Empty session values override an older pane's saved identity.
Native requests ignore any obsolete TCP identity in the session.

Each native request adds a random `request_id` to its JSON body.
cmux suppresses identical terminal, title, and body content for five seconds before automation runs.
A different notification ID alone does not prevent that suppression.
The unique body lets repeated open, attach, and close requests reach the Mac hook.

On the Mac, the `wt-native-relay` automation runs `cmux-hook --event` for `notification.created`.
cmux exposes that event through `CMUX_AUTOMATION_EVENT_JSON`.
The event contains the notification ID and Mac row ID, but redacts the notification text.
The handler reads the matching record from `cmux --json list-notifications`.
It accepts only native SSH rows and keeps the existing host, path, and task validation.
It dismisses a successful open or attach request by notification ID.
Closing a row removes that row's notifications.

The rule uses cmux's minimum rate interval and maximum burst allowance.
Without that setting, cmux admits only one event per second and drops later requests.
An unrelated notification can consume that default allowance before an open request arrives.
cmux separately limits all automation rules to 32 concurrent firings.
It drops requests above that limit with `skipped_backpressure`.
The [automation engine](https://github.com/manaflow-ai/cmux/blob/v0.65.0/Sources/AutomationEngine.swift) controls both limits.
The [native notification gate](https://github.com/manaflow-ai/cmux/blob/v0.65.0/Packages/macOS/CmuxCloud/Sources/CmuxCloud/Notifications/CloudMachineNotificationGate.swift) also admits five notifications per machine initially.
It replenishes that allowance by one notification per second.
cmux retries requests above that rate on later updates.

`install.sh` merges this rule into `~/.cmuxterm/automations.json` on the Mac.
It backs up an existing regular file before replacement.
It preserves other rules and leaves managed symlinks or unreadable configurations unchanged.
It replaces a changed `wt-native-relay` rule and preserves an explicit `enabled: false` setting.
It reports unknown schema versions on stderr and skips their merge.
A missing or nonnumeric version uses the malformed-file message and skips the merge.
Each install ends with a summary of skips and follow-up actions.

After an authorized installation, run `cmux automation reload` on the Mac.
For an older task row, close that row and reopen it with `wt -H <host> attach -r <repo> <name>`.
The new attachment saves the row's current native identity.

Native requests enter the notification store before the automation runs.
A banner or sound can occur before the handler dismisses the request.
The automation cannot change those effects before delivery.

## An accepted request without a window

An updated `wt` script does not install or load the Mac automation rule.
VM-side exit status 0 means that the local relay accepted the request.
It does not confirm Mac delivery, hook execution, row selection, or a VS Code window.

Before notification, `wt` queries `cmux-tui --socket <socket> --json client list` with the current session's identity.
The [0.65.2 CLI](https://github.com/manaflow-ai/cmux/blob/v0.65.2/cmux-tui/crates/cmux-tui/src/cli/command.rs) uses the resource API for this command.
Its [client snapshots](https://github.com/manaflow-ai/cmux/blob/v0.65.2/cmux-tui/crates/cmux-tui-core/src/server.rs) expose `client_kind` and `attached_terminal_ids`.
The [Mac mirror handshake](https://github.com/manaflow-ai/cmux/blob/v0.65.2/Sources/Cloud/CloudTuiManualMirrorHandshake.swift) registers the kind `native-mirror`.
Client kind is client-supplied metadata.
`wt` requires that kind with the caller's terminal in `attached_terminal_ids`.
Environment variables, a socket, and a registered terminal cannot establish that a Mac client mirrors the terminal.

An absent mirror fails before notification.
A failed or malformed query also fails because mirror presence is unknown.
Older raw client-list responses use different fields and fail this check.
`cmux-tui` reports its own version rather than the Mac app release.
The preflight validates response fields instead of comparing version strings.
Each client query and notification has a five-second wait limit.
The diagnostic reports exit status 142 for a deadline and preserves other command statuses.
The shared deadline runner requires Perl and bounds child processes too.
Attach and open return nonzero for these failures and print the quoted Mac fallback command.
If task creation succeeded before its row request failed, the task remains created.
Use its printed attach command; do not create the task again.

A mirror can disconnect after the query, before the Mac receives the notification.
Notification admission and Mac automation limits can also prevent handling.
Therefore, successful requests explicitly report local acceptance and unverified Mac delivery.
A notification failure or timeout also leaves delivery unverified because the relay might already have accepted it.
[Issue #198](https://github.com/mal84emma/workgrove/issues/198) records the unmirrored-terminal failure.

On the Mac, run `cmux automation list`.
If it reports `No automation rules`, check `~/.cmuxterm/automations.json` for the `wt-native-relay` rule.
Install a missing rule as described in [Fix](#fix), then run `cmux automation reload`.
If the rule is intentionally disabled, keep that setting.
Use the printed Mac-side `wt -H <host> open -r <repo> <name>` command instead.

Check `~/.local/state/cmux-hook.log` for a new `handled wt-open` entry for the task's row.
The log reports missing event fields, unsupported remote backends, missing records, and invalid request fields.
Dropped `wt-open` and `wt-attach` requests name the check that failed.
The hook exits zero for dropped requests and leaves their notifications unchanged.
If the request remains in the notification list without that entry, the hook has not confirmed the open operation.
The Mac-side open command starts VS Code directly and does not need this automation.

## Verification on the test VM

Native requests use the task session's current terminal identity and a distinct `request_id` for repeated operations.
[PR #20's archived evidence](https://github.com/mal84emma/workgrove/pull/20#issuecomment-6775483639) preserves the October 8, 2026 checks, logs, and restoration limits.

## Verification on cmux 0.65.1

Native rows use their own lifecycle; the legacy suspended-row recovery path is removed.
[PR #78's archived evidence](https://github.com/mal84emma/workgrove/pull/78#issuecomment-6775485011) preserves the October 16, 2026 connection observations and cross-window checks.

The [0.65.1 native setup](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/RemoteTui/Workspace%2BSSHTui.swift) clears the legacy remote session controller and its active ID.
The [native status payload](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/RemoteTui/Workspace%2BSSHTuiStatus.swift) omits `persistent_daemon_slot`.
The [native coordinator](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/RemoteTui/SSHTuiWorkspaceCoordinator.swift) reports connecting, connected, or error states through its own lifecycle.
These historical checks do not verify another release; use the [compatibility log](cmux-integration.md#cmux-compatibility-log) for current support.

## Smoke tests

Run these tests from the repository root:

```bash
bash test/wt-smoke.sh
WT_BASH=/bin/bash bash test/wt-smoke.sh
bash test/native-relay-smoke.sh
shellcheck bin/wt bin/cmux-hook install.sh test/native-relay-smoke.sh
```

The native test checks the automation merge function in a scratch home.
It does not run `install.sh` or change installed files.
It checks native identity changes and repeated native requests with identical operation fields.
It also executes the installed rule's command and checks its VS Code request and notification dismissal.
