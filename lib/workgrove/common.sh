# shellcheck shell=bash
# lib/workgrove/common.sh — shell functions that more than one script in bin/ needs.
# bin/wt, bin/cmux-hook and bin/agent-notify source this file after they hand off to bash 5.
# This file needs bash 5. Bash reads a sourced file one command at a time, so an older bash returns at
# the next line before it parses the rest, and its source fails cleanly.
# Apart from that version check, this file only defines functions. It sets no shell options,
# so it works under the "set -euo pipefail" of bin/wt and under the "set -u" of the hooks.
if ((BASH_VERSINFO[0] < 5)); then return 1; fi

# valid_host <alias> — an ssh alias: letters, digits, '.', '_' and '-', with a letter or digit first.
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# The Mac hook (bin/cmux-hook) drops any other path, so never relay a path that fails this.
hook_safe_path() { [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *//* && "$1" != */ && "$1" != *'/../'* && "$1" != */.. && "$1" != *[\'\"\`\$\\\;]* ]]; }

# Identity. bin/wt and bin/cmux-hook take a task's row title, repo id and tmux session from these functions.
# A row's title tells which task it is. Its description (row_tag in bin/wt) tells which machine
# and which repo. Two repos can have tasks with the same name, so the title alone does not identify a row.
# attach_row in bin/cmux-hook writes the description of the rows that it relays in the same format as
# row_tag, so keep the two byte-compatible.
repo_id()    { printf '%s' "${1##*/}" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'; }
row_title()  { printf '%s' "$1"; }                                          # row_title <name> — a task row's title
wt_session() { printf 'wt-%s-%s' "$(repo_id "$2")" "$1"; }                  # wt_session <name> <repo>
# valid_name <name> — a task name: lowercase letters, digits, '_' and '-', max 63, no '.'.
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; }

# cmux authorizes relay requests against the current row's identity. A reattach changes the tmux session
# environment, but panes keep their original values. Read the session environment at each call.
# Both callers read the three CMUX_TUI_* variables so the native identity follows the same precedence.
#
# Empty session values clear the previous transport. Missing names and "-NAME" keep the pane's value.
# Include explicit empty session assignments in RELAY_IDENT so a child cannot inherit a cleared identity from the pane.
# Keep absent pane names unset in the child.
#
# relay_env sets RELAY_SOCKET, RELAY_WS, RELAY_TUI_SOCKET, RELAY_TUI_TERMINAL and RELAY_IDENT.
# It returns nonzero when neither a native relay identity nor a TCP relay socket is available.
# shellcheck disable=SC2034
relay_env() {
  local session_name='' session_env='' variable value line session_match
  local relay_vars=(CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID
                    CMUX_TERMINAL_LIFECYCLE_ID CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID)
  RELAY_IDENT=(); RELAY_SOCKET=''; RELAY_WS=''; RELAY_TUI_SOCKET=''; RELAY_TUI_TERMINAL=''
  if [[ -n ${TMUX:-} ]] && command -v tmux >/dev/null 2>&1; then
    session_name=$(tmux display-message -p '#S' </dev/null 2>/dev/null || true)
  fi
  if [[ -n $session_name ]]; then
    session_env=$(tmux show-environment -t "=$session_name" </dev/null 2>/dev/null || true)
  fi
  for variable in "${relay_vars[@]}"; do
    value=${!variable:-}
    session_match=0
    while IFS= read -r line; do
      case $line in
        "$variable="*) value=${line#*=}; session_match=1; break ;;
      esac
    done <<< "$session_env"
    if [[ -n $value || $session_match == 1 ]]; then RELAY_IDENT+=("$variable=$value"); fi
    case $variable in
      CMUX_SOCKET_PATH) RELAY_SOCKET=$value ;;
      CMUX_WORKSPACE_ID) RELAY_WS=$value ;;
      CMUX_TUI_SOCKET) RELAY_TUI_SOCKET=$value ;;
      CMUX_TUI_TERMINAL_ID) RELAY_TUI_TERMINAL=$value ;;
    esac
  done
  [[ $RELAY_TUI_SOCKET == /* && $RELAY_TUI_TERMINAL =~ ^term_[a-f0-9]{32}$ ]] && return 0
  [[ $RELAY_SOCKET == *:[0-9]* ]]
}

ssh_hosts() { # non-wildcard Host aliases in ~/.ssh/config, one per line. known_host reads the same list.
  { awk '$1=="Host"{for(i=2;i<=NF;i++){if($i ~ /^#/)break; if($i !~ /^[!]/ && $i !~ /[*?]/) print $i}}' "$HOME/.ssh/config" 2>/dev/null || true; } | sort -u
}
# known_host <alias> — the alias is one that ssh_hosts prints. grep reads all its input (no -q),
# so sort never gets SIGPIPE, and the answer stays correct under pipefail.
known_host() { ssh_hosts | grep -xF -- "$1" >/dev/null; }

tmux_cmd() { # tmux_cmd <session> [command] [shared] [reinit]
  # The line that a VM row's shell runs. It creates that tmux session (running <command>, then a shell) or
  # takes over the session that is already there. A task row owns its session, so it attaches with -d. It
  # hands the session THIS row's relay socket and workspace id. That makes `cmux notify` from inside the
  # session light up this row.
  # After "remote session was lost", cmux starts a shell that carries none of the CMUX_* variables.
  # The file ~/.tmux.conf lists CMUX_SOCKET_PATH and CMUX_WORKSPACE_ID in update-environment (install.sh
  # links home/.tmux.conf with --with-tmux-conf, or appends that one line to the file you already have).
  # So an attach from that shell would mark them removed in the session and silence `cmux notify` there.
  # Therefore, when the shell has none, the line takes each variable from the session (the row's old relay
  # port stays bound to the row). It sets each one only when it is non-empty.
  # A native attachment clears TCP values. A TCP attachment clears native values to override stale panes.
  # A session that you may also be in yourself (the VM shell, a repo shell) gets "shared" instead. Then the
  # row joins your clients and does not evict them, and it leaves their relay socket as it is.
  # Native cmux closes a row when its terminal exits. Exec the tmux client so self-removal ends that terminal.
  local run="" native_mark=""
  # Replacing an old client does not replace its parent shell. Preserve its original cleanup contract.
  [[ ${4:-} == reinit ]] || native_mark="tmux set-environment -t '=$1' WT_CMUX_CLOSE_ON_EXIT 1; "
  [[ -n "${2:-}" ]] && printf -v run '%q' "$2; exec bash"
  if [[ "${3:-}" == shared ]]; then
    printf "tmux new-session -d -s '%s' %s 2>/dev/null; tmux attach -t '=%s'" "$1" "$run" "$1"
  else
    printf "tmux new-session -d -s '%s' %s 2>/dev/null; " "$1" "$run"
    # Bind the current transport before reading the old session's identity.
    printf "if [ -n \"\$CMUX_TUI_SOCKET\" ]; then for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export \"\$v=\"; tmux set-environment -t '=%s' \"\$v\" ''; done; " "$1"
    printf "for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=%s' \"\$v\" \"\$(printenv \"\$v\")\"; done; %sexec tmux attach -d -t '=%s'; fi; " "$1" "$native_mark" "$1"
    printf "[ -n \"\$CMUX_SOCKET_PATH\" ] || export CMUX_SOCKET_PATH=\"\$(tmux show-environment -t '=%s' CMUX_SOCKET_PATH 2>/dev/null | sed -n 's/^CMUX_SOCKET_PATH=//p')\"; [ -n \"\$CMUX_WORKSPACE_ID\" ] || export CMUX_WORKSPACE_ID=\"\$(tmux show-environment -t '=%s' CMUX_WORKSPACE_ID 2>/dev/null | sed -n 's/^CMUX_WORKSPACE_ID=//p')\"; [ -n \"\$CMUX_SOCKET_PATH\" ] && tmux set-environment -t '=%s' CMUX_SOCKET_PATH \"\$CMUX_SOCKET_PATH\"; [ -n \"\$CMUX_WORKSPACE_ID\" ] && tmux set-environment -t '=%s' CMUX_WORKSPACE_ID \"\$CMUX_WORKSPACE_ID\"; " "$1" "$1" "$1" "$1"
    printf "for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do export \"\$v=\"; tmux set-environment -t '=%s' \"\$v\" ''; done; tmux attach -d -t '=%s'" "$1" "$1"
  fi
}
