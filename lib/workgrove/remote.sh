# shellcheck shell=bash
# Reads globals: CMUX_ROW_EXISTING, HOME, WG_LIB_DIR, WT_PROTOCOL.
# ---------------------------------------------------------------- wt -H <host> …
remote_sh_raw() { vm_ssh "$1" "$2"; }
remote_sh() {
  local rc=0
  remote_sh_raw "$@" || rc=$?
  vm_wt_failure "$1" raw "$rc" "" 0
}
remote_wt() {
  local rc=0
  vm_wt "$@" || rc=$?
  vm_wt_failure "$1" raw "$rc" "" 0
}

remote_row() { # remote_row <host> <session> <title> <repo> <command> [shared] [cmux flags…]
  local host=$1 session=$2 title=$3 repo=$4 cmd=$5 shared='' line; shift 5
  if [[ ${1:-} == shared ]]; then shared=shared; shift; fi
  cmux_ok || die "cmux is not running; start cmux, then re-run this command"
  line=$(tmux_cmd "$session" "$cmd" "$shared")
  cmux_require cmux_row_open_ssh "$host" "$title" "$(row_tag "$host" "$repo")" "$line" "$@"
  printf 'row: %s %s%s\n' "$title" "$(row_tag "$host" "$repo")" "${CMUX_ROW_EXISTING:+ (already open)}"
}

need_r() { # need_r <host> <sub> <args…> — a remote call has no cwd to infer the repo from, so -r is required.
  local host="$1" sub="$2"; shift 2
  local -A opts=()
  wt_opts "$(wt_spec "$sub" remote)" opts "$@"
  [[ ! -v opts[repo] ]] || return 0
  die "$sub: -r <repo> is required with -H (wt -H $host repos lists them)"
}

# Normalize every repository value before forwarding or using it as a row identity.
wt_remote_args() {
  local __host=$1 __sub=$2 __output=$3 __i __value
  shift 3
  local -A __parsed=()
  wt_opts "$(wt_spec "$__sub" remote)" __parsed "$@"
  for ((__i=0; __i<${__parsed[@count]}; __i++)); do
    [[ ${__parsed[@key:$__i]} == repo ]] || continue
    __value=${__parsed[@value:$__i]}
    while [[ $__value == */ && $__value != / ]]; do __value=${__value%/}; done
    case "$__value" in
      /*) ;;
      ""|.|..|*/*) die "$__sub: -r must be an absolute path on $__host, or a repo name there (wt -H $__host repos lists them)" ;;
    esac
    __parsed[@value:$__i]=$__value
  done
  wt_opt_args __parsed "$__output"
}

host_preflight_source() {
  cat "$WG_LIB_DIR/version.sh" "$WG_LIB_DIR/vm/python-runtime.sh"
  cat <<'WG_PREFLIGHT_HEADER'
wg_portable_preflight() {
if wg_select_python; then
wg_run_python - doctor --preflight <<'WG_PREFLIGHT_SOURCE'
WG_PREFLIGHT_HEADER
  cat "$WG_LIB_DIR/portable.py"
  cat <<'WG_PREFLIGHT_END'
WG_PREFLIGHT_SOURCE
elif wg_has_portable_profile; then
  printf 'workgrove: %s\n' "$wg_python_issue" >&2
  return 1
else return 0; fi
}
WG_PREFLIGHT_END
  cat "$WG_LIB_DIR/vm/host-new-preflight.sh"
}

host_new_preflight() { # read-only checks in the same non-interactive SSH environment as remote_wt
  local version protocol=null output_file rc=0
  output_file=$(mktemp "${TMPDIR:-/tmp}/wt-new-preflight.XXXXXX") || return 1
  wt_register_tmpfile "$output_file"
  remote_sh "$1" "sh -s -- $(shell_join "$2" "$3")" < <(host_preflight_source) >"$output_file" || rc=$?
  version=$(cat "$output_file")
  rm -f "$output_file"
  if [[ $rc != 0 ]]; then
    [[ -z $version ]] || printf '%s\n' "$version" >&2
    warn "$(host_recovery_hint "$1")"
    return 1
  fi
  if version=$(wt_read_version <<<"$version" 2>/dev/null); then
    protocol=$(jq -r '.protocol' <<<"$version")
  fi
  if [[ $protocol != "$WT_PROTOCOL" ]]; then
    warn "$(host_protocol_message "$protocol"); run $(host_protocol_repair "$1" "$protocol")"
  fi
}

host_protocol_message() {
  printf 'VM protocol %s; Mac protocol %s' "${1:-unavailable}" "$WT_PROTOCOL"
}

host_protocol_repair() {
  if [[ $2 =~ ^[0-9]+$ ]] && (($2 > WT_PROTOCOL)); then
    printf 'wt update'
  else
    printf 'wt -H %s update' "$(shell_join "$1")"
  fi
}

host_new() { # create the worktree on the VM, then the cmux row here unless --no-workspace
  local host="$1" prompt="" repo_request="" requested_agent="" inspect="" no_workspace=0 args=(); shift
  # Consume both ways of giving a brief HERE, and relay them the same way. A forwarded --prompt-stdin would
  # read nothing locally and pipe an empty prompt into ssh. The VM would then create the task with no brief.
  local -A opts=()
  wt_opts "$(wt_spec new remote)" opts "$@"
  local i
  for ((i=0; i<${opts[@count]}; i++)); do
    case ${opts[@key:$i]} in
      prompt) prompt=${opts[@value:$i]} ;;
      stdin_prompt) IFS= read -r -d '' prompt || true ;;
    esac
  done
  repo_request=${opts[repo]-$repo_request}
  requested_agent=${opts[agent]-$requested_agent}
  [[ ! -v opts[agent] ]] || valid_agent "$requested_agent"
  [[ ${opts[workspace]:-1} == 1 ]] || no_workspace=1
  wt_opt_args opts args prompt stdin_prompt workspace
  if [[ $no_workspace -eq 0 ]]; then
    cmux_ok || die "cmux is not running; start cmux before creating a task on $host"
  fi
  host_new_preflight "$host" "$repo_request" "$requested_agent"
  inspect="wt -H $host list"
  [[ -z "$repo_request" ]] || inspect+=" -r $(shell_join "$repo_request")"
  local out err name repo session rc result_rc=0
  local -A result=()
  vm_result "$host" new result out err rc -- --no-workspace --prompt-stdin "${args[@]}" < <(printf '%s' "$prompt") || result_rc=$?
  if [[ $rc != 0 && $err == *'cleanup remains pending for '* && -n ${opts[name]-} && -n $repo_request ]]; then
    rows_json checked >/dev/null || return 1
    if [[ -z $(cmux_row_field "$(row_title "${opts[name]}")" "$repo_request" id "$host" checked) ]] && \
        remote_wt "$host" rm "${opts[name]}" -r "$repo_request" --observe-only --row-closed >/dev/null; then
      result_rc=0
      vm_result "$host" new result out err rc -- --no-workspace --prompt-stdin "${args[@]}" < <(printf '%s' "$prompt") || result_rc=$?
    fi
  fi
  [[ -z $err ]] || printf '%s\n' "$err" >&2
  if [[ $rc != 0 ]]; then
    [[ -z "$out" ]] || printf '%s\n' "$out" >&2
  fi
  if [[ $rc == 0 && -n $out ]]; then printf '%s\n' "$out"; fi
  vm_wt_failure "$host" new "$rc" "$inspect" "$result_rc" "${result[status]-}" || return $?
  name=${result[name]} repo=${result[repo]} session=${result[session]}
  if [[ $no_workspace -eq 1 ]]; then
    printf 'start later: wt -H %s attach -r %s %s\n' "$host" "$(shell_join "$repo")" "$(shell_join "$name")"
    return 0
  fi
  if [[ -n "$(cmux_row_field "$(row_title "$name")" "$repo" id "$host")" ]]; then
    warn "the worktree was created on $host, but a row for this task is already open; do not run new again"
    warn "close the stale row in cmux, then recover with: wt -H $host attach --restart-agent -r $(shell_join "$repo") $(shell_join "$name")"
    return 1
  fi
  if ! (remote_row "$host" "$session" "$(row_title "$name")" "$repo" "$(vm_run_line "$name" "$repo")" --no-focus); then
    warn "the worktree was created on $host; do not run new again"
    warn "inspect: wt -H $host show -r $(shell_join "$repo") $(shell_join "$name")"
    warn "if an agent is running: wt -H $host attach -r $(shell_join "$repo") $(shell_join "$name")"
    warn "if no agent pane exists: wt -H $host attach --restart-agent -r $(shell_join "$repo") $(shell_join "$name")"
    return 1
  fi
}

agent_on_vm() { # agent_on_vm <host> <session> — use the Mac's checked probe before removal or restart.
  local script
  # shellcheck disable=SC2016  # $1 belongs to the remote Bash command.
  script="$(declare -f tmux_agent)"$'\n''tmux_agent "$1"'
  remote_sh "$1" "bash -s -- $(shell_join "$2")" <<<"$script" >/dev/null
}

host_open() { # VS Code Remote-SSH on a VM worktree
  local host="$1" name="" repo=""; shift
  local -A opts=()
  wt_opts "$(wt_spec open)" opts "$@"
  name=${opts[name]-$name}
  repo=${opts[repo]-$repo}
  need_r "$host" open "$@"
  [[ -n "$name" ]] || die "open: worktree name required (wt -H $host open -r <repo> <name>)"
  local p out err rc result_rc=0
  local -A result=()
  vm_result "$host" path result out err rc -- "$name" -r "$repo" || result_rc=$?
  [[ -z $err ]] || printf '%s\n' "$err" >&2
  if [[ $rc != 0 && $rc != 255 && -n $out ]]; then printf '%s\n' "$out" >&2; fi
  vm_wt_failure "$host" path "$rc" "" "$result_rc" "${result[status]-}" || return $?
  p=${result[path]}
  hook_safe_path "$p" || die "open: refusing an unsafe path from $host ($p)"
  open_code "vscode-remote://ssh-remote+$host$p/" "$host:$p"
}

host_rm() { # remove on the VM, close the row, then kill the session (closing first stops cmux recreating it)
  local host="$1" name="" repo="" args=(); shift
  local -A opts=()
  wt_opts "$(wt_spec rm)" opts "$@"
  name=${opts[name]-$name}
  repo=${opts[repo]-$repo}
  need_r "$host" rm "$@"
  wt_opt_args opts args
  [[ -n "$name" ]] || die "rm: worktree name required (wt -H $host rm -r <repo> <name>)"
  # The row's identity comes from -r. cmd_host has already refused -r unless it is an absolute path or
  # a plain repo name. A relative '.' or '..' would make repo_id '-', and close_row would close nothing.
  local session title; session=$(wt_session "$name" "$repo"); title=$(row_title "$name")
  local _row _self
  cmux_require check_row_removal "$title" "$repo" _row _self "$host"
  local agent_rc=0
  agent_on_vm "$host" "$session" || agent_rc=$?
  case $agent_rc in
    0) : ;;
    1) ;;
    *) die "cannot check the agent in tmux session $session on $host; kept the worktree" ;;
  esac
  if [[ ${opts[observe_only]:-0} == 1 ]]; then
    [[ -z $_row ]] || die 'VM row is still present; observation did not close it'
    remote_wt "$host" rm "${args[@]}" --row-closed
    return
  fi
  remote_wt "$host" rm "${args[@]}" --defer-close || return $?
  # shellcheck disable=SC2034  # The checked helper also returns caller ownership.
  local checked_row='' checked_self='' rows
  cmux_require check_row_removal "$title" "$repo" checked_row checked_self "$host"
  [[ $checked_row == "$_row" ]] || die 'VM row identity changed; cleanup remains pending'
  cmux_require close_row "$checked_row"
  rows=$(rows_json checked) || die 'cannot confirm VM row absence'
  if [[ -n $checked_row ]] && jq -e --arg id "$checked_row" 'any(.workspaces[]; .id == $id)' <<<"$rows" >/dev/null; then
    die 'VM row remains open; session cleanup is pending'
  fi
  remote_wt "$host" rm "${args[@]}" --row-closed
}

host_list() {
  local host=$1; shift
  local -A opts=()
  wt_opts "$(wt_spec list)" opts "$@"
  if [[ -v opts[repo] ]]; then remote_wt "$host" list "$@"
  else remote_wt "$host" list --all "$@"; fi
}

host_repos() {
  local host=$1; shift
  local -A opts=()
  wt_opts "$(wt_spec repos)" opts "$@"
  if [[ -t 1 && ! -v opts[mode] ]]; then set -- --table "$@"; fi
  remote_wt "$host" repos "$@"
}

wt_update_record() {
  jq -cn --arg stage "$1" --arg side "$2" --argjson version "$3" \
    '$version | {commit,protocol} + {event:"wt_update",stage:$stage,side:$side}'
}

host_version() {
  local output rc=0
  output=$(vm_wt "$1" version) || rc=$?
  vm_wt_failure "$1" version "$rc" "" 0 || return $?
  [[ $rc == 0 ]] || return "$rc"
  output=$(wt_read_version <<<"$output" 2>/dev/null) || {
    warn "invalid version report from $1; run wt -H $(shell_join "$1") update"
    return 1
  }
  printf '%s\n' "$output"
}

host_update() {
  local host=$1 version
  version=$(host_version "$host") || return $?
  wt_update_record before Mac "$(wt_version)"
  wt_update_record before VM "$version"
  local rc=0
  vm_wt "$host" --tty update "${@:2}" || rc=$?
  vm_wt_failure "$host" raw "$rc" "" 0 || return $?
  version=$(host_version "$host") || version='{"commit":null,"protocol":null}'
  if ! jq -e '.commit != null and .protocol != null' <<<"$version" >/dev/null; then
    warn "update on $host succeeded; could not read its version (ssh $host)"
  fi
  wt_update_record after Mac "$(wt_version)"
  wt_update_record after VM "$version"
}
