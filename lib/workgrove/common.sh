# shellcheck shell=bash
# Reads globals: BASH_SOURCE, HOME, TMUX, WG_EXIT_HANDLERS, WG_MACHINE_RESULT, WG_POLL_INTERVAL,
#   WG_COMMON_LOADED, WG_PREFIX.
# Requires no functions from other modules. Loads cmux.sh and task.sh.
# lib/workgrove/common.sh — shell functions that more than one script in bin/ needs.
# bin/wt, bin/cmux-hook and bin/agent-notify source this file after they hand off to bash 5.
# This file needs bash 5. Bash reads a sourced file one command at a time, so an older bash returns at
# the next line before it parses the rest, and its source fails cleanly.
# After the version check, this file loads the cmux adapter and task core, and defines shared functions.
# It sets no shell options, so it works under the "set -euo pipefail" of bin/wt and the "set -u" of the hooks.
if ((BASH_VERSINFO[0] < 5)); then return 1; fi
# Repeated loads must preserve registered cleanup callbacks and module state.
if [[ ${WG_COMMON_LOADED:-0} == 1 ]]; then return 0; fi
WT_FS=$'\x1f'   # the status line's field separator: git allows '|' in a branch name, and a base like
                # 'feat|x' used to shift every field of the line right, so the branch column printed the base

# shellcheck source=lib/workgrove/cmux.sh
source "${BASH_SOURCE[0]%/*}/cmux.sh" || return

die()  { printf '%s: %s\n' "${WG_PREFIX:-wt}" "$*" >&2; exit 1; }
warn() { printf '%s: %s\n' "${WG_PREFIX:-wt}" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; }
shell_join() { local out="" a; for a in "$@"; do printf -v a '%q' "$a"; out="${out:+$out }$a"; done; printf '%s' "$out"; }
need_jq() { have jq || die "jq not found (brew install jq, or sudo apt-get install -y jq)"; }

# Each callback receives the original exit status, in registration order.
WG_EXIT_HANDLERS=()
on_exit() {
  WG_EXIT_HANDLERS+=("$1")
  trap 'wg_on_exit "$?"' EXIT
}
wg_on_exit() {
  local rc=$1 handler
  for handler in "${WG_EXIT_HANDLERS[@]}"; do
    "$handler" "$rc" || true
  done
  return "$rc"
}

# shellcheck source=lib/workgrove/task.sh
source "${BASH_SOURCE[0]%/*}/task.sh" || return

# Prefix all internal locals with __ in functions that accept or forward output variable names.
# This includes local -n references. Callers must not use __ for output variables.

# Tests can shorten poll waits. Production waits one second unless WG_POLL_INTERVAL is set.
wg_sleep() { sleep "${WG_POLL_INTERVAL:-1}"; }

# valid_host <alias> — an ssh alias: letters, digits, '.', '_' and '-', with a letter or digit first.
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# The Mac hook (bin/cmux-hook) drops any other path, so never relay a path that fails this.
hook_safe_path() { [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *//* && "$1" != */ && "$1" != *'/../'* && "$1" != */.. && "$1" != *[\'\"\`\$\\\;]* ]]; }

# Identity. bin/wt and bin/cmux-hook take a task's row title, repo id and tmux session from these functions.
# A row's title tells which task it is. Its description (row_tag in task.sh) tells which machine
# and which repo. Two repos can have tasks with the same name, so the title alone does not identify a row.
# attach_row in bin/cmux-hook writes the description of the rows that it relays in the same format as
# row_tag, so keep the two byte-compatible.
repo_id()    { printf '%s' "${1##*/}" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'; }
row_title()  { printf '%s' "$1"; }                                          # row_title <name> — a task row's title
wt_session() { printf 'wt-%s-%s' "$(repo_id "$2")" "$1"; }                  # wt_session <name> <repo>
# valid_name <name> — a task name: lowercase letters, digits, '_' and '-', max 63, no '.'.
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; }

wt_result() {
  [[ ${WG_MACHINE_RESULT:-} == 1 ]] || return 0
  printf 'WT_RESULT\t'
  jq -cn --arg command "$1" --arg status "$2" --arg name "$3" --arg repo "$4" \
    --arg session "${5:-}" --arg state "${6:-}" \
    '{version:1, command:$command, status:$status, name:$name, repo:$repo, session:$session, state:$state}'
}

wt_read_result() {
  local output=$1 command=$2 records=()
  mapfile -t records < <(printf '%s\n' "$output" | sed -n $'/^WT_RESULT\t/p')
  [[ ${#records[@]} -gt 0 ]] || return 2
  [[ ${#records[@]} -eq 1 ]] || return 1
  printf '%s\n' "${records[0]#*$'\t'}" | jq --stream -esc --arg command "$command" '
    map(select(length == 2)) as $fields
    | if (map(select(length == 1)) | length) == 1
        and all($fields[]; (.[0] | length == 1 and (.[0] | type == "string"))
          and (.[1] | type != "array" and type != "object"))
        and ($fields | map(.[0]) | unique | length) == ($fields | length)
      then $fields | map({key: .[0][0], value: .[1]}) | from_entries
      else error("invalid wt result") end
    | if .version == 1 and .command == $command
        and all(.status, .name, .repo, .session, .state; type == "string" and (explode | all(. >= 32 and . != 127)))
      then . else error("invalid wt result") end' 2>/dev/null || return 1
}

# cmux authorizes relay requests against the current row's identity. A reattach changes the tmux session
# environment, but panes keep their original values. Read the session environment at each call.
# Read the three CMUX_TUI_* variables with the same precedence.
#
# Empty session values clear the previous transport. Missing names and "-NAME" keep the pane's value.
# Include explicit empty session assignments in the identity array.
# This prevents a child from inheriting a cleared identity from the pane.
# Keep absent pane names unset in the child.
#
# relay_env <identity array output> <native socket output> <native terminal output>
# It returns nonzero when a native relay identity is unavailable.
relay_env() {
  local -n __relay_ident=$1 __relay_tui_socket=$2 __relay_tui_terminal=$3
  local __session_name='' __session_env='' __variable __value __line __session_match
  local __relay_vars=(CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID)
  __relay_ident=(); __relay_tui_socket=''; __relay_tui_terminal=''
  if [[ -n ${TMUX:-} ]] && command -v tmux >/dev/null 2>&1; then
    __session_name=$(tmux display-message -p '#S' </dev/null 2>/dev/null || true)
  fi
  if [[ -n $__session_name ]]; then
    __session_env=$(tmux show-environment -t "=$__session_name" </dev/null 2>/dev/null || true)
  fi
  for __variable in "${__relay_vars[@]}"; do
    __value=${!__variable:-}
    __session_match=0
    while IFS= read -r __line; do
      case $__line in
        "$__variable="*) __value=${__line#*=}; __session_match=1; break ;;
      esac
    done <<< "$__session_env"
    if [[ -n $__value || $__session_match == 1 ]]; then __relay_ident+=("$__variable=$__value"); fi
    case $__variable in
      CMUX_TUI_SOCKET) __relay_tui_socket=$__value ;;
      CMUX_TUI_TERMINAL_ID) __relay_tui_terminal=$__value ;;
    esac
  done
  [[ $__relay_tui_socket == /* && $__relay_tui_terminal =~ ^term_[a-f0-9]{32}$ ]] && return 0
  return 1
}


ssh_hosts() { # non-wildcard Host aliases in ~/.ssh/config, one per line. known_host reads the same list.
  { awk '$1=="Host"{for(i=2;i<=NF;i++){if($i ~ /^#/)break; if($i !~ /^[!]/ && $i !~ /[*?]/) print $i}}' "$HOME/.ssh/config" 2>/dev/null || true; } | sort -u
}
# known_host <alias> — the alias is one that ssh_hosts prints. grep reads all its input (no -q),
# so sort never gets SIGPIPE, and the answer stays correct under pipefail.
known_host() { ssh_hosts | grep -xF -- "$1" >/dev/null; }

tmux_cmd() { # tmux_cmd <session> [command] [shared] [reinit]
  # The line that a VM row's shell runs. It creates that tmux session (running <command>, then a shell) or
  # takes over the session that is already there. A task row owns its session, so it attaches with -d.
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
    printf "for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export \"\$v=\"; tmux set-environment -t '=%s' \"\$v\" ''; done; " "$1"
    printf "for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=%s' \"\$v\" \"\$(printenv \"\$v\")\"; done; %sexec tmux attach -d -t '=%s'" "$1" "$native_mark" "$1"
  fi
}

WG_COMMON_LOADED=1
