# shellcheck shell=bash
# Reads globals: WG_LIB_DIR, WG_VERSION_ROOT, WG_CMUX_SUPPORTED, WT_PROTOCOL, HOME, WT_HOST, WT_REPOS_DIR.
# Requires common.sh, task.sh, cmux.sh, options.sh, and remote.sh from bin/wt.

# Keep checking after a failure so one run reports every repair.
doctor_result() {
  if [[ $1 == 0 ]]; then printf 'PASS %s\n' "$2"
  else
    printf '%s %s\n' "${4:-FAIL}" "$2"
    [[ -z ${5:-} ]] || printf '  %s\n' "$5"
    printf '  Fix: %s\n' "$3"
    DOCTOR_FAILED=1
  fi
}

doctor_json() {
  jq -e "$2" <<<"$1" >/dev/null 2>&1
}

# Accept static shell words and command separators without evaluating hook text.
# Dynamic expansions require an executable helper file instead of an inline hook.
doctor_words() {
  local rest=$1 word segment kind assignment
  local bare='^[A-Za-z0-9_./:=@%+,!-]+' single="^'([^']*)'" double='^"([^"\\]*)"' escaped='^\\(.)'
  local blank='^[[:blank:]]+' operator=$'^(&&|\\|\\||[;|\n])'
  DOCTOR_WORDS=() DOCTOR_KINDS=()
  while [[ -n $rest ]]; do
    if [[ $rest =~ $blank ]]; then rest=${rest:${#BASH_REMATCH[0]}}; continue; fi
    if [[ $rest =~ $operator ]]; then
      DOCTOR_WORDS+=("${BASH_REMATCH[0]}"); DOCTOR_KINDS+=(operator)
      rest=${rest:${#BASH_REMATCH[0]}}; continue
    fi
    word='' kind='' assignment=0
    while [[ -n $rest ]]; do
      if [[ $rest =~ $bare ]]; then
        segment=${BASH_REMATCH[0]}
        if [[ -z $kind && $segment =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then assignment=1; fi
        word+=$segment; rest=${rest:${#segment}}
      elif [[ $rest =~ $single ]]; then
        word+=${BASH_REMATCH[1]}; rest=${rest:${#BASH_REMATCH[0]}}
      elif [[ $rest =~ $double ]]; then
        segment=${BASH_REMATCH[1]}; rest=${rest:${#BASH_REMATCH[0]}}
        [[ ! $segment =~ \$HOME[A-Za-z0-9_] ]] || return 2
        segment=${segment//\$\{HOME\}/$HOME}; segment=${segment//\$HOME/$HOME}
        [[ $segment != *'$'* && $segment != *'`'* ]] || return 2
        word+=$segment
      elif [[ $rest == \~/* && -z $kind ]]; then
        word+=$HOME/; rest=${rest:2}
      elif [[ $rest == "\${HOME}"* ]]; then word+=$HOME; rest=${rest:7}
      elif [[ $rest =~ ^\$HOME([^A-Za-z0-9_]|$) ]]; then word+=$HOME; rest=${rest:5}
      elif [[ $rest =~ $escaped ]]; then
        word+=${BASH_REMATCH[1]}; rest=${rest:${#BASH_REMATCH[0]}}
      else break; fi
      kind=word
    done
    [[ $kind == word ]] || return 2
    # Quoting the assignment name makes it a command word in shell syntax.
    if [[ $word =~ ^[A-Za-z_][A-Za-z0-9_]*= && $assignment == 0 ]]; then return 2; fi
    DOCTOR_WORDS+=("$word"); DOCTOR_KINDS+=(word)
  done
}

doctor_executable() {
  local path=$1
  if [[ $path != */* ]]; then path=$(type -P -- "$path") || return 1; fi
  [[ -f $path && -x $path ]] || return 1
  printf '%s' "$path"
}

doctor_simple_hook() {
  local word path
  while (($#)); do
    case $1 in
      exec|command) shift ;;
      *)
        if [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          doctor_static_environment "${1%%=*}" || return 2
          shift
        else break; fi ;;
    esac
  done
  (($#)) || return 2
  path=$1; shift
  case $path in
    if|then|else|fi|for|while|do|done|case|"esac"|function|source|.|cd|pushd|popd|export|unset|eval|set|trap|alias|hash|builtin) return 2 ;;
  esac
  path=$(doctor_executable "$path") || return 1
  case ${path##*/} in
    env)
      while (($#)); do
        case $1 in
          -u|--unset) (($# >= 2)) || return 1; doctor_static_environment "$2" || return 2; shift 2 ;;
          -i|--ignore-environment) return 2 ;;
          --) shift; break ;;
          --unset=*) doctor_static_environment "${1#*=}" || return 2; shift ;;
          -*) return 2 ;;
          *) break ;;
        esac
      done
      while (($#)) && [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        doctor_static_environment "${1%%=*}" || return 2
        shift
      done
      (($#)) || return 2
      path=$(doctor_executable "$1") || return 1
      doctor_simple_hook "$path" "${@:2}" ;;
    command|exec) doctor_simple_hook "$@" ;;
    sh|bash|zsh)
      while (($#)); do
        word=$1; shift
        case $word in
          --) break ;;
          -c) (($#)) && doctor_hook_path "$1"; return ;;
          --norc|--noprofile|--posix) ;;
          -o|+o|--rcfile|--init-file|--login) return 2 ;;
          -*)
            # Interactive, login, restricted, and stdin modes can change lookup or execution.
            [[ $word =~ ^-[abefhkmnptuvxBCEHPTc]+$ ]] || return 2
            if [[ $word == *c* ]]; then (($#)) && doctor_hook_path "$1"; return; fi ;;
          *) set -- "$word" "$@"; break ;;
        esac
      done
      (($#)) && [[ -f $1 && -r $1 ]] || return 1 ;;
  esac
}

# These variables can change executable lookup or a nested shell's initialization.
doctor_static_environment() {
  case $1 in PATH|HOME|ENV|BASH_ENV|ZDOTDIR|SHELL) return 1 ;; esac
}

doctor_hook_path() {
  local command=$1 i rc=0
  local -a DOCTOR_WORDS=() DOCTOR_KINDS=() words=()
  bash -n <<<"$command" 2>/dev/null || return 1
  doctor_words "$command" || return $?
  for ((i=0; i<${#DOCTOR_WORDS[@]}; i++)); do
    if [[ ${DOCTOR_KINDS[i]} == operator ]]; then
      if ((${#words[@]})); then doctor_simple_hook "${words[@]}" || return $?; words=(); fi
    else words+=("${DOCTOR_WORDS[i]}"); fi
  done
  if ((${#words[@]})); then doctor_simple_hook "${words[@]}" || rc=$?; fi
  return "$rc"
}

doctor_hooks() {
  local file commands command rc fix
  for file in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
    rc=0
    fix="vi $(shell_join "$file") # correct hook paths; put dynamic shell code in an executable helper file"
    commands=$(jq -ec '[.hooks | objects | .. | objects | select(.type? == "command") | .command
      | if type == "string" and length > 0 and (explode | index(0) == null) then . else error("invalid hook command") end]
      | if length > 0 then . else error("no command hooks") end' "$file" 2>/dev/null) || rc=1
    doctor_result "$rc" "hook configuration $file" "$fix"
    [[ $rc == 0 ]] || continue
    while IFS= read -r -d '' command; do
      rc=0; doctor_hook_path "$command" || rc=$?
      if [[ $rc == 2 ]]; then doctor_result 1 "hook command needs a static helper: $command" "$fix" WARN
      else doctor_result "$rc" "hook command $command" "$fix"; fi
    done < <(jq -j '.[] | ., "\u0000"' <<<"$commands")
  done
}

doctor_mac() {
  local version='' raw='' methods='' method rc repair automation
  local installer="https://github.com/manaflow-ai/cmux/releases/download/v$WG_CMUX_SUPPORTED/cmux-macos.dmg"
  local warning='Quit cmux before running this command. It replaces /Applications/cmux.app with the verified release.'
  # shellcheck disable=SC2016  # The user runs this repair; the probe only prints it.
  printf -v repair 'd=$(mktemp -d) && curl -fL %s -o "$d/cmux.dmg" && hdiutil attach -nobrowse -mountpoint "$d/mount" "$d/cmux.dmg" && ditto "$d/mount/cmux.app" /Applications/cmux.app && hdiutil detach "$d/mount" && open -a cmux' "$installer"
  raw=$(cmux_call version 2>/dev/null) || raw=''
  if [[ $raw =~ ^cmux[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then version=${BASH_REMATCH[1]}; fi
  DOCTOR_CMUX_VERSION=$version
  rc=0; [[ $version == "$WG_CMUX_SUPPORTED" ]] || rc=1
  doctor_result "$rc" "cmux ${version:-unavailable}; verified $WG_CMUX_SUPPORTED. workgrove supports only the latest verified release; older and newer versions need verification." "$repair" WARN "$warning"

  methods=$(cmux_call capabilities 2>/dev/null) || methods=''
  for method in workspace.list workspace.create workspace.action workspace.close workspace.select \
      workspace.remote.reconnect notification.list notification.dismiss system.top surface.read_text; do
    rc=0
    jq -e --arg method "$method" '.methods | type == "array" and index($method) != null' <<<"$methods" >/dev/null 2>&1 || rc=1
    doctor_result "$rc" "cmux method $method" "$repair" FAIL "$warning"
  done
  rc=0; cmux_rows_load checked || rc=1
  doctor_result "$rc" 'cmux window and row JSON' "$repair" FAIL "$warning"
  DOCTOR_ROWS=${CMUX_ROWS_JSON:-}
  raw=$(cmux_call top --json 2>/dev/null) || raw=''
  DOCTOR_TOP=$raw
  rc=0
  doctor_json "$raw" 'type == "object" and (.caller | type == "object")
    and (.caller.workspace_id == null or (.caller.workspace_id | type == "string"))
    and (.coding_agents | type == "array" and all(.[];
      .resources.process_count | type == "number" and . >= 0))' || rc=1
  doctor_result "$rc" 'cmux top JSON' "$repair" FAIL "$warning"
  raw=$(cmux_notifications 2>/dev/null) || raw=''
  DOCTOR_NOTIFICATIONS=$raw
  rc=0
  doctor_json "$raw" 'type == "array" and all(.[]; (.id | type == "string" and length > 0)
    and (.workspace_id | type == "string" and length > 0)
    and (.title | type == "string") and (.body | type == "string"))' || rc=1
  doctor_result "$rc" 'cmux notification JSON' "$repair" FAIL "$warning"
  automation=$(cmux_call automation show wt-native-relay 2>/dev/null) || automation=''
  DOCTOR_AUTOMATION=$automation
  rc=0
  jq -e --slurpfile expected "$WG_VERSION_ROOT/home/.cmuxterm/automations.json" \
    '. == $expected[0].rules[0]' <<<"$automation" >/dev/null 2>&1 || rc=1
  doctor_result "$rc" 'wt-native-relay automation' 'wt update && cmux automation enable wt-native-relay && cmux automation reload'
  rc=0; [[ -x $HOME/.local/bin/cmux-hook ]] || rc=1
  doctor_result "$rc" 'automation hook file' 'wt update'
  doctor_hooks
}

doctor_vm() {
  local rc raw='' provider helper rest directory
  rc=0; command -v cmux-tui >/dev/null 2>&1 || rc=1
  doctor_result "$rc" 'cmux-tui CLI' 'cmux ssh <vm> # run on the Mac to install cmux-tui'
  raw=$(cmux-tui --json agent hook status claude codex 2>/dev/null) || raw=''
  for provider in claude codex; do
    rc=0
    jq -e --arg provider "$provider" '.errors == [] and (.providers | type == "array")
      and ([.providers[] | select(.provider == $provider)] | length == 1 and all(.[]; .state == "installed"))' \
      <<<"$raw" >/dev/null 2>&1 || rc=1
    doctor_result "$rc" "cmux-tui $provider hook" 'cmux-tui agent hook install claude codex'
  done
  helper=$(cmux_tui_agent_helper)
  rc=0; [[ -x $helper && -f $helper ]] || rc=1
  doctor_result "$rc" "cmux-tui hook helper $helper" 'unset CMUX_TUI_HOOK WT_CMUX_TUI_HOOK; cmux-tui agent hook install claude codex'
  raw=$(tmux -V 2>/dev/null) || raw=''
  rc=1
  if [[ $raw =~ ^tmux[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
    if ((10#${BASH_REMATCH[1]} > 3 || (10#${BASH_REMATCH[1]} == 3 && 10#${BASH_REMATCH[2]} >= 2))); then rc=0; fi
  fi
  doctor_result "$rc" "tmux 3.2 minimum (${raw:-unavailable})" 'sudo apt-get update && sudo apt-get install tmux'
  rc=0; [[ -n ${WT_HOST:-} ]] && valid_host "$WT_HOST" || rc=1
  doctor_result "$rc" 'WT_HOST' 'printf '\''export WT_HOST="<vm>"\n'\'' >> ~/.zshenv.local; source ~/.zshenv.local'
  rc=0; rest=${WT_REPOS_DIR:-}
  [[ -n $rest && $rest != :* && $rest != *: && $rest != *::* ]] || rc=1
  while [[ -n $rest ]]; do
    directory=${rest%%:*}
    [[ $directory == /* && -d $directory ]] || rc=1
    case $rest in *:*) rest=${rest#*:} ;; *) rest='' ;; esac
  done
  # shellcheck disable=SC2016  # The repair runs in the user's shell.
  doctor_result "$rc" 'WT_REPOS_DIR folders' 'printf '\''export WT_REPOS_DIR="$HOME/repos"\n'\'' >> ~/.zshenv.local; mkdir -p "$HOME/repos"; source ~/.zshenv.local'
}

cmd_contract_doctor() {
  local -A opts=()
  local DOCTOR_FAILED=0 DOCTOR_CMUX_VERSION='' DOCTOR_ROWS='' DOCTOR_TOP='' DOCTOR_NOTIFICATIONS='' DOCTOR_AUTOMATION=''
  local version rc=0
  wt_opts "$(wt_spec doctor)" opts "$@"
  if is_remote; then
    [[ ! -v opts[record] ]] || die 'doctor: --record runs on the Mac'
    doctor_vm
  else doctor_mac; fi
  version=$(wt_version | wt_read_version 2>/dev/null) || rc=1
  doctor_result "$rc" "wt version ${version:-unavailable}" 'wt update'
  if [[ -v opts[record] ]]; then doctor_record "${opts[record]}" || DOCTOR_FAILED=1; fi
  [[ $DOCTOR_FAILED == 0 ]]
}

host_contract_doctor() {
  local host=$1 version='' rc=0 failed=0 protocol='' output DOCTOR_FAILED=0
  printf 'VM checks for %s; run their repair commands on the VM.\n' "$host"
  # shellcheck disable=SC2016  # HOME belongs to the VM shell.
  output=$(remote_sh_raw "$host" 'exec "$HOME/.local/bin/wt" doctor' 2>&1) || failed=$?
  printf '%s\n' "$output"
  if [[ $failed == 255 ]]; then
    doctor_result 1 'VM doctor connection from the Mac' "ssh $(shell_join "$host")"
    return 1
  fi
  if [[ $failed == 0 ]] && ! grep -Eq '^(PASS|FAIL|WARN) cmux-tui CLI$' <<<"$output"; then
    failed=1
  fi
  if [[ $failed != 0 ]] && ! grep -Eq '^(FAIL|WARN) ' <<<"$output"; then
    doctor_result 1 'VM doctor unavailable' "wt -H $(shell_join "$host") update"
  fi
  printf 'Mac comparison:\n'
  version=$(host_version "$host" 2>/dev/null) || {
    doctor_result 1 'VM version connection from the Mac' "ssh $(shell_join "$host")"
    return 1
  }
  protocol=$(jq -r '.protocol' <<<"$version")
  [[ $protocol == "$WT_PROTOCOL" ]] || rc=1
  if [[ $protocol =~ ^[0-9]+$ ]] && ((protocol > WT_PROTOCOL)); then
    doctor_result "$rc" "VM protocol ${protocol:-unavailable}; Mac protocol $WT_PROTOCOL" 'wt update'
  else
    doctor_result "$rc" "VM protocol ${protocol:-unavailable}; Mac protocol $WT_PROTOCOL" "wt -H $(shell_join "$host") update"
  fi
  [[ $failed == 0 && $DOCTOR_FAILED == 0 ]]
}

# JSON and root options retain the portable readiness interface. Bare doctor checks the cmux contract.
doctor_dispatch() {
  local context=$1 host=$2 mode=contract
  shift 2
  local -A opts=()
  local args=()
  wt_opts "$(wt_spec doctor "$context")" opts "$@"
  if [[ -v opts[environment] || -v opts[root] || -v opts[json] ]]; then
    [[ ! -v opts[record] ]] || die 'doctor: --record cannot be combined with portable readiness options'
    mode=environment
  else
    need_jq
  fi
  wt_opt_args opts args environment
  if [[ $context == remote ]]; then
    "host_${mode}_doctor" "$host" "${args[@]}"
  else
    "cmd_${mode}_doctor" "${args[@]}"
  fi
}

cmd_doctor() { doctor_dispatch local '' "$@"; }
host_doctor() { local host=$1; shift; doctor_dispatch remote "$host" "$@"; }

# Raw responses stay in shell variables. Only sanitized JSON reaches the destination.
doctor_record() {
  local base=$1 windows event raw bundle dir rc=0 file window rows rows_by_window='{}'
  local -a window_ids=()
  if [[ -z $base || ! $DOCTOR_CMUX_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    doctor_result 1 'fixture destination or cmux version unavailable' 'wt doctor --record test/fixtures'
    return 1
  fi
  dir=$base/cmux-$DOCTOR_CMUX_VERSION
  windows=$(cmux_call --json list-windows 2>/dev/null) || rc=1
  if [[ $rc == 0 ]]; then
    mapfile -t window_ids < <(jq -r '.[].id' <<<"$windows")
    for window in "${window_ids[@]}"; do
      rows=$(cmux_call workspace list --json --window "$window" 2>/dev/null) || { rc=1; break; }
      rows_by_window=$(printf '%s\n' "$rows_by_window" "$rows" | jq -sc --arg window "$window" \
        '.[0] + {($window):.[1]}') || { rc=1; break; }
    done
  fi
  event=$(cmux_call events --after 0 --name notification.created --limit 1 --timeout 3 --no-ack --no-heartbeat 2>/dev/null) || rc=1
  raw=$(cmux_call capabilities 2>/dev/null) || rc=1
  bundle=$(printf '%s\n' "$DOCTOR_ROWS" "$windows" "$DOCTOR_NOTIFICATIONS" "$DOCTOR_TOP" \
    "$DOCTOR_AUTOMATION" "$raw" "$event" "$rows_by_window" | jq -s '
      if length == 8 then
        {rows:.[0],windows:.[1],notifications:.[2],top:.[3],automation:.[4],capabilities:.[5],event:.[6],rows_by_window:.[7]}
      else error("incomplete cmux capture") end' 2>/dev/null) || rc=1
  if [[ $rc == 0 ]]; then
    doctor_json "$event" '.name == "notification.created" and (.workspace_id | type == "string")
      and (.payload.notification_id | type == "string")' || rc=1
  fi
  if [[ $rc == 0 ]]; then
    bundle=$(jq -f "$WG_LIB_DIR/doctor-sanitize.jq" <<<"$bundle") || rc=1
  fi
  if [[ $rc != 0 ]]; then
    doctor_result 1 'fixture capture; a retained notification.created event is required' 'wt doctor --record test/fixtures # retry after an agent notification'
    return 1
  fi
  if mkdir -p "$dir"; then
    for file in rows windows notifications top automation capabilities event rows_by_window; do
      jq ".$file" <<<"$bundle" >"$dir/$file.json" || rc=1
    done
    printf 'cmux %s\n' "$DOCTOR_CMUX_VERSION" >"$dir/version.txt" || rc=1
    printf 'Redacted cmux contract responses. All free text and identities use placeholders.\n' >"$dir/REDACTED.txt" || rc=1
  else rc=1; fi
  doctor_result "$rc" "redacted fixtures $dir" "mkdir -p $(shell_join "$base"); wt doctor --record $(shell_join "$base")"
  return "$rc"
}
