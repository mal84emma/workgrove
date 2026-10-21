# The cmux integration contract

This page lists the cmux interfaces that workgrove uses and the behaviors that its implementation depends on.
A row is a cmux workspace, shown as one entry in the sidebar.
The [Mac–VM protocol](vm-protocol.md) defines task results, relay requests, and the tmux environment.
Use the [cmux update checklist](cmux-checklist.md) to verify a release.

## What the probe checks

The functions in [doctor.sh](../lib/workgrove/doctor.sh) define the checks below.
`cmd_doctor` reports all checks and returns nonzero for a failure or version warning.
The probe does not create rows, execute agent hooks, or verify the complete user flows.

| Check | Reader and required result |
|---|---|
| The cmux version | `doctor_mac` parses `cmux version` and compares it with `WG_CMUX_SUPPORTED` in [cmux.sh](../lib/workgrove/cmux.sh), currently `0.65.1`. |
| Available methods | `doctor_mac` requires `workspace.list`, `workspace.create`, `workspace.action`, `workspace.close`, and `workspace.select` in `.methods`. |
| Other methods | `doctor_mac` also requires `workspace.remote.reconnect`, `notification.list`, `notification.dismiss`, `system.top`, and `surface.read_text`. |
| Window and row JSON | `doctor_mac` calls `cmux_rows_load checked` in `cmux.sh`. The next tables define the fields. |
| Agent and notification JSON | `doctor_mac` validates `top --json` and `--json list-notifications`. |
| The native automation | `doctor_mac` compares `automation show wt-native-relay` with the complete repository rule. It checks that `~/.local/bin/cmux-hook` is executable. |
| Configured hook commands | `doctor_hooks` reads `.hooks`, `.type == "command"`, and `.command` in the Claude and Codex JSON files. |
| Static hook paths | `doctor_hook_path`, `doctor_words`, and `doctor_simple_hook` check syntax and files without executing commands. Dynamic syntax produces a warning. |
| VM tools and configuration | `doctor_vm` checks cmux-tui, both installed provider hooks, the executable helper, tmux 3.2 minimum, `WT_HOST`, and `WT_REPOS_DIR` folders. |
| The workgrove version | `cmd_doctor` validates `wt version`. `host_doctor` compares the VM protocol with the Mac protocol. |

`workspace.remote.reconnect` remains a capability check.
Current recovery code in [recovery.sh](../lib/workgrove/recovery.sh) does not call that method.
The hook path checks reject changes to `PATH`, `HOME`, `ENV`, `BASH_ENV`, `ZDOTDIR`, or `SHELL`.
`doctor_static_environment` treats these names as executable lookup or shell initialization controls.

## Commands and flags

Unless a row names another file, each reader below is in [cmux.sh](../lib/workgrove/cmux.sh).
`cmux_call` runs the selected command-line interface (CLI), records failures, and normally sets `CMUX_QUIET=1`.
The Mac hook supplies its `capped` runner instead.
Angle brackets mark values supplied by the caller.

| Command and flags | Reader and use |
|---|---|
| `cmux ping` | `cmux_ok` checks reachability. `check_row_removal` distinguishes an absent socket from other failures. |
| `cmux --json list-windows` | `cmux_rows_load` reads window UUIDs. `doctor_record` in `doctor.sh` captures windows. |
| `cmux workspace list --json --window <uuid>` | `cmux_rows_load` merges each window's rows. `doctor_record` records each window separately. |
| `cmux workspace list --json` | `cmux_rows_load` uses the caller-window fallback when enumeration supplies no documents. |
| `cmux workspace create --name <title> --description <description> --cwd <path> --focus false --command <command>` | `open_workspace` starts a local task without selecting its row. `cmux_create` forwards the arguments. |
| `cmux workspace create --name driver --description <description> --cwd <path> --command claude --focus true` | `cmd_driver` in [bin/wt](../bin/wt) creates and selects the driver row through `cmux_create`. |
| `cmux workspace create --name <repo-shell-title> --description <description> --cwd <repo>` | `cmd_task` in `bin/wt` creates a local repository shell through `cmux_create`. |
| `cmux workspace select <id>` | `cmux_select` selects an existing row. |
| `cmux workspace close <id> [--force]` | `close_row` uses `--force` for the caller's own row or a newly created row during failed setup. |
| `cmux ssh <host> --name <title> --no-focus --command <command>` | `cmux_row_create_ssh` creates a VM row before tagging it. Requested selection follows the description update. |
| `cmux workspace-action --workspace <id> --action set-description --description <description>` | `cmux_row_create_ssh` and `cmux_row_open_ssh` write the second line. |
| `cmux top --workspace <id> --json` | `row_agent` reads the caller identity and agent process counts before removal. |
| `cmux top --json` | `doctor_mac` in `doctor.sh` checks the response shape. |
| `cmux read-screen --workspace <id>` | `cmux_screen` returns screen text. `row_shell_prompt` checks its last nonblank lines before recovery sends input. |
| `cmux send --workspace <id> <text>` | `send_tmux_line` sends the tmux attachment command. |
| `cmux send-key --workspace <id> enter` | `send_tmux_line` submits that command. |
| `cmux diff --branch --repo <path> --base <ref> --layout split --title <title> --focus true` | `cmd_show` in `bin/wt` opens the diff through `cmux_diff`. |
| `cmux diff --branch --layout split --focus true` | [cmux.json](../home/.config/cmux/cmux.json): `.actions["wt-diff"].command` opens the configured Diff action. cmux selects the repository and base. |
| `cmux --json list-notifications` | `cmux_notifications` supplies records to the Mac hook and `doctor_mac`. |
| `cmux dismiss-notification --id <uuid>` | `cmux_dismiss` removes a successfully handled open or attach request. |
| `cmux version` | `doctor_mac` in `doctor.sh` parses the version. |
| `cmux capabilities` | `doctor_mac` in `doctor.sh` checks method names. `doctor_record` captures the response. |
| `cmux automation show wt-native-relay` | `doctor_mac` in `doctor.sh` compares the returned rule with the repository rule. |
| `cmux events --after 0 --name notification.created --limit 1 --timeout 3 --no-ack --no-heartbeat` | `doctor_record` in `doctor.sh` reads one retained event without acknowledging it or emitting heartbeats. |
| `cmux-tui --socket <path> notify --surface <terminal-id> --title <title> --body <json>` | `cmux_notify` sends native VM requests. It never supplies `--workspace`, because terminal IDs differ from Mac row UUIDs. |
| `cmux-tui --json agent hook status claude codex` | `doctor_vm` in `doctor.sh` checks both providers. |

The code prints additional repair commands without executing them.
`doctor_mac` prints `cmux automation enable wt-native-relay` and `cmux automation reload`.
`doctor_vm` prints `cmux ssh <vm>` and `cmux-tui agent hook install claude codex`.
`hook_cmux_automation` in [automation.sh](../lib/workgrove/automation.sh) prints `cmux automation reload`.
`install_configs` in [install.sh](../install.sh) prints `cmux hooks codex install --yes` or the VM provider status command.

Creation output is text, not JSON.
`cmux_ref` extracts the first `workspace:N` reference from local or SSH creation output.
If SSH creation returns no reference, `cmux_row_create_ssh` waits one second and makes one lookup.
That lookup excludes preexisting IDs and requires the requested title, host, and an absent repository description.
If a new row's description update fails, the adapter closes it and reports failure.
An existing row's description update failure produces a diagnostic but preserves the row.
SSH creation always uses `--no-focus`; explicit selection follows only when the caller requested focus.
On cmux 0.65.1, focused replacement creation reproduced a generated title instead of the requested task title.
Creating unfocused and then selecting preserved the title during live reattachment.
A failed selection retains the identified row and task while reporting the failure.

`close_row` accepts this exact error when the row has already disappeared:

```text
Error: not_found: Workspace not found
```

Without `CMUX_WORKSPACE_ID`, `check_row_removal` accepts a ping error that starts with this exact prefix:

```text
Error: Socket not found at
```

The prefix in the code includes a space after `at`.
Other ping failures block removal.

## JSON fields

Fields below are inputs that select behavior or receive validation.
Additional fields in captured fixtures do not establish additional runtime requirements.

| Response | Fields | File and reader |
|---|---|---|
| Window list | The outer value is an array. Each `.id` must be a universally unique identifier (UUID) string. | `cmux.sh`: `cmux_rows_load`. `doctor.sh`: `doctor_record`. |
| Row list | Either an array or an object with `.workspaces` contains the rows. | `cmux.sh`: `cmux_rows_load`, `cmux_find_row`, `row_remote_field`, `from_row_on_host`. |
| Row identity | `.id` is a nonempty string. `.title` is a string. `.description` is null or a string. | `cmux.sh`: `cmux_rows_load`, `cmux_find_row`, `row_label`, `cmux_row_create_ssh`, and the `ROW_JQ` definitions. |
| Remote identity | `.remote` is null or an object. `.remote.enabled` is null or boolean. `.remote.destination` is null or a string. | `cmux.sh`: `cmux_rows_load`, `ROW_JQ`, `from_row_on_host`. |
| Native backend | `.remote.enabled` must be true. `.remote.backend` must equal `cmux-tui`. | [bin/cmux-hook](../bin/cmux-hook): the top-level `--event` handler. |
| Remote state | `.remote.state` must equal `connected` for automatic input or client replacement. | `cmux.sh`: `row_remote_field`. `recovery.sh`: `reattach_shell_row`, `reinit_task_client`. |
| Row directory | `.current_directory` identifies local rows that might hold the target worktree. | `cmux.sh`: `check_row_removal`. [task.sh](../lib/workgrove/task.sh): `check_identity`. |
| Agent status | `.caller.workspace_id` identifies the caller's own row. `.coding_agents[].resources.process_count` must be nonnegative numbers. | `cmux.sh`: `row_agent`. `doctor.sh`: `doctor_mac`, which also checks `.caller` as an object. |
| Notifications | The outer value is an array. `.id` and `.workspace_id` identify a record. `.title` and `.body` must be strings. | `cmux.sh`: `cmux_notifications`. `doctor.sh`: `doctor_mac`. `bin/cmux-hook`: the `--event` handler. |
| Automation event | `.name == "notification.created"`, `.workspace_id`, and `.payload.notification_id` identify the request. The hook requires UUIDs for both IDs. | `bin/cmux-hook`: the `--event` handler. `doctor.sh`: `doctor_record`. |
| Capabilities | `.methods` is an array with every method in the probe table. | `doctor.sh`: `doctor_mac`. |
| VM provider hooks | `.errors == []`; `.providers` is an array. Each requested `.provider` occurs once, with `.state == "installed"`. | `doctor.sh`: `doctor_vm`. |
| Focused notification hook | `.context.appFocused` controls suppression of the desktop notification. | [cmux.json](../home/.config/cmux/cmux.json): the inline `quiet-when-focused` jq command in `.notifications.hooks`. |

`ROW_JQ` identifies task rows by title, repository, and host.
The description is `@<host> · <repo>`; the separator contains spaces and U+00B7 MIDDLE DOT.
`repo_id` in [common.sh](../lib/workgrove/common.sh) replaces basename characters outside `A-Za-z0-9-` with `-`.
The readers also accept older `<repo>:<name>` titles.
`row_shell_prompt` in `cmux.sh` accepts a prompt ending in `$`, `#`, or `%` that names `user@host`.
A two-line prompt may put that name on the preceding line.
In that case, the final nonblank line must contain only `$`, `#`, or `%`, apart from trailing whitespace.

### The automation rule

[automations.json](../home/.cmuxterm/automations.json) defines the `wt-native-relay` rule.
`doctor_mac` compares every rule field, including omitted fields, with this source.
`hook_cmux_automation` in `automation.sh` reads the file's `.version`, `.rules`, rule `.id`, and existing `.enabled` setting during merge.
It accepts schema version 1 and preserves an explicit `enabled: false`.

| Rule field | Required repository value |
|---|---|
| `id` | `wt-native-relay` |
| `when.event` | `notification.created` |
| `rate_limit.interval_seconds` | `0.001` |
| `rate_limit.maximum` | `1024` |
| `then[].action` | `run` |
| `then[].command` | `~/.local/bin/cmux-hook --event` |
| `then[].timeout_seconds` | `20` |

The Mac hook reads notification text from the matching stored record because public event text is redacted.
`quiet` returns false effects for `desktop`, `sound`, `markUnread`, and `paneFlash` after successful open or attach.
`quiet_control` also returns false effects for `record`, `reorderWorkspace`, and `command` after successful close.
These functions are in `bin/cmux-hook`; their responses cannot suppress effects that occurred before automation ran.

`doctor_record` saves redacted JSON below `cmux-<version>/`.
[doctor-sanitize.jq](../lib/workgrove/doctor-sanitize.jq) preserves types and selected public keys, while replacing identities and free text.
Its `public_keys`, `public_value`, and `methods` definitions control redaction, not runtime feature checks.

## Environment variables

This table covers integration inputs and variables that the code deliberately writes or clears.
Adapter state such as `CMUX_ROWS_JSON` and `CMUX_RUN` is internal shell state, not an environment interface.

| Variable | File and reader or writer | Contract |
|---|---|---|
| `CMUX_BUNDLED_CLI_PATH`, `PATH`, `HOME` | `cmux.sh`: `cmux_bin`. | The search uses the executable bundled path, `PATH`, `~/.cmux/bin/cmux`, then the CLI inside `/Applications/cmux.app`. |
| `CMUX_QUIET` | `cmux.sh`: `cmux_call` writes it. | Normal CLI calls receive `1`; the Mac hook supplies its own runner. |
| `CMUX_WORKSPACE_ID` | `cmux.sh`: `check_row_removal`. `common.sh`: `tmux_cmd` clears it. | A caller row makes an absent CLI or socket a removal failure. |
| `CMUX_SSH_ATTEMPT_ID` | `task.sh`: `is_remote`. | A nonempty value selects VM behavior, as does any operating system other than Darwin. |
| `CMUX_SURFACE_ID` | [bin/agent-notify](../bin/agent-notify): the top-level Mac banner condition. `common.sh`: `tmux_cmd`. | A nonempty value suppresses the outside-cmux Mac banner. Native task attachments clear it. |
| `CMUX_SOCKET_PATH`, `CMUX_PANEL_ID`, `CMUX_TAB_ID`, `CMUX_TERMINAL_LIFECYCLE_ID` | `common.sh`: `tmux_cmd`. | Native task attachments clear these legacy identity values in the shell and tmux session. |
| `CMUX_TUI_SOCKET`, `CMUX_TUI_TERMINAL_ID`, `CMUX_TUI_SESSION_ID` | `common.sh`: `relay_env`, `tmux_cmd`. [cmux-tui-hook.sh](../lib/workgrove/cmux-tui-hook.sh): top level. | The tmux session supplies current native identity. The socket must be absolute; the terminal must match `term_[a-f0-9]{32}` for requests. |
| `CMUX_TUI_SOCKET` | `bin/wt`: `cmd_rm`. | An inherited native socket without usable session identity produces the older-row teardown diagnostic. |
| `CMUX_SOCKET` | `cmux.sh`: `cmux_notify` removes it from the child environment. | Native requests use the explicit `--socket` instead. |
| `CMUX_TUI_HOOK`, `WT_CMUX_TUI_HOOK`, `XDG_DATA_HOME`, `HOME` | `cmux.sh`: `cmux_tui_agent_helper`. `bin/wt`: `cmd_run`. `cmux-tui-hook.sh`: top level. | The wrapper saves the original helper and rejects wrapper paths as helpers. The fallback is the cmux-tui data folder. |
| `CMUX_AUTOMATION_EVENT_JSON` | `bin/cmux-hook`: the `--event` handler. | The value contains the native event object. |
| `XDG_STATE_HOME`, `HOME` | `bin/cmux-hook`: top-level `LOG` initialization and `log`. | The hook writes `cmux-hook.log` below the state folder, defaulting to `~/.local/state`. |
| `TMUX`, `TMUX_PANE` | `common.sh`: `relay_env`. `bin/wt`: `cmd_run`, `cmd_rm`. `cmux-tui-hook.sh`: top level. | The readers find the current session. The wrapper uses `TMUX_PANE` to select the pane's session. |
| `WT_CMUX_CLOSE_ON_EXIT` | `common.sh`: `tmux_cmd` writes it. `bin/wt`: `cmd_rm` reads it. | A session value of `1` selects native teardown through terminal exit. |
| `WT_HOST`, `WT_REPOS_DIR` | `task.sh`: `wt_host`, repository search initialization. `doctor.sh`: `doctor_vm`. | The VM alias must be valid. The probe requires existing absolute folders separated by colons. |
| `CODEX_SANDBOX` | `bin/wt`: `cmd_rm`. [task.sh](../lib/workgrove/task.sh): `open_code`. | A nonempty value blocks removal before socket cleanup and blocks direct VS Code launch. |
| `WT_CLOSE_WAIT_SECONDS` | `bin/wt`: `cmd_rm`. | Relay teardown waits 22 seconds by default. Invalid values use the default. |
| `WG_POLL_INTERVAL` | `common.sh`: `wg_sleep`. | Tests can replace the normal one-second lookup and recovery waits. |
| `CMUX_CUSTOM_CODEX_PATH`, `CMUX_CUSTOM_CLAUDE_PATH`, `HOME` | [home/.zshenv](../home/.zshenv): top-level Darwin block. | Unset or empty overrides receive executable agent paths from `~/.local/bin`, which prevents wrapper recursion. |

The [tmux environment contract](vm-protocol.md#the-tmux-session-environment) records the exact empty and removed-value rules.
The [VM protocol](vm-protocol.md#result-records-and-versions) defines `WT_MACHINE` and result versions.

## Recorded behavior and limits

These entries distinguish recorded observations from checks that the code performs on each call.
They do not establish compatibility with an unverified release.

| Recorded behavior | Source and implementation dependency |
|---|---|
| A row list covers one window. Window UUIDs remain stable when window indices change. | `cmux.sh`: comments and enumeration in `cmux_rows_load`. The [live verification](vm-open-relay.md#verification-on-cmux-0651) confirms cross-window lookup. |
| Without a creation reference, the row list lags by about one second. | `cmux.sh`: the measured comment and single wait in `cmux_row_create_ssh`. |
| cmux 0.65 closes a newly created VM row without `--force`. | `cmux.sh`: the measured comment in `close_row`. The implementation still supplies `--force` during failed setup cleanup. |
| Local agent rows require `--force` to close without confirmation. | `cmux.sh`: `close_row` supplies the flag only for self or new cleanup. |
| Identical terminal, title, and body content is suppressed for five seconds, regardless of notification ID. | `cmux.sh`: the comment and random `request_id` generation in `cmux_notify`. |
| Row listing takes about 0.02 seconds; SSH creation takes about four seconds. Painting takes 1.2–2.9 seconds afterward. | `bin/cmux-hook`: the recorded timings in `capped` explain its 15-second call budget. |
| The VS Code CLI normally exits within one second. | `bin/cmux-hook`: the `wt-open` handler waits once. A running process or zero exit permits request dismissal. |
| A background child loses cmux socket authorization when the hook exits. | `bin/cmux-hook`: the `wt-attach` handler calls `attach_row` synchronously to preserve process ancestry. |
| A new tmux pane can inherit another row's identity from the server's global environment. A reattach changes only session values. | `cmux-tui-hook.sh`: comments and session refresh before helper execution. `common.sh`: `relay_env` refreshes before requests. |
| Native terminal exit closes the Mac row. An open SSH row can reconnect and recreate a killed session. | `common.sh`: `tmux_cmd` executes the tmux client. `bin/cmux-hook`: `wt-close` closes the row before killing the session. |

The rule gives a hook 20 seconds.
`capped` in `bin/cmux-hook` normally shares a 15-second deadline between calls.
The close handler uses 12 seconds before closing, then five seconds for session cleanup.
`cmux_row_create_ssh` adds three seconds for cleanup if the description update fails.
If Perl is unavailable, `capped` runs calls without its process-group timeout.

The [relay investigation](vm-open-relay.md#fix) records additional upstream limits.
The automation default admits one event per second; the repository rule uses a 0.001-second interval and maximum 1024.
In cmux 0.65.1, [AutomationEngine.swift](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/AutomationEngine.swift) enforces the default in `admit`.
Its `receive` function permits 32 concurrent automation firings and drops excess requests with `skipped_backpressure`.

The [native notification gate](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Packages/macOS/CmuxCloud/Sources/CmuxCloud/Notifications/CloudMachineNotificationGate.swift) initially permits five notifications per machine and replenishes one per second.
Its `Configuration`, `TokenBucket.refill`, and `admit` implement these limits and the five-second content window.
`Configuration` also permits a burst of 30 notifications across all machines and replenishes one notification every 0.1 seconds.
`admit` requires available capacity under both limits.
`deliver` in [CloudNotificationLocalDelivery.swift](https://github.com/manaflow-ai/cmux/blob/v0.65.1/Sources/Cloud/CloudNotificationLocalDelivery.swift) leaves requests pending when either rate limit prevents delivery.
Later updates retry those requests.

`doctor_mac` checks the configured rule, not these upstream runtime limits.

## cmux compatibility log

This log records cmux versions verified with workgrove. It does not establish support for untested versions.
Run `cmux version` to check your installed version.
Run `wt doctor` after an update, then follow the [cmux update checklist](cmux-checklist.md).
`WG_CMUX_SUPPORTED` in `lib/workgrove/cmux.sh` selects the single verified version for the probe.

workgrove supports cmux 0.65.1 until a newer release passes verification. Version 0.65.2 is unverified.
The log has one supported version at a time. Older rows record historical verification.
Support does not include the removed cmux 0.64 TCP relay paths.

| cmux version | Status | Verified on | Verified behavior |
|---|---|---|---|
| 0.65.1 (build 110, `8a853dcc9`) | Supported; native VM and cross-window checks passed | 2026-10-16 | A Claude VM task showed Running, then Idle. VM-side `wt open` opened VS Code on the Mac. VM-side self-removal closed its row, ended its tmux session, and removed its worktree. Two existing VM rows and sessions remained present. No recorded native state was suspended, and no payload contained a daemon slot. Cross-window lookup, description updates, input, and self-removal passed. |
| 0.65.0 (build 108, `dda24fbd2`) | Historical | 2026-10-08 | Claude and Codex self-removal, locally and on `<test-vm>`. All four cases removed their task rows. Both VM tmux sessions ended. Five preexisting rows and two VM sessions remained intact. |

[PR #19](https://github.com/mal84emma/workgrove/pull/19) adapts self-removal to cmux 0.65.0's row-closing behavior.
Local self-removal uses cmux's `--force` only for the verified caller's own row.
Native VM rows exit with their task's tmux session.
The earlier `0.64 or newer` requirement did not guarantee compatibility with these changes.

For each supported version, record the exact build, verified behavior, and remaining checks.
[VM verification on cmux 0.65.1](vm-open-relay.md#verification-on-cmux-0651) records the current live checks.
Codex VM status, combined states from several agents, and Esc interruption behavior remain unverified by that live session.
