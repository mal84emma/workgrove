# shellcheck shell=bash
# Reads globals: CMUX_ROW_EXISTING, HOME, WG_LIB_DIR.
# Requires cmux.sh: check_row_removal, close_row, cmux_ok, cmux_row_field, cmux_row_open_ssh.
# Requires common.sh: die, hook_safe_path, host_recovery_hint, row_title, shell_join, tmux_cmd, usage, vm_result, vm_run_line,
#   vm_ssh, vm_tmux, vm_wt, warn, wt_session, wt_version.
# Requires version.sh: wt_read_version.
# Requires options.sh: wt_opt_args, wt_opts, wt_spec.
# Requires task.sh: cmux_require, need_model, open_code, row_tag, tmux_agent, valid_agent.
# ---------------------------------------------------------------- wt -H <host> …
remote_sh_raw() { vm_ssh "$1" "$2"; }
remote_sh() {
  local rc=0
  remote_sh_raw "$@" || rc=$?
  [[ $rc != 255 ]] || die "host unreachable: is the VM running? (ssh $1)"
  return "$rc"
}
remote_wt() {
  local rc=0
  vm_wt "$@" || rc=$?
  [[ $rc != 255 ]] || die "host unreachable: is the VM running? (ssh $1)"
  return "$rc"
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
"$wg_python" -B - doctor --preflight <<'WG_PREFLIGHT_SOURCE'
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
  if ! remote_sh "$1" "sh -s -- $(shell_join "$2" "$3")" < <(host_preflight_source); then
    warn "$(host_recovery_hint "$1")"
    return 1
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
  [[ -z $err ]] || printf '%s\n' "$err" >&2
  if [[ $rc != 0 ]]; then
    [[ -z "$out" ]] || printf '%s\n' "$out" >&2
    if [[ $rc -eq 255 ]]; then
      warn "SSH disconnected during creation on $host; could not confirm whether a worktree was created; inspect with: $inspect"
      warn "a disconnected create may still be finishing; recheck before starting the same task elsewhere"
    fi
    return "$rc"
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
  case $result_rc in
    0) [[ ${result[status]} == created ]] || die "unexpected output from $host; the worktree may exist; inspect with: $inspect before retrying" ;;
    2) die "$host did not report created/repo/session; the worktree may exist; inspect with: $inspect before retrying" ;;
    3) die "unsupported result protocol from $host; run wt update on the Mac; the worktree may exist; inspect with: $inspect before retrying" ;;
    *) die "unexpected output from $host; the worktree may exist; inspect with: $inspect before retrying" ;;
  esac
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

# WT_COMPAT: Remove when every VM uses the current agent probe.
agent_on_vm() { # agent_on_vm <host> <session> — use the Mac's checked probe, even with an older wt on the VM.
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
  [[ $rc != 255 ]] || die "host unreachable: is the VM running? (ssh $host)"
  if [[ $rc != 0 ]]; then
    [[ -z $out ]] || printf '%s\n' "$out" >&2
    return "$rc"
  fi
  [[ $result_rc != 3 ]] || die "unsupported result protocol from $host; run wt update on the Mac"
  [[ $result_rc == 0 && ${result[status]} == found ]] || die "unexpected output from $host"
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
    0) die "another agent is running in tmux session $session on $host; kept the worktree" ;;
    1) ;;
    *) die "cannot check the agent in tmux session $session on $host; kept the worktree" ;;
  esac
  remote_wt "$host" rm "${args[@]}"
  cmux_require close_row "$(cmux_row_field "$title" "$repo" id "$host")"
  vm_tmux "$host" kill-session "$session" >/dev/null 2>&1 || true
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
    '$version + {event:"wt_update",stage:$stage,side:$side}'
}

host_version() {
  local output rc=0
  output=$(vm_wt "$1" version) || rc=$?
  [[ $rc != 255 ]] || { warn "host unreachable: is the VM running? (ssh $1)"; return 1; }
  if [[ $rc == 0 ]] && output=$(wt_read_version <<<"$output" 2>/dev/null); then
    printf '%s\n' "$output"
  else
    # WT_COMPAT: Remove the unsupported-command fallback when every VM supports wt version.
    printf '{"commit":null,"protocol":null}\n'
  fi
}

host_update() {
  local host=$1 version
  version=$(host_version "$host") || return $?
  wt_update_record before Mac "$(wt_version)"
  wt_update_record before VM "$version"
  local rc=0
  vm_wt "$host" --tty update "${@:2}" || rc=$?
  [[ $rc != 255 ]] || die "host unreachable: is the VM running? (ssh $host)"
  [[ $rc == 0 ]] || return "$rc"
  version=$(host_version "$host") || version='{"commit":null,"protocol":null}'
  if ! jq -e '.commit != null and .protocol != null' <<<"$version" >/dev/null; then
    warn "update on $host succeeded; could not read its version (ssh $host)"
  fi
  wt_update_record after Mac "$(wt_version)"
  wt_update_record after VM "$version"
}
