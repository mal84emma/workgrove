# shellcheck shell=bash
# Reads globals: WG_LIB_DIR, WG_VERSION_ROOT, WG_CMUX_SUPPORTED, WT_PROTOCOL, HOME, WT_HOST, WT_REPOS_DIR.
# Requires common.sh, task.sh, cmux.sh, options.sh, and remote.sh from bin/wt.

# Keep checking after a failure so one run reports every repair.
doctor_result() {
  if [[ $1 == 0 ]]; then printf 'PASS %s\n' "$2"
  else
    printf '%s %s\n  Fix: %s\n' "${4:-FAIL}" "$2" "$3"
    DOCTOR_FAILED=1
  fi
}

doctor_json() {
  jq -e "$2" <<<"$1" >/dev/null 2>&1
}

# Split shell words without evaluating hook commands or command substitutions.
doctor_words() {
  local text=$1 char quote='' word='' active=0 escape=0 depth=0 i
  DOCTOR_WORDS=()
  for ((i=0; i<${#text}; i++)); do
    char=${text:i:1}
    if [[ $escape == 1 ]]; then word+=$char; active=1; escape=0; continue; fi
    # Keep a command substitution inside its assignment word without running it.
    if [[ ${text:i:2} == \$\( && $quote != "'" ]]; then
      depth=$((depth + 1)); word+="\$("; active=1; i=$((i + 1)); continue
    fi
    if ((depth > 0)); then
      word+=$char
      case $char in '(') depth=$((depth + 1)) ;; ')') depth=$((depth - 1)) ;; esac
      continue
    fi
    case $char in
      \\) if [[ $quote != "'" ]]; then escape=1; else word+=$char; fi ;;
      \"|\')
        if [[ -z $quote ]]; then quote=$char
        elif [[ $quote == "$char" ]]; then quote=''
        else word+=$char; fi
        active=1 ;;
      ' '|$'\t'|$'\n'|';'|'&'|'|')
        if [[ -n $quote ]]; then word+=$char
        elif [[ $active == 1 ]]; then DOCTOR_WORDS+=("$word"); word=''; active=0; fi ;;
      *) word+=$char; active=1 ;;
    esac
  done
  [[ -z $quote && $escape == 0 && $depth == 0 ]] || return 1
  [[ $active == 0 ]] || DOCTOR_WORDS+=("$word")
}

doctor_hook_path() {
  local command=$1 word path index=0
  local -a DOCTOR_WORDS=()
  doctor_words "$command" || return 1
  bash -n <<<"$command" 2>/dev/null || return 1
  for word in "${DOCTOR_WORDS[@]}"; do
    index=$((index + 1))
    [[ $word != env && ! $word =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    path=${word/#\~\//$HOME/}
    path=${path//\$\{HOME\}/$HOME}
    path=${path//\$HOME/$HOME}
    if [[ $path != */* ]]; then path=$(type -P -- "$path") || return 1; fi
    [[ -f $path && -x $path ]] || return 1
    # Check a script argument as well when a shell starts the hook.
    case ${path##*/} in
      sh|bash|zsh)
        word=${DOCTOR_WORDS[index]:-}
        if [[ $word == -*c* ]]; then
          word=${DOCTOR_WORDS[index+1]:-}
          [[ -n $word ]] && doctor_hook_path "$word"
          return
        fi
        while [[ $word == -* ]]; do index=$((index + 1)); word=${DOCTOR_WORDS[index]:-}; done
        [[ -n $word ]] || return 1
        path=${word/#\~\//$HOME/}
        path=${path//\$\{HOME\}/$HOME}
        path=${path//\$HOME/$HOME}
        [[ -f $path ]] || return 1 ;;
    esac
    return 0
  done
  return 1
}

doctor_hooks() {
  local file commands command rc fix
  fix='wt update --refresh-config && cmux hooks codex install --yes'
  for file in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
    rc=0
    commands=$(jq -er '[.hooks | objects | .. | objects | select(.type? == "command") | .command
      | if type == "string" and length > 0 then . else error("invalid hook command") end]
      | if length > 0 then .[] else error("no command hooks") end' "$file" 2>/dev/null) || rc=1
    doctor_result "$rc" "hook configuration $file" "$fix"
    [[ $rc == 0 ]] || continue
    while IFS= read -r command; do
      rc=0; doctor_hook_path "$command" || rc=1
      doctor_result "$rc" "hook command $command" "$fix"
    done <<<"$commands"
  done
}

doctor_mac() {
  local version='' raw='' methods='' method rc repair automation
  repair='brew reinstall --cask cmux'
  raw=$(cmux_call version 2>/dev/null) || raw=''
  if [[ $raw =~ ^cmux[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then version=${BASH_REMATCH[1]}; fi
  DOCTOR_CMUX_VERSION=$version
  rc=0; [[ $version == "$WG_CMUX_SUPPORTED" ]] || rc=1
  doctor_result "$rc" "cmux ${version:-unavailable}; verified $WG_CMUX_SUPPORTED. workgrove supports only the latest verified release; older and newer versions need verification." "$repair" WARN

  methods=$(cmux_call capabilities 2>/dev/null) || methods=''
  for method in workspace.list workspace.create workspace.action workspace.close workspace.select \
      workspace.remote.reconnect notification.list notification.dismiss system.top surface.read_text; do
    rc=0
    jq -e --arg method "$method" '.methods | type == "array" and index($method) != null' <<<"$methods" >/dev/null 2>&1 || rc=1
    doctor_result "$rc" "cmux method $method" "$repair"
  done
  rc=0; cmux_rows_load checked || rc=1
  doctor_result "$rc" 'cmux window and row JSON' "$repair"
  DOCTOR_ROWS=${CMUX_ROWS_JSON:-}
  raw=$(cmux_call top --json 2>/dev/null) || raw=''
  DOCTOR_TOP=$raw
  rc=0
  doctor_json "$raw" 'type == "object" and (.caller | type == "object")
    and (.caller.workspace_id == null or (.caller.workspace_id | type == "string"))
    and (.coding_agents | type == "array" and all(.[];
      .resources.process_count | type == "number" and . >= 0))' || rc=1
  doctor_result "$rc" 'cmux top JSON' "$repair"
  raw=$(cmux_notifications 2>/dev/null) || raw=''
  DOCTOR_NOTIFICATIONS=$raw
  rc=0
  doctor_json "$raw" 'type == "array" and all(.[]; (.id | type == "string" and length > 0)
    and (.workspace_id | type == "string" and length > 0)
    and (.title | type == "string") and (.body | type == "string"))' || rc=1
  doctor_result "$rc" 'cmux notification JSON' "$repair"
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
  raw=$(cmux-tui agent hook status claude codex 2>/dev/null) || raw=''
  for provider in claude codex; do
    rc=0
    grep -Eiq "^[[:space:]]*${provider}[[:space:]:]+installed([[:space:]]|$)" <<<"$raw" || rc=1
    doctor_result "$rc" "cmux-tui $provider hook" 'cmux-tui agent hook install claude codex'
  done
  helper=${WT_CMUX_TUI_HOOK:-${CMUX_TUI_HOOK:-}}
  case $helper in ''|*/lib/workgrove/cmux-tui-hook.sh) helper=${XDG_DATA_HOME:-$HOME/.local/share}/cmux-tui/bin/cmux-tui-hook ;; esac
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

cmd_doctor() {
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

host_doctor() {
  local host=$1 version='' rc=0 failed=0 protocol='' output DOCTOR_FAILED=0
  printf 'VM checks for %s; run their repair commands on the VM.\n' "$host"
  output=$(remote_wt "$host" doctor 2>&1) || failed=$?
  printf '%s\n' "$output"
  if [[ $failed != 0 ]] && ! grep -Eq '^(FAIL|WARN) ' <<<"$output"; then
    if [[ $failed == 255 ]]; then
      doctor_result 1 'VM doctor connection' "ssh $(shell_join "$host")"
    else
      doctor_result 1 'VM doctor unavailable' "wt -H $(shell_join "$host") update"
    fi
  fi
  printf 'Mac comparison:\n'
  version=$(host_version "$host" 2>/dev/null) || rc=1
  if [[ $rc == 0 ]]; then
    protocol=$(jq -r '.protocol' <<<"$version")
    [[ $protocol == "$WT_PROTOCOL" ]] || rc=1
  fi
  if [[ $protocol =~ ^[0-9]+$ ]] && ((protocol > WT_PROTOCOL)); then
    doctor_result "$rc" "VM protocol ${protocol:-unavailable}; Mac protocol $WT_PROTOCOL" 'wt update'
  else
    doctor_result "$rc" "VM protocol ${protocol:-unavailable}; Mac protocol $WT_PROTOCOL" "wt -H $(shell_join "$host") update"
  fi
  [[ $failed == 0 && $DOCTOR_FAILED == 0 ]]
}

# Raw responses stay in shell variables. Only sanitized JSON reaches the destination.
doctor_record() {
  local base=$1 windows event raw bundle dir rc=0 file
  if [[ -z $base || ! $DOCTOR_CMUX_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    doctor_result 1 'fixture destination or cmux version unavailable' 'wt doctor --record test/fixtures'
    return 1
  fi
  dir=$base/cmux-$DOCTOR_CMUX_VERSION
  windows=$(cmux_call --json list-windows 2>/dev/null) || rc=1
  event=$(cmux_call events --after 0 --name notification.created --limit 1 --timeout 3 --no-ack --no-heartbeat 2>/dev/null) || rc=1
  raw=$(cmux_call capabilities 2>/dev/null) || rc=1
  bundle=$(printf '%s\n' "$DOCTOR_ROWS" "$windows" "$DOCTOR_NOTIFICATIONS" "$DOCTOR_TOP" \
    "$DOCTOR_AUTOMATION" "$raw" "$event" | jq -s '
      if length == 7 then
        {rows:.[0],windows:.[1],notifications:.[2],top:.[3],automation:.[4],capabilities:.[5],event:.[6]}
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
    for file in rows windows notifications top automation capabilities event; do
      jq ".$file" <<<"$bundle" >"$dir/$file.json" || rc=1
    done
    printf 'cmux %s\n' "$DOCTOR_CMUX_VERSION" >"$dir/version.txt" || rc=1
    printf 'Redacted cmux contract responses. All free text and identities use placeholders.\n' >"$dir/REDACTED.txt" || rc=1
  else rc=1; fi
  doctor_result "$rc" "redacted fixtures $dir" "mkdir -p $(shell_join "$base"); wt doctor --record $(shell_join "$base")"
  return "$rc"
}
