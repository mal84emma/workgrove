# VM requests after cmux 0.65

This page explains how VM tasks request VS Code windows and task rows on the Mac.
It records the cmux 0.65 regression and the verified fix.

## Cause

cmux 0.65.0 (108), commit `dda24fbd2`, uses `cmux-tui` for new SSH rows.
Those rows supply `CMUX_TUI_SOCKET` and `CMUX_TUI_TERMINAL_ID` instead of the old TCP relay variables.
The old `wt` sender accepts only TCP sockets.
It stops before sending a notification:

```text
wt: no cmux relay socket in this session; run the line below on the Mac
```

The VM at `ci-mal-c4-m14` had an older installed `wt`, from workgrove commit `c58eebfa69ff0fc1073e224100e020fc85ee20f0`.
The task branch had the same TCP-only sender check.
The installed VM script's SHA-256 was `d395fd696834e05c0dd1f3882555214be6cc22c1e7a0286d6e502c368ae98279`.

Sending through `cmux-tui notify` reaches the Mac's notification list.
However, that delivery path bypasses `notifications.hooks` in cmux 0.65.
[CloudNotificationLocalDelivery.swift](https://github.com/manaflow-ai/cmux/blob/v0.65.0/Sources/Cloud/CloudNotificationLocalDelivery.swift) calls `addNotification` without resolved hooks.
[TerminalNotificationStore.swift](https://github.com/manaflow-ai/cmux/blob/v0.65.0/Sources/TerminalNotificationStore.swift) substitutes an empty hook array for a remote origin.
A local notification still runs `cmux-hook` with the `CMUX_NOTIFICATION_*` fields and a version-1 JSON envelope.
The [0.65 schema](https://raw.githubusercontent.com/manaflow-ai/cmux/v0.65.0/web/data/cmux.schema.json) still accepts the existing notification hook configuration.
The hook's event names and configuration did not cause this failure.

A second identity problem occurs when tmux starts new panes from an existing server.
The pane can inherit another row's `CMUX_TUI_TERMINAL_ID`.
The first direct native test reached the Mac, but cmux recorded it under another task on the same VM.
The fix records the current row's native identity in its task's tmux session before attachment.

## Fix

`wt` sends native requests with `cmux-tui`, the explicit socket, and the current session's terminal ID.
It retains the old sender for TCP relay rows.
Each attachment clears the inactive transport's session variables before binding the current row.
Empty session values override an older pane's saved identity.
Native delivery also takes precedence when an older session still contains both transports.

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
It preserves existing rules and leaves managed symlinks or unreadable configurations unchanged.
An existing rule with the same ID stays unchanged, including an explicitly disabled rule.
Review the repository rule when the installer reports an existing or managed configuration.

After an authorized installation, run `cmux automation reload` on the Mac.
For an older task row, close that row and reopen it with `wt -H <host> attach -r <repo> <name>`.
The new attachment saves the row's current native identity.

Native requests enter the notification store before the automation runs.
A banner or sound can occur before the handler dismisses the request.
The automation cannot change those effects before delivery.

## Verification on ci-mal-c4-m14

Both commands passed with temporary installed fixes:

```bash
wt -H ci-mal-c4-m14 open -r /home/azureuser/wt-demo relay-probe
# Inside the VM task row:
wt open relay-probe -r /home/azureuser/wt-demo
```

VS Code's status output reported the remote window:

```text
window [4] (relay-probe [SSH: ci-mal-c4-m14] — SSH: ci-mal-c4-m14)
```

A VM-side `wt new` created a second task through `wt-attach`.
Its row stayed unfocused, and `wt open` worked without a manual identity correction.
The `wt-close` relay removed that task's worktree, Mac row, and tmux session.
The Mac hook log at `~/.local/state/cmux-hook.log` recorded these requests:

```text
2026-10-08T12:01:30 handled wt-open for workspace 2AD6A732-463A-47F0-B45C-ACF38065EB27
2026-10-08T12:02:26 handled wt-attach for workspace 2AD6A732-463A-47F0-B45C-ACF38065EB27
2026-10-08T12:03:10 handled wt-open for workspace 43676295-744C-4184-9775-5A65E5AEBB9C
2026-10-08T12:05:52 handled wt-close for workspace 43676295-744C-4184-9775-5A65E5AEBB9C
```

Both throwaway tasks were removed after testing.
The original Mac hook symlink, Mac automation configuration, and VM `wt` symlink were restored.
No installed file remains changed.
Neither `install.sh` nor `wt update` ran on the Mac or VM.

Follow-up tests attached `relay-second-fixed` to a tmux session with an obsolete TCP identity.
The native attachment cleared that identity and saved its current terminal without manual corrections.
Mac-side open passed.
Two identical VM open operations arrived 158 milliseconds apart with different `request_id` values.
Both reached the hook and exited successfully.
Native open also passed after the test deliberately restored an obsolete TCP value alongside the valid native identity.

The hook recorded both repeated requests and the mixed-transport request:

```text
2026-10-08T13:29:15 handled wt-open for workspace 1ADA0A4D-C4F0-4CC6-A05B-F8FE80F40634
2026-10-08T13:29:15 handled wt-open for workspace 1ADA0A4D-C4F0-4CC6-A05B-F8FE80F40634
2026-10-08T13:29:56 handled wt-open for workspace 1ADA0A4D-C4F0-4CC6-A05B-F8FE80F40634
```

## Smoke tests

Run these tests from the repository root:

```bash
bash test/wt-smoke.sh
WT_BASH=/bin/bash bash test/wt-smoke.sh
bash test/native-relay-smoke.sh
bash test/agent-status-smoke.sh
shellcheck bin/wt bin/cmux-hook install.sh test/native-relay-smoke.sh
```

The native test checks the automation merge function in a scratch home.
It does not run `install.sh` or change installed files.
It checks transport changes in both directions and repeated native requests with identical operation fields.
