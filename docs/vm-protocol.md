# The Mac–VM protocol

This page defines the commands, records, requests, and tmux environment that connect the Mac and a VM.
The Mac runs cmux and opens VS Code windows.
The VM holds the worktrees and runs agents in tmux sessions.
The [cmux integration contract](cmux-integration.md) lists the CLI, JSON, and environment dependencies.
The [relay investigation](vm-open-relay.md) and [agent status investigation](vm-agent-status.md) record live verification and known limits.

## Mac to VM

[options.sh](../lib/workgrove/options.sh) defines accepted remote subcommands in `WT_COMMANDS`.
`cmd_host` in [bin/wt](../bin/wt) dispatches them.
`wt_remote_args` in [remote.sh](../lib/workgrove/remote.sh) normalizes repository arguments before forwarding them.
With `-H`, a repository must be an absolute VM path or a plain repository name.
`show`, `rm`, `path`, `open`, and `attach` require `-r`.

`vm_wt` in [common.sh](../lib/workgrove/common.sh) executes `"$HOME/.local/bin/wt"` on the VM through SSH.
`vm_wt_line` and `vm_run_line` build commands without executing them.
`vm_ssh` supplies shared SSH options, including keepalives; `vm_tmux` handles session queries and removal.
`VM_SSH_OPTIONS` in `common.sh` supplies the same connection options to `vm_ssh` and `probe_host`.
Both use batch mode, zero password prompts, one connection attempt, and a five-second connection timeout.
Both send keepalives every five seconds and stop after two unanswered keepalives.
The alias's SSH configuration controls host-key checking; neither path overrides that policy.
Managed registrations require `StrictHostKeyChecking yes`.
A plain alias can retain an explicit `accept-new` policy, including aliases from `azml-ssh-host`.
Without an explicit policy, OpenSSH's default checking applies; batch mode cannot prompt for an unknown key.
The probe alone adds `-T`; interactive callers can still request a terminal.
`shell_join` in [common.sh](../lib/workgrove/common.sh) quotes each argument for the remote shell.
Values such as `WT_MACHINE=1` appear inline in the command; the connection does not require SSH `AcceptEnv`.
The Mac ships preflight and recovery scripts on standard input, so those scripts use the Mac's implementation.
`host_environment_doctor` quotes its bootstrap with `shell_join` and runs it through `/bin/sh -c`.
The VM's login shell does not parse the bootstrap's script syntax.

| Mac command or operation | VM command or input | What the Mac reads | File and reader |
|---|---|---|---|
| `new` | `new --no-workspace --prompt-stdin`, with requested name, repository, base, agent, and model options. Standard input holds the brief. | Status 0 and a `new/created` record supply `name`, `repo`, and `session`. The session must match `wt_session`. | `remote.sh`: `host_new`. |
| Creation preflight | `sh -s -- <repo> <agent>` receives `version.sh` and `vm/host-new-preflight.sh`. | The Mac reads the version JSON without forwarding stdout. It warns on stderr when protocols differ or the version is unavailable, then continues. The script's exit status checks `wt`, the repository, tmux, and the requested or default agent. | `remote.sh`: `host_new_preflight`, `host_new`. |
| `attach` | `show <name> -r <repo>` with a machine-result request. | A `show/found` record supplies identity and the `agent`, `attached`, and `started` booleans. The name and derived session must match. | [recovery.sh](../lib/workgrove/recovery.sh): `host_attach`. |
| `attach` recovery | tmux queries and `vm/reinit-client-*.sh` scripts. | The Mac checks session clients, a single PID/TTY pair, and fresh screen markers before replacing a client. | `recovery.sh`: `vm_session_detached`, `reattach_shell_row`, `reinit_task_client`. |
| `show` | `show` with the supplied options. | The Mac forwards output and exit status. It does not parse the user's report. | `bin/wt`: `cmd_host`; `remote.sh`: `remote_wt`. |
| `rm` or `remove` | An agent probe, then `rm` with the supplied removal options. | The Mac requires an absent or idle agent and successful removal before closing its row and stopping the session. | `remote.sh`: `agent_on_vm`, `host_rm`. |
| `path` | `path <name> -r <repo>`. | The Mac forwards the ordinary path and exit status. | `bin/wt`: `cmd_host`; `remote.sh`: `remote_wt`. |
| `open` | `path <name> -r <repo>` with a machine-result request. | The recorded `path` must pass `hook_safe_path`. Older records and text-only VMs use stdout as the path. | `remote.sh`: `host_open`. |
| `list` or `ls` | `list`, with `--all` added when `-r` is absent. | The Mac forwards the table or requested JSON. | `remote.sh`: `host_list`. |
| `repos` | `repos` with the supplied options. A terminal receives `--table` unless a mode was requested. | The Mac forwards repository lookup, table, or porcelain output. | `remote.sh`: `host_repos`. |
| `doctor` | `doctor`, followed by `version`. | The Mac prints checks, recognizes SSH failure, and compares the reported protocol with `WT_PROTOCOL`. Remote `--record` is unsupported. | [doctor.sh](../lib/workgrove/doctor.sh): `host_doctor`. |
| `version` | `version`. | The Mac forwards the VM's JSON object. | `bin/wt`: `cmd_host`; `remote.sh`: `remote_wt`. |
| `update` | `version`, `update` with installation flags, then `version`. | The Mac validates version objects and prints before/after update records. It lends a terminal to interactive update confirmation. | `remote.sh`: `host_version`, `host_update`; `common.sh`: `vm_wt --tty`. |
| `help`, `-h`, or `--help` | The normalized `help` command. | The Mac forwards help text and exit status. | `bin/wt`: `cmd_host`; `remote.sh`: `remote_wt`. |
| Agent safety probe | The Mac sends its `tmux_agent` function on stdin to `bash -s`. | Status 0 means an agent runs; 1 means absent or idle; 2 means unreadable status. | `remote.sh`: `agent_on_vm`; [task.sh](../lib/workgrove/task.sh): `tmux_agent`. |
| Task row startup | The SSH row runs `tmux_cmd`, then `wt run <name> -r <repo>` inside the new session. | The Mac uses the command's session identity, rather than parsing `wt run` output. | `remote.sh`: `remote_row`; `common.sh`: `vm_run_line`, `tmux_cmd`. |
| `hosts` inventory | `sh -s` receives `version.sh` and `vm/probe-host.sh`. This is not a remote `wt hosts` command. | Tab-separated `wt_version`, `cpu`, `mem_kib`, `gpu_status`, and `gpu` rows become host JSON. | [hosts.sh](../lib/workgrove/hosts.sh): `probe_host`, `host_record`. |

`host_new` consumes `-p` or `--prompt-stdin` on the Mac and sends both forms through the same standard-input channel.
`--no-workspace` skips the Mac cmux requirement and row creation, but still runs VM preflight and creates the worktree.
`host_new` does not retry creation after a disconnected SSH call because the VM might already have created the task.

`host_attach` uses the boolean facts when the VM supplies them.
`state` remains display text. Older VMs use marked wording fallbacks for the values `none`, `shell only`, `shell only, detached`, `agent running`, and `agent running, detached`.
A task with no session and no started marker can start for the first time.
A lost agent requires explicit `--restart-agent`; explicit `--reattach` sends attachment input only after a shell-prompt check.

The host probe reads GPU rows as index, model name, and memory in MiB.
It reads CPU count and memory in KiB, then converts memory to MiB.
`host_record` validates these fields and reports unknown values as null or `unknown`.
The [JSON contracts](wt-json.md) define the public inventory and task-status objects.

`probe_host` in `hosts.sh` reads `WG_HOST_PROBE_TIMEOUT` for the Mac's SSH client deadline, which defaults to 20 seconds.
The value must match `^[1-9][0-9]*$` and cannot exceed `922337203685477580`.
An invalid value returns 1; an exceeded deadline returns 124.
`host_record` converts either failure into an unavailable host record with an error message.

## Result records and versions

`WT_PROTOCOL` in `common.sh` is currently `1`.
`vm_result` calls `vm_wt --machine` to request records with `WT_MACHINE=$WT_PROTOCOL`.
Creation, attach, open, doctor, and the Mac hook use this reader.
It returns decoded fields, stdout, stderr, and command status separately, and removes records from both visible streams.
It discovers records on either stream and uses only stdout for a legacy successful path.
At startup, `bin/wt` consumes `WT_MACHINE`, stores it in nonexported `WG_MACHINE_RESULT`, and unsets the request.
Nested `wt` calls and `.wt-setup` therefore do not inherit machine-result mode.

`wt_result` in `common.sh` emits records only for a request matching `^[1-9][0-9]*$`.
Each record starts with `WT_RESULT`, one tab, and one compact JSON object on the same line.
Human output can surround the record.
`wt_read_result` in `common.sh` finds and validates the record; it does not parse unrelated lines.
`wt_read_result_into` validates the record before decoding its fields into an associative array.
The doctor checks array becomes a JSON string in that array.

| Field | Value and producer | Reader |
|---|---|---|
| `version` | `wt_result` emits the lower of the requested version and `WT_PROTOCOL`. Protocol 1 VMs therefore emit 1 for every valid request. | `common.sh`: `wt_read_result`. |
| `command` | `new`, `show`, `path`, or `doctor`, supplied by their command functions. | `common.sh`: `wt_read_result` requires the expected command. |
| `status` | `created` for `new`; `found` for `show` or successful `path`; `missing` for an absent `path`; `PASS` or `FAIL` for `doctor`. | `remote.sh`: `host_new`; `recovery.sh`: `host_attach`; `doctor.sh`: `host_contract_doctor`; `bin/cmux-hook`: the `wt-close` handler. |
| `name` | The task name supplied by the producer; empty for `doctor`. | `common.sh`: `vm_result` validates creation names and checks the requested name for lookup results. |
| `repo` | The absolute main checkout path supplied by the producer; empty for `doctor`. | `common.sh`: `vm_result` derives task sessions and requires the requested repository for a missing path. |
| `session` | `common.sh`: `wt_session` supplies `wt-<repo-id>-<name>` for `new` and `show`; `path` and `doctor` supply an empty string. | `common.sh`: `vm_result` requires the derived session name for creation and show results. |
| `state` | `cmd_show` uses `session_state` on a VM. Other producers supply an empty string. | `recovery.sh`: `host_attach` displays it and uses wording only when boolean facts are absent. |
| `agent` | `cmd_show` reports whether the checked tmux probe found an agent. | `host_attach` requires a running agent unless first-start or explicit recovery applies. |
| `attached` | `cmd_show` reports whether tmux lists an attached client. | `host_attach` checks a detached session before reattaching a shell row. |
| `started` | `cmd_show` reports whether the task's started marker exists. | `host_attach` permits a first start only when the marker and session are absent. |
| `path` | `cmd_path` supplies the worktree path for a found result. | `host_open` validates the path before opening VS Code. |

`cmd_contract_doctor` adds a `checks` array to the `doctor` record.
Each entry has `name`, `status`, and `repair` strings.
`doctor_result` collects each check when it prints the check line.
The check status is `PASS`, `FAIL`, or `WARN`.
The `repair` field contains the repair command, including for passing checks.
The overall `status` is `PASS` only when every check passes; failures and warnings produce `FAIL`.
The record uses empty `name`, `repo`, `session`, and `state` fields.
These additional fields keep protocol version 1.

`host_contract_doctor` uses the record and the command exit status to determine success.
It displays the VM text and keeps the Mac protocol comparison separate.
For older VMs without a record, it keeps the marked `WT_COMPAT` text checks.
Malformed or unsupported records cannot use that fallback.
Older Macs continue to read the unchanged VM check lines.

`require_wt` in `task.sh` emits a missing `path` record on standard error and exits 1 through `die`.
It checks the Git worktree registration before reporting absence.
Successful records go to standard output.
Ordinary `wt path` prints only the path when no machine-result request exists.

`wt_read_result` requires exactly one record, unique keys, and scalar values, except for the doctor `checks` array.
It validates a positive integer version and string fields for `status`, `name`, `repo`, `session`, and `state`.
Every key and string value, including unknown fields, must omit control characters below 32 and character 127.
The optional `agent`, `attached`, and `started` fields must be booleans. The optional `path` field must be a string.
Doctor entries require exactly the three string fields above, without control characters.
The reader rejects an overall doctor status that disagrees with its checks.
The reader preserves unknown scalar fields.
Additive fields retain the version; a changed field meaning requires a new version.

The parser returns 1 for malformed records, 2 for absent records, and 3 for unsupported versions.
These are parser statuses, not the remote command's exit status.
`vm_result` uses legacy identity text only when the record is absent.
Version 1 records that omit newer facts retain marked compatibility fallbacks.
They reject malformed or unsupported records.
The unsupported-version path prints a Mac update hint.

`vm_result` reads legacy `created`, `repo:`, and `session:` lines, including the parenthesized state.
For older VMs, `host_attach` sends a compatibility script to check the started marker.
The close handler accepts the legacy missing-worktree text only with remote exit status 1.

`wt_version` in `common.sh` emits `commit` and `protocol`.
`commit` is the short repository commit or `unknown` when no repository is available.
`wt_read_version` in [version.sh](../lib/workgrove/version.sh) requires one object, a nonempty commit string, and a positive integer protocol.
`host_version` and `wt_vm_version` use null fields when an older VM cannot report a valid version.
`host_version` treats SSH failure separately and returns failure.
`doctor_vm` checks VM tools; `host_doctor` requires an equal Mac and VM protocol.

`wt_update_record` in `remote.sh` adds `event: "wt_update"`, `stage`, and `side` to the version object.
Stages are `before` and `after`; sides are `Mac` and `VM` for `host_update`, or `local` for `cmd_update`.
A failed update can stop before the after records.
A failed final version query produces null VM fields without changing a successful update status.

## VM to Mac

`notify_mac` in `task.sh` encodes the request body as JSON strings.
`cmux_notify` in [cmux.sh](../lib/workgrove/cmux.sh) adds `request_id`, then sends through the native cmux-tui socket and terminal.
`bin/cmux-hook --event` reads `CMUX_AUTOMATION_EVENT_JSON` on the Mac.
It requires a `notification.created` event with valid notification and row UUIDs.
It accepts only a remote row with backend `cmux-tui` and reads the record with both matching IDs.

| Notification title | Body fields | Producer | Mac reader and action |
|---|---|---|---|
| `wt-open` | `host`, `path`, `request_id` | `task.sh`: `open_worktree` calls `notify_mac`. `cmux.sh`: `cmux_notify` adds the ID. | `bin/cmux-hook`: `field`, `request_valid`, and the `wt-open` handler open the remote folder through the VS Code CLI. |
| `wt-attach` | `host`, `repo`, `task`, `request_id` | `task.sh`: `request_row` calls `notify_mac`. `cmux.sh`: `cmux_notify` adds the ID. | `bin/cmux-hook`: `field`, `request_valid`, `attach_row`, and the `wt-attach` handler select or create the task row. |
| `wt-close` | `host`, `repo`, `task`, `request_id` | `bin/wt`: `cmd_rm` calls `notify_mac` for self-removal without native terminal-exit cleanup. | `bin/cmux-hook`: `field` and the `wt-close` handler verify absence, close the requesting row, then kill its tmux session. |

`request_id` contains 32 random lowercase hexadecimal characters.
The Mac hook does not read it; its changing value defeats cmux's five-second content suppression.
No request-body version field exists.
`field` reads required string fields and ignores additional fields.

`valid_host`, `known_host`, `hook_safe_path`, and `valid_name` in `common.sh` supply the validation rules.
The host must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and a literal alias in the Mac's `~/.ssh/config`.
`from_row_on_host` in `cmux.sh` requires the requesting row's SSH destination to equal that host.
A task name must match `^[a-z0-9][a-z0-9_-]{0,62}$`.

Paths must be absolute, without newlines, `//`, a trailing slash, or a `..` component.
`hook_safe_path` also rejects single quotes, double quotes, backticks, dollar signs, backslashes, and semicolons.
The open handler additionally requires an executable VS Code CLI.
The [Security section](../README.md#every-host-that-you-open-a-cmux-ssh-row-to-is-inside-this-macs-trust-boundary) explains the host trust boundary.

The close handler requires the requesting row to match the task's title, repository, and host.
It calls `path` with machine results and captures both output streams.
Closure requires remote status 1, record status `missing`, and matching `name` and `repo`.
An absent legacy record permits the missing-worktree text fallback; a malformed record or SSH failure never permits closure.
The handler closes the row before killing the session, so a reconnect cannot recreate that session.

`event_handled` in `bin/cmux-hook` dismisses successful open and attach requests by notification ID.
Closing a row removes its notifications.
The hook exits 0 for rejected requests, retains their notifications, and writes diagnostics to `cmux-hook.log`.
A successful VM send confirms request acceptance only; it does not confirm a Mac action.
`open_worktree` and `request_row` print Mac commands for manual recovery.

## The tmux session environment

`wt_session` in `common.sh` derives `wt-<repo-id>-<name>`.
`repo_id` converts the main checkout basename to letters, digits, and hyphens.
`tmux_cmd` creates a detached session, then executes `tmux attach -d` with an exact `=<session>` target.
The detached session runs the requested command followed by `exec bash`.
An existing task session survives attachment, and `-d` replaces its prior client.

| Session value | Writer | Reader and meaning |
|---|---|---|
| `CMUX_TUI_SOCKET` | `common.sh`: the generated `tmux_cmd` shell copies the attaching row's value. | `relay_env` and the top-level `cmux-tui-hook.sh` wrapper read the current socket. |
| `CMUX_TUI_TERMINAL_ID` | `common.sh`: `tmux_cmd` copies the attaching row's value. | `relay_env` and the wrapper select the terminal that owns requests and agent status. |
| `CMUX_TUI_SESSION_ID` | `common.sh`: `tmux_cmd` copies the attaching row's value. | `relay_env` and the wrapper forward the current native session identity. |
| `CMUX_SOCKET_PATH`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_PANEL_ID`, `CMUX_TAB_ID`, `CMUX_TERMINAL_LIFECYCLE_ID` | `common.sh`: `tmux_cmd` writes empty values in both the attaching shell and task session. | Legacy local/TCP identity cannot replace the current native identity. `is_remote` in `task.sh` therefore uses other inputs. |
| `WT_CMUX_CLOSE_ON_EXIT` | `common.sh`: `tmux_cmd` writes `1` for a normal native task attachment. Client reinitialization preserves its previous value. | `bin/wt`: `cmd_rm` requires the current session to match the task and the exact assignment `WT_CMUX_CLOSE_ON_EXIT=1`. |

For a native self-removal, `cmd_rm` kills the session after removing the worktree and sidecar files.
The executed tmux client exits, which ends the terminal and closes its Mac row.
Without that marker, self-removal requests `wt-close` through the relay and waits 22 seconds by default.
`WT_CLOSE_WAIT_SECONDS` in `cmd_rm` can change that wait; invalid values retain 22.

The `shared` form of `tmux_cmd` serves VM and repository shells.
It attaches without `-d` and does not replace session identity or write the close marker.
The `reinit` form refreshes identity but preserves the existing cleanup marker.

`relay_env` reads session assignments at each request because panes keep their original environment after a reattach.
An explicit empty session assignment clears the pane's value and reaches the child as an empty assignment.
A missing name or a removed `-NAME` entry retains the pane's value in `relay_env`.
The agent wrapper in [cmux-tui-hook.sh](../lib/workgrove/cmux-tui-hook.sh) differs: an empty assignment or `-NAME` unsets the value.
A name absent from the session retains the pane's value in both readers.

`cmd_run` in `bin/wt` saves the original helper in `WT_CMUX_TUI_HOOK` and sets `CMUX_TUI_HOOK` to the workgrove wrapper.
The wrapper uses `TMUX_PANE` to find its session and refreshes identity before each helper call.
The tmux queries read `/dev/null`, so the helper receives the agent payload on standard input.
`cmux_tui_agent_helper` in `cmux.sh` and the wrapper reject wrapper paths as helper targets to prevent recursion.

## Exit statuses and failure handling

`vm_wt_failure` in `common.sh` owns the failure messages and caller policies.
Without parser arguments, it supplies the existing command summary at the `vm_wt` or `vm_result` boundary.
With parser arguments, it combines the SSH status, parser status, and record status into the caller's message and exit status.
A caller supplies its policy, such as `new`, `show`, `path`, or `raw`, in one call.
Creation keeps its inspection advice and preserves status 255 after a disconnection.
`host_version` warns and returns 1 for status 255, so a later version query can retain its fallback.
The hook uses the same message definitions but writes failures to its log.

The hook runs managed SSH registration validation and SSH under the same absolute deadline through `capped`.
`VM_SSH_CHECK_RUN` applies that runner to the Python validation process, including its `ssh -G` children.
The close check reserves 12 seconds for verification and five seconds for session removal after row closure.

When the VM's `wt` fails, `vm_wt` prints one summary line on standard error and preserves the command's exit status.
The line names the subcommand, host, and status: `wt show on <vm> exited 141 (SIGPIPE)`.
For statuses above 128, the line uses the Ubuntu VM's [Linux signal numbers](https://man7.org/linux/man-pages/man7/signal.7.html), including real-time signals.
For unknown or reserved signal numbers, it includes `unknown signal` and the number.

The VM's own standard error also reaches the user.
For `vm_result` calls, a failed `show` includes the inspection command used by attach recovery.
A failed `new` includes a `list` command to inspect possible creation before retrying.
If the VM rejects the model option, the line also includes the existing update command.
Status 255 keeps the existing SSH failure handling below and does not add this summary.

| Status | Boundary and meaning | File and reader |
|---|---|---|
| `0` | The command succeeded. A VM notification send confirms acceptance, not the Mac action. | `cmux.sh`: `cmux_notify`; `task.sh`: `open_worktree`. |
| `3` | `rm` refuses because its Git or file safety checks found work to preserve. Other removal checks can fail with 1. | `bin/wt`: `cmd_rm`; `remote.sh`: `host_rm` preserves the refusal. |
| `1` | `path` cannot find the registered worktree. A requested `path/missing` record goes to standard error. | `task.sh`: `require_wt`; `common.sh`: `die`; `bin/cmux-hook`: `wt-close`. |
| `255` | Raw SSH reports a transport failure. This does not prove that a remote creation failed to finish. | `common.sh`: `vm_wt`, `vm_tmux`; `remote.sh`: `remote_sh_raw`, `host_new`. |
| `1` after SSH `255` | `remote_sh`, `remote_wt`, `host_attach`, `host_open`, and `host_update` print an unreachable-host error through `die`. `host_version` and `host_doctor` also convert connection failure to 1. | `remote.sh`: the named wrappers; `doctor.sh`: `host_doctor`. |
| `142` | A capped hook call exceeded its deadline. A failed lookup cannot authorize another row or removal. | `bin/cmux-hook`: `capped`; `cmux.sh`: `ws_load`. |

Run `wt doctor` on the Mac and `wt -H <vm> doctor` for the VM checks.
Use the [cmux update checklist](cmux-checklist.md) for live flows that the probes cannot establish.
