# VM requests after cmux 0.65

This page explains how VM tasks request VS Code windows and task rows on the Mac.
It records the cmux 0.65 regression and the verified fix.
[Agent status in VM rows](vm-agent-status.md) covers the status that a VM row shows.

Use the [cmux update checklist](cmux-checklist.md) after each cmux update.

## Cause

cmux 0.65.0 (108), commit `dda24fbd2`, uses `cmux-tui` for new SSH rows.
Those rows supply `CMUX_TUI_SOCKET` and `CMUX_TUI_TERMINAL_ID` instead of the old TCP relay variables.
Before native request support, the `wt` sender accepted only TCP sockets.
It stopped before sending a notification:

```text
wt: no cmux relay socket in this session; run the line below on the Mac
```

The VM at `<test-vm>` had an older installed `wt`, from workgrove commit `c58eebfa69ff0fc1073e224100e020fc85ee20f0`.
The task branch had the same TCP-only sender check.
The installed VM script's SHA-256 was `d395fd696834e05c0dd1f3882555214be6cc22c1e7a0286d6e502c368ae98279`.

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
The first direct native test reached the Mac, but cmux recorded it under another task on the same VM.
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
Each install ends with a summary of skips and follow-up actions.

After an authorized installation, run `cmux automation reload` on the Mac.
For an older task row, close that row and reopen it with `wt -H <host> attach -r <repo> <name>`.
The new attachment saves the row's current native identity.

Native requests enter the notification store before the automation runs.
A banner or sound can occur before the handler dismisses the request.
The automation cannot change those effects before delivery.

## An accepted request without a window

An updated `wt` script does not install or load the Mac automation rule.
VM-side exit status 0 means that cmux accepted the request.
It does not confirm that the Mac hook ran or that VS Code opened.

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

Machine names and runtime paths below use privacy placeholders.
Replace the placeholders before running the commands.

Both commands passed with temporary installed fixes:

```bash
wt -H <test-vm> open -r <repo> relay-probe
# Inside the VM task row:
wt open relay-probe -r <repo>
```

VS Code's status output reported the remote window:

```text
window [4] (relay-probe [SSH: <test-vm>] — SSH: <test-vm>)
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

## Verification on cmux 0.65.1

On 2026-10-16, the live checks used cmux 0.65.1, build 110, commit `8a853dcc9`.
The VM ran a temporary copy of workgrove commit `1c9cad7` in a disposable repository.
The Mac used its existing `wt-native-relay` automation rule.
No installed workgrove scripts or automation configuration were replaced.

These checks passed:

- A Claude turn in the native VM task showed Running, then Idle after completion.
- `wt open` from that task opened its remote folder in VS Code on the Mac.
  VS Code's status output listed the task's remote window.
- `wt rm` from a second native task removed its worktree, closed its row, and ended its tmux session.
  The task's tmux session held `WT_CMUX_CLOSE_ON_EXIT=1`.
- The two existing VM task rows and their tmux sessions remained present after self-removal.

The native row reported `backend: cmux-tui` and `state: connected`.
Its status payload omitted `persistent_daemon_slot`.
The user moved the row into a second window, disconnected the Mac's network for 90 seconds, and reconnected it.
The user then put the Mac to sleep for 30 seconds and woke it.
A command in the row confirmed that the connection worked afterward.
The recorder polled every two seconds while awake and logged state changes.
Every recorded state for the live row was connected.
It observed neither `suspended` nor `persistent_daemon_slot`.
The user also saw no `[ssh:suspended]` label.

The moved row kept its UUID, title, and `workspace:N` ref.
The caller-window list omitted it, but workgrove's combined window lookup found it.
Description updates and targeted input reached it by UUID from the original window.
Self-removal then closed that row and ended its session across windows.

The [cmux 0.65.1 native setup](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/RemoteTui/Workspace%2BSSHTui.swift)
clears the legacy remote session controller and its active controller ID.
Its [native status payload](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/RemoteTui/Workspace%2BSSHTuiStatus.swift)
omits `persistent_daemon_slot`.
The [native coordinator](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/RemoteTui/SSHTuiWorkspaceCoordinator.swift)
reports connecting, connected, or error states through its own lifecycle.
Together, the source and live checks answer issue #62 Step 1 for supported cmux 0.65.1.
The legacy suspended-row recovery and its stale TCP listener cleanup were removed.
These checks do not verify cmux 0.65.2.

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
