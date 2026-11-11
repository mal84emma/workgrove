# Agent status in VM rows

This page explains how a VM task's row on the Mac shows the agent's status with cmux 0.65.
The VM rows of cmux 0.65 did not show the agent's status, but local rows did.
This page records the cause, the fix, and how to check it.
[VM requests after cmux 0.65](vm-open-relay.md) covers the other requests from VM tasks.

The [cmux integration contract](cmux-integration.md) lists the commands, fields, and measured behavior.
The [Mac–VM protocol](vm-protocol.md) defines remote commands, records, requests, and the tmux environment.

Use the [cmux update checklist](cmux-checklist.md) after each cmux update.

## Cause of the missing status

Before native status support, workgrove's status relay supported only cmux 0.64 TCP relay rows.
`wt run` started the status owner only when `CMUX_SOCKET_PATH` named a TCP socket.
The former `bin/agent-notify` implementation relayed status only for the same socket.
On a native row, `tmux_cmd` cleared `CMUX_SOCKET_PATH`, so workgrove sent no status.
The fix for `wt open` in [VM requests after cmux 0.65](vm-open-relay.md) did not change that status path.
The TCP status relay has since been removed.
`bin/agent-notify` now remains only as a silent stub for hooks loaded before configuration refresh.

cmux 0.65 has its own status path for native rows.
cmux-tui installs agent hooks in `~/.claude/settings.json` and `~/.codex/hooks.json` on the VM.
Each hook runs `"$CMUX_TUI_HOOK" <agent> <event>`.
Inside tmux, a hook with no `CMUX_TUI_HOOK` runs cmux-tui's default helper.
The helper reports the state to the terminal in `CMUX_TUI_TERMINAL_ID`.
Without that variable, it reports nothing.
The Mac shows the state in the row as `cmux.remote.agent`, with Running, Idle, or Needs input.

In a task's tmux session, the agent gets the wrong terminal ID:

- `tmux_cmd` runs `tmux new-session` before it saves the row's identity in the session environment.
  So the agent's pane starts with tmux's global environment.
- The global environment holds the identity of the row that started the tmux server.
  So the hooks report to that row's terminal, which can belong to another task.
- A reattach gives the row a new terminal.
  A running agent keeps the terminal ID that it started with.

The [wrong-terminal diagnostic evidence](https://github.com/mal84emma/workgrove/pull/46#issuecomment-6775486347) distinguishes the pane's inherited identity from the task session's identity.

## Fix for the status

`wt run` sets `CMUX_TUI_HOOK` to `lib/workgrove/cmux-tui-hook.sh` for its agent.
It saves the previous helper in `WT_CMUX_TUI_HOOK`.
At each hook, the wrapper reads `CMUX_TUI_SOCKET`, `CMUX_TUI_TERMINAL_ID`, and `CMUX_TUI_SESSION_ID` from the task's tmux session.
Then it runs the cmux-tui helper with these values.

An empty value or a removed name in the session unsets the value.
This prevents the helper from reporting to a stale terminal.
A name that the session does not hold keeps the pane's value.
The wrapper never uses a path that ends in `lib/workgrove/cmux-tui-hook.sh` as the helper.
So a nested `wt run` from any checkout cannot make it run itself.

The fix applies only to an agent that `wt run` starts after the update.
For a running agent, exit it and run `wt -H <vm> attach --restart-agent -r <repo> <name>`.
A new tmux pane gets the session's values, so an agent that you start in it reports to the row.
After a reattach, that agent reports to the old terminal until you restart it.
The task's first pane keeps the global values after `wt run` exits, so do not start an agent by hand in it.

Agents that the task's agent starts, such as `claude -p`, inherit the wrapper and report to the same row.
An agent in a native row without tmux behaves the same way.
The removed TCP status relay ignored such agents, but the native wrapper does not.
How the row combines the states of several agents was not tested.

The removed cmux 0.64 heartbeat detected Esc interruptions in Claude's transcript.
On cmux 0.65 rows, only the cmux-tui hooks report the state.
An Esc interruption on a cmux 0.65 row was not tested.

The cmux-tui hooks must be installed on the VM.
`install.sh --refresh-config` preserves foreign hook commands in both JSON files, including the cmux-tui hooks.
A classic refresh rewrites `~/.codex/config.toml` and drops Codex hook trust and folder trust.
Codex can then show `partial` even when its cmux-tui hook groups remain in `hooks.json`.
The install summary names the status check, the repair, and the Codex `/hooks` review.

To check them, run `cmux-tui agent hook status claude codex` on the VM.
Make sure that the `claude` and `codex` providers show `installed`.
If a provider shows `absent` or `partial`, run `cmux-tui agent hook install claude codex`.
In Codex, review and trust the hooks with `/hooks`.
Then restart the agent.

## Verification of the status

The wrapper refreshes native identity at each hook so that status follows the task after reattachment.
[PR #46's archived evidence](https://github.com/mal84emma/workgrove/pull/46#issuecomment-6775486347) preserves the status output and local-row comparison; its exact test date and commit were not recorded.

## Smoke tests

`test/native-relay-smoke.sh` checks the wrapper with a fake tmux and a fake helper.
It checks the values that the helper gets, and that the agent's payload and arguments reach the helper.
It checks that a wrapper path as the saved helper does not make the wrapper run itself.
It stops the wrapper after 5 seconds, so a regression fails the suite instead of hanging it.
It also checks the hook variables that `wt run` gives its agent.

```bash
bash test/native-relay-smoke.sh
shellcheck -x bin/wt lib/workgrove/cmux-tui-hook.sh test/native-relay-smoke.sh
```
