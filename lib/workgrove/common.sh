# shellcheck shell=bash
# Reads globals: BASH_SOURCE, HOME, TMUX, WG_EXIT_HANDLERS, WG_MACHINE_RESULT, WG_POLL_INTERVAL,
#   VM_SSH_RUN, VM_WT_CAPTURE_FAILURE, WG_COMMON_LOADED, WG_PREFIX, WG_VERSION_ROOT, WT_PROTOCOL, WT_TMPFILES.
# Requires no functions from other modules. Loads cmux.sh, task.sh, options.sh, and version.sh.
# lib/workgrove/common.sh — shell functions that more than one script in bin/ needs.
# bin/wt, bin/cmux-hook and bin/agent-notify source this file after they hand off to bash 5.
# This file needs bash 5. Bash reads a sourced file one command at a time, so an older bash returns at
# the next line before it parses the rest, and its source fails cleanly.
# After the version check, this file loads the cmux adapter and task core, and defines shared functions.
# It sets no shell options, so it works under the "set -euo pipefail" of bin/wt and the "set -u" of the hooks.
if ((BASH_VERSINFO[0] < 5)); then return 1; fi
# Repeated loads must preserve registered cleanup callbacks and module state.
if [[ ${WG_COMMON_LOADED:-0} == 1 ]]; then return 0; fi
WT_PROTOCOL=1
WG_VERSION_ROOT=${BASH_SOURCE[0]%/*}/../..
# shellcheck source=lib/workgrove/version.sh
source "${BASH_SOURCE[0]%/*}/version.sh" || return
WT_FS=$'\x1f'   # cmux row fields use a separator that preserves empty values.

# shellcheck source=lib/workgrove/cmux.sh
source "${BASH_SOURCE[0]%/*}/cmux.sh" || return

die()  { printf '%s: %s\n' "${WG_PREFIX:-wt}" "$*" >&2; exit 1; }
warn() { printf '%s: %s\n' "${WG_PREFIX:-wt}" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; }
# Keep printf %q output, but escape leading = and ~ for zsh.
# Replace bash-specific ANSI-C quotes with POSIX single quotes for sh.
shell_join() {
  local out="" a quoted
  for a in "$@"; do
    printf -v quoted '%q' "$a"
    case $quoted in
      \$\'*) a=${a//\'/\'\\\'\'}; quoted="'$a'" ;;
      [=~]*) quoted="\\$quoted" ;;
    esac
    out="${out:+$out }$quoted"
  done
  printf '%s' "$out"
}
need_jq() { have jq || die "jq not found (brew install jq, or sudo apt-get install -y jq)"; }

# Each callback receives the original exit status, in registration order.
WG_EXIT_HANDLERS=()
on_exit() {
  WG_EXIT_HANDLERS+=("$1")
  trap 'wg_on_exit "$?"' EXIT
}
wg_on_exit() {
  local handler
  # Callbacks cannot change the positional arguments of this dispatcher.
  for handler in "${WG_EXIT_HANDLERS[@]}"; do
    "$handler" "$1" || true
  done
  return "$1"
}

# shellcheck source=lib/workgrove/task.sh
source "${BASH_SOURCE[0]%/*}/task.sh" || return

# shellcheck source=lib/workgrove/options.sh
source "${BASH_SOURCE[0]%/*}/options.sh" || return

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
  [[ ${WG_MACHINE_RESULT:-} =~ ^[1-9][0-9]*$ ]] || return 0
  local facts=${7-}
  [[ -n $facts ]] || facts='{}'
  # WT_COMPAT: Keep version 1 emission until no Mac requests protocol 1.
  printf 'WT_RESULT\t'
  jq -cn --arg command "$1" --arg status "$2" --arg name "$3" --arg repo "$4" \
    --arg session "${5:-}" --arg state "${6:-}" --argjson facts "$facts" \
    --argjson protocol "$WT_PROTOCOL" --arg requested "$WG_MACHINE_RESULT" \
    '{version:([$protocol, ($requested | tonumber)] | min), command:$command, status:$status, name:$name, repo:$repo, session:$session, state:$state} + $facts'
}

wt_version() (
  local commit=unknown variable
  # Git hooks can export another repository's paths. Clear them only in this lookup subprocess.
  while IFS= read -r variable; do unset "$variable"; done < <(git rev-parse --local-env-vars)
  if [[ -e $WG_VERSION_ROOT/.git ]]; then
    commit=$(git -C "$WG_VERSION_ROOT" rev-parse --short HEAD 2>/dev/null) || commit=unknown
  fi
  jq -cn --arg commit "$commit" --argjson protocol "$WT_PROTOCOL" '{commit:$commit,protocol:$protocol}'
)

# Unknown scalar keys are kept. New fields are additive.
# Increase the version only when a field changes meaning.
# Unsupported versions also print an update hint for callers such as the Mac hook.
# Keep the protocol 1 decoder when the maximum accepted version increases.
# Return 1 for malformed records, 2 for absent records, and 3 for unsupported versions.
wt_read_result() {
  local output=$1 command=$2 parsed records=()
  mapfile -t records < <(printf '%s\n' "$output" | sed -n $'/^WT_RESULT\t/p')
  [[ ${#records[@]} -gt 0 ]] || return 2
  [[ ${#records[@]} -eq 1 ]] || return 1
  parsed=$(printf '%s\n' "${records[0]#*$'\t'}" | jq --stream -esc --arg command "$command" '
    map(select(length == 2)) as $fields
    | if (map(select(length == 1)) | length) == 1
        and all($fields[]; (.[0] | length == 1 and (.[0] | type == "string"))
          and (.[1] | type != "array" and type != "object"))
        and ($fields | map(.[0]) | unique | length) == ($fields | length)
      then $fields | map({key: .[0][0], value: .[1]}) | from_entries
      else error("invalid wt result") end
    | if (.version | type == "number" and . >= 1 and floor == .) and .command == $command
      then . else error("invalid wt result") end' 2>/dev/null) || return 1
  if jq -e --argjson protocol "$WT_PROTOCOL" '.version > $protocol' <<<"$parsed" >/dev/null; then
    warn "unsupported result protocol; run wt update on the Mac"
    return 3
  fi
  jq -ec --argjson protocol "$WT_PROTOCOL" '
      if .version == 1 and .version <= $protocol
        and all(.status, .name, .repo, .session, .state; type == "string" and (explode | all(. >= 32 and . != 127)))
        and all(to_entries[]; (.key | explode | all(. >= 32 and . != 127))
          and (.value | if type == "string" then (explode | all(. >= 32 and . != 127)) else true end))
        and all(to_entries[]; if .key == "agent" or .key == "attached" or .key == "started"
          then (.value | type == "boolean")
          elif .key == "path" then (.value | type == "string" and (explode | all(. >= 32 and . != 127)))
          else true end)
      then . else error("invalid wt result") end' <<<"$parsed" 2>/dev/null || return 1
}

# Decode only after validation rejects control characters in every key and string value.
wt_read_result_into() {
  local -n __result_fields=$3
  local __result_json __field_key __field_value
  __result_fields=()
  __result_json=$(wt_read_result "$1" "$2" 2>/dev/null) || return $?
  while IFS= read -r -d '' __field_key && IFS= read -r -d '' __field_value; do
    [[ -n $__field_key ]] || continue
    # shellcheck disable=SC2004  # The output names an associative array.
    __result_fields[$__field_key]=$__field_value
  done < <(jq -j 'to_entries[] | .key, "\u0000", (.value | tostring), "\u0000"' <<<"$__result_json")
}

# These builders do not run commands or report errors.
# shellcheck disable=SC2016  # HOME belongs to the VM shell.
vm_wt_line() { printf 'exec "$HOME/.local/bin/wt" %s' "$(shell_join "$@")"; }
# shellcheck disable=SC2016  # HOME belongs to the VM shell.
vm_run_line() { printf '"$HOME/.local/bin/wt" run %s' "$(shell_join "$1" -r "$2")"; }

# The hook injects its deadline runner here, as it does for cmux calls.
VM_SSH_RUN=(ssh)
vm_ssh() {
  local host=$1 line=$2; shift 2
  ssh_host_check "$host" || return 1
  "${VM_SSH_RUN[@]}" -o BatchMode=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$@" "$host" "$line"
}

vm_wt_failure() {
  local host=$1 sub=$2 rc=$3 hint=${4:-} signal='' detail=''
  if ((rc != 0 && rc != 255)); then
    if ((rc > 128)); then
      # Ubuntu VMs use Linux signal numbers, which differ from the Mac's numbers.
      local number=$((rc - 128))
      local names=('' HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM
        STKFLT CHLD CONT STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO PWR SYS)
      if ((number < ${#names[@]})); then
        signal="SIG${names[number]}"
      # Ubuntu's thread library reserves signal numbers 32 and 33.
      elif ((number == 34)); then
        signal=SIGRTMIN
      elif ((number == 64)); then
        signal=SIGRTMAX
      elif ((number > 34 && number < 64)); then
        signal="SIGRTMIN+$((number - 34))"
      fi
      if [[ -n $signal ]]; then
        detail=" ($signal)"
      else
        detail=" (unknown signal $number)"
      fi
    fi
    printf 'wt %s on %s exited %s%s%s\n' "$sub" "$host" "$rc" "$detail" "${hint:+; $hint}" >&2
  fi
  return 0
}

# Preserve SSH's exit status. Callers decide how to report transport failures.
vm_wt() {
  local host=$1 machine='' tty=() guard rc=0; shift
  case ${1:-} in
    --machine) machine="WT_MACHINE=$WT_PROTOCOL "; shift ;;
    --tty) [[ ! -t 0 ]] || tty=(-t); shift ;;
  esac
  # shellcheck disable=SC2016
  guard='test -x "$HOME/.local/bin/wt" || { printf "%s\n" '
  guard+="$(shell_join "remote wt is missing; run: wt -H $host doctor --json; wt -H $host setup --root <persistent-root>")"
  guard+=' >&2; exit 127; }; '
  vm_ssh "$host" "$guard$machine$(vm_wt_line "$@")" "${tty[@]}" || rc=$?
  # vm_result adds recovery advice after it reads both captured streams.
  if [[ ${VM_WT_CAPTURE_FAILURE:-0} != 1 ]]; then vm_wt_failure "$host" "$1" "$rc"; fi
  return "$rc"
}

vm_tmux() {
  local q; q=$(shell_join "=$3")
  case $2 in
    kill-session|has-session) vm_ssh "$1" "exec tmux $2 -t $q" ;;
    detached) vm_ssh "$1" "tmux has-session -t $q 2>/dev/null && c=\$(tmux list-clients -t $q 2>/dev/null) && [ -z \"\$c\" ]" ;;
    *) return 2 ;;
  esac
}

# vm_result <host> <sub> <record array> <stdout> <stderr> <command status> -- <args...>
# Return the parser status separately from the command status. Never retry a command.
# Return 2 when text output lacks the required identity, 1 for invalid records, and 3 for newer protocols.
vm_result() {
  local __host=$1 __sub=$2
  local __fields_output=$3
  local -n __vm_record=$3 __visible=$4 __errors=$5 __vm_rc=$6
  shift 7
  local __raw __stdout __stderr __stderr_file __parse=0 __value __name='' __repo='' __arg __want_repo=0 __hint='' __summary
  __vm_record=() __visible='' __errors='' __vm_rc=0
  for __arg in "$@"; do
    if [[ $__want_repo == 1 ]]; then __repo=$__arg; __want_repo=0; continue; fi
    case $__arg in
      -r|--repo) __want_repo=1 ;;
      --repo=*) __repo=${__arg#*=} ;;
      -*) ;;
      *) [[ -n $__name ]] || __name=$__arg ;;
    esac
  done
  __stderr_file=$(mktemp "${TMPDIR:-/tmp}/wt-vm-stderr.XXXXXX") || { __vm_rc=1; return 1; }
  WT_TMPFILES+=("$__stderr_file")
  __stdout=$(VM_WT_CAPTURE_FAILURE=1 vm_wt "$__host" --machine "$__sub" "$@" 2>"$__stderr_file") || __vm_rc=$?
  __stderr=$(cat "$__stderr_file")
  rm -f "$__stderr_file"
  case $__sub in
    new)
      __hint="the worktree may exist; inspect with: wt -H $__host list"
      [[ -z $__repo ]] || __hint+=" -r $(shell_join "$__repo")"
      __hint+=' before retrying'
      # WT_COMPAT: Remove when every VM accepts the model option.
      case $__stdout$'\n'$__stderr in
        *'new: unknown option -m'*|*'new: unknown option --model'*) __hint+="; update with: wt -H $__host update" ;;
      esac ;;
    show) __hint="try: wt -H $__host show $(shell_join "$__name" -r "$__repo")" ;;
  esac
  __raw=$__stdout$'\n'$__stderr
  __visible=$(printf '%s\n' "$__stdout" | sed $'/^WT_RESULT\t/d')
  __errors=$(printf '%s\n' "$__stderr" | sed $'/^WT_RESULT\t/d')
  __summary=$(vm_wt_failure "$__host" "$__sub" "$__vm_rc" "$__hint" 2>&1)
  if [[ -n $__summary ]]; then __errors+="${__errors:+$'\n'}$__summary"; fi
  wt_read_result_into "$__raw" "$__sub" "$__fields_output" || __parse=$?
  case $__parse in
    0)
      [[ ${__vm_record["name"]} == "$__name" || $__sub == new ]] || return 1
      if [[ $__sub == path && ${__vm_record["status"]} == missing ]]; then
        [[ ${__vm_record["repo"]} == "$__repo" ]] || return 1
        return 0
      fi ;;
    2)
      # WT_COMPAT: Remove text decoding when every VM emits protocol 1 records.
      case $__sub in
        new|show)
          __vm_record["repo"]=$(sed -n 's/^ *repo: *//p' <<<"$__visible" | sed -n '1p')
          __value=$(sed -n 's/^ *session: *//p' <<<"$__visible" | sed -n '1p')
          __vm_record["session"]=${__value%% *}
          if [[ $__sub == new ]]; then
            __vm_record["name"]=$(sed -n 's/^created //p' <<<"$__visible" | sed -n '1p')
            __vm_record["status"]=created
          else
            __vm_record["name"]=$__name __vm_record["status"]=found
            __value=${__value#*(}; __vm_record["state"]=${__value%)}
          fi ;;
        path)
          __vm_record["name"]=$__name __vm_record["repo"]=$__repo
          if [[ $__vm_rc == 1 && $__raw == *"no worktree named '$__name' in $__repo"* ]]; then
            __vm_record["status"]=missing
          elif [[ $__vm_rc == 0 ]]; then
            __vm_record["status"]=found __vm_record["path"]=$__visible
          else return 2; fi
          return 0 ;;
        *) return 2 ;;
      esac ;;
    *) return "$__parse" ;;
  esac
  case $__sub in
    new|show)
      [[ -n ${__vm_record["name"]} && -n ${__vm_record["repo"]} && -n ${__vm_record["session"]} ]] || return 2
      valid_name "${__vm_record["name"]}" &&
        [[ ${__vm_record["session"]} == "$(wt_session "${__vm_record["name"]}" "${__vm_record["repo"]}")" ]] || return 1 ;;
    path)
      # WT_COMPAT: Protocol 1 originally sent the path only in display text.
      [[ -v __vm_record["path"] ]] || __vm_record["path"]=$__visible ;;
  esac
  return 0
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
# Validate every imported fragment before OpenSSH can process the configuration.
# Ordinary configurations retain OpenSSH's existing behavior and need no Python runtime.
ssh_host_check() {
  local config="$HOME/.ssh/config"
  [[ -f $config ]] || return 0
  LC_ALL=C grep -F 'wt-ssh-host' "$config" >/dev/null || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    warn 'managed SSH registration needs Python 3 for validation'
    return 1
  fi
  python3 -B "$WG_VERSION_ROOT/lib/workgrove/ssh_host.py" check "$1"
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
