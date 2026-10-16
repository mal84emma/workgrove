#!/usr/bin/env bash
# lib/workgrove/cmux-tui-hook.sh — the agent hook of cmux-tui, run with the current row's identity.
#
# On a VM, cmux 0.65 shows an agent's state in its VM row only through cmux-tui. cmux-tui installs agent
# hooks in ~/.claude/settings.json and ~/.codex/hooks.json. Each hook runs "$CMUX_TUI_HOOK" <agent> <event>.
# Inside tmux, a hook with no CMUX_TUI_HOOK runs cmux-tui's default helper.
# That helper reports the state to the terminal in CMUX_TUI_TERMINAL_ID over CMUX_TUI_SOCKET.
# Without CMUX_TUI_TERMINAL_ID, it reports nothing.
# An agent in a tmux pane keeps the environment that the pane started with, and two cases make it wrong:
# - tmux gives a new session's first pane its global environment. That environment holds the terminal
#   of the row that started the tmux server, so the hook reports to another task's row.
# - A reattach gives the row a new terminal. tmux_cmd saves it in the session environment only.
# `wt run` sets CMUX_TUI_HOOK to this file for its agent. This file reads the identity from the task's tmux
# session at each hook, then runs the cmux-tui helper that WT_CMUX_TUI_HOOK names.
# The helper reads the agent's payload from stdin, so the tmux calls here read /dev/null.
# The hook command discards this file's stderr and exit status, so a missing helper fails silently.
set -u
if [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] && command -v tmux >/dev/null 2>&1; then
  s=$(tmux display-message -p -t "$TMUX_PANE" '#S' </dev/null 2>/dev/null) || s=''
  env=''
  [[ -n $s ]] && env=$(tmux show-environment -t "=$s" </dev/null 2>/dev/null)
  for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do
    # A name that the session does not hold keeps the pane's value, as in relay_env in lib/workgrove/common.sh.
    # An empty or removed name clears the old identity, so the helper cannot report to the previous terminal.
    while IFS= read -r line; do
      case $line in
        "$v="?*) export "$v=${line#*=}"; break ;;
        "$v=" | "-$v") unset "$v"; break ;;
      esac
    done <<<"$env"
  done
fi
# A wrapper from another workgrove checkout must not become the helper: it would run itself on every hook.
helper=${WT_CMUX_TUI_HOOK:-}
case $helper in "" | */lib/workgrove/cmux-tui-hook.sh) helper=${XDG_DATA_HOME:-$HOME/.local/share}/cmux-tui/bin/cmux-tui-hook ;; esac
exec "$helper" "$@"
