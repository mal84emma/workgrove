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

The VM at `<test-vm>` had an older installed `wt`, from workgrove commit `c58eebfa69ff0fc1073e224100e020fc85ee20f0`.
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
If the request remains in the notification list without that entry, the hook has not confirmed the open operation.
The Mac-side open command starts VS Code directly and does not need this automation.

## Agent status in VM rows

The VM rows of cmux 0.65 did not show the agent's status, but local rows did.

### Cause of the missing status

The workgrove status relay works only on cmux 0.64 TCP relay rows.
`wt run` starts the status owner only when `CMUX_SOCKET_PATH` names a TCP socket.
`bin/agent-notify` relays status only for the same socket.
On a native row, `tmux_cmd` clears `CMUX_SOCKET_PATH`, so workgrove sends no status.
The fix for `wt open` in this document did not change the status path.

cmux 0.65 has its own status path for native rows.
cmux-tui installs agent hooks in `~/.claude/settings.json` and `~/.codex/hooks.json` on the VM.
Each hook runs `"$CMUX_TUI_HOOK" <agent> <event>`.
That helper reports the state to the terminal in `CMUX_TUI_TERMINAL_ID`.
The Mac shows the state in the row as `cmux.remote.agent`, with Running, Idle, or Needs input.

In a task's tmux session, the agent gets the wrong terminal ID:

- `tmux_cmd` runs `tmux new-session` before it saves the row's identity in the session environment.
  So the agent's pane starts with tmux's global environment.
- The global environment holds the identity of the row that started the tmux server.
  So the hooks report to that row's terminal, which can belong to another task.
- A reattach gives the row a new terminal.
  A running agent keeps the terminal ID that it started with.

On the test VM, the agent of a new task had the terminal ID of another live row.
cmux-tui recorded the agent's state on that terminal.
The new task's row showed no status:

```text
$ tmux show-environment -t =wt-wt-demo-ssh-status-test-a CMUX_TUI_TERMINAL_ID
CMUX_TUI_TERMINAL_ID=term_26c3…
$ tmux show-environment -g CMUX_TUI_TERMINAL_ID
CMUX_TUI_TERMINAL_ID=term_d221…
$ tr '\0' '\n' < /proc/<agent pid>/environ | grep CMUX_TUI_TERMINAL_ID
CMUX_TUI_TERMINAL_ID=term_d221…
$ cmux sidebar-state --workspace <test row> | grep status_count
status_count=0
```

A manual report to the row's own terminal set the status on the Mac:

```text
$ cmux-tui --socket <socket> agent report --terminal term_26c3… --state working --source socket
$ cmux sidebar-state --workspace <test row> | grep agent
  cmux.remote.agent:agent=Running icon=bolt.fill color=#4C8DFF
```

### Fix for the status

`wt run` sets `CMUX_TUI_HOOK` to `lib/workgrove/cmux-tui-hook.sh` for its agent.
It saves the previous helper in `WT_CMUX_TUI_HOOK`.
At each hook, the wrapper reads `CMUX_TUI_SOCKET`, `CMUX_TUI_TERMINAL_ID`, and `CMUX_TUI_SESSION_ID` from the task's tmux session.
Then it runs the cmux-tui helper with these values.
An empty value or a removed name in the session unsets the value, so a TCP relay row gets no native report.
A name that the session does not hold keeps the pane's value.

The fix applies only to an agent that `wt run` starts after the update.
For a running agent, exit it and run `wt -H <vm> attach --restart-agent -r <repo> <name>`.

The cmux-tui hooks must be installed on the VM.
`install.sh --refresh-config` replaces `~/.claude/settings.json` and `~/.codex/hooks.json`, which removes them.
To check them, run `cmux-tui agent hook status` on the VM.
Make sure that the `claude` and `codex` providers show `installed`.
If a provider shows `absent`, run `cmux-tui agent hook install claude codex`.
Then restart the agent.

### Verification of the status

The test used a throwaway task on `<test-vm>` and started the fixed `wt run` in the task's tmux pane.
The agent's own environment still held the other row's terminal ID.
The task's row showed the agent's states as they changed:

```text
08:46:28   cmux.remote.agent:claude_code=Running icon=bolt.fill color=#4C8DFF
08:46:34   cmux.remote.agent:claude_code=Idle icon=pause.circle.fill color=#8E8E93
```

The Mac also received a `Claude finished` notification for that row.
After the test closed the row and attached the task again, the new row had a new terminal.
The running agent's status followed it to the new row:

```text
08:48:10   cmux.remote.agent:claude_code=Running icon=bolt.fill color=#4C8DFF
08:48:29   cmux.remote.agent:claude_code=Running icon=bolt.fill color=#4C8DFF
08:48:32   cmux.remote.agent:claude_code=Idle icon=pause.circle.fill color=#8E8E93
```

Local rows did not change. A local task row showed `claude_code=Running icon=bolt.fill` during the same test.

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
It also executes the installed rule's command and checks its VS Code request and notification dismissal.
