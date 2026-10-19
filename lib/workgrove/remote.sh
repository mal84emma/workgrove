# shellcheck shell=bash
# Reads globals: CMUX_ROW_EXISTING, HOME, WG_LIB_DIR.
# Requires cmux.sh: check_row_removal, close_row, cmux_ok, cmux_row_field, cmux_row_open_ssh.
# Requires common.sh: die, hook_safe_path, row_title, shell_join, tmux_cmd, usage, valid_name, warn,
#   wt_read_result, wt_session.
# Requires task.sh: cmux_require, need_model, open_code, row_tag, tmux_agent, valid_agent.
# ---------------------------------------------------------------- wt -H <host> …
remote_sh_raw() { # keep SSH's exit status intact for callers that must tell a refusal from a dropped connection
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" "$2"
}
remote_sh() { # remote_sh <host> <command> — one ssh call; 255 means transport failure
  local host="$1" cmd="$2" rc=0
  remote_sh_raw "$host" "$cmd" || rc=$?
  if [[ $rc -eq 255 ]]; then die "host unreachable: is the VM running? (ssh $host)"; fi
  return $rc
}
remote_wt() { local host="$1"; shift; remote_sh "$host" "exec \"\$HOME/.local/bin/wt\" $(shell_join "$@")"; }
remote_wt_result() { local host="$1"; shift; remote_sh "$host" "WT_MACHINE=1 exec \"\$HOME/.local/bin/wt\" $(shell_join "$@")"; }
remote_wt_result_raw() { local host="$1"; shift; remote_sh_raw "$host" "WT_MACHINE=1 exec \"\$HOME/.local/bin/wt\" $(shell_join "$@")"; }
remote_sh_tty() { # remote_sh_tty <host> <command> — remote_sh, but lends the VM this terminal when there is one,
                  # so a command that asks before it acts (wt update) can read the answer. Never use it for a
                  # caller that captures stdout: a pty folds stderr into stdout and turns every \n into \r\n.
                  # Without a local terminal there is nothing to lend, and the VM's own refusal is correct.
  local host="$1" cmd="$2" rc=0 tty=()
  [[ -t 0 ]] && tty=(-t)                                   # -t works with BatchMode=yes, which only blocks prompts
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${tty[@]}" "$host" "$cmd" || rc=$?
  if [[ $rc -eq 255 ]]; then die "host unreachable: is the VM running? (ssh $host)"; fi
  return $rc
}
remote_wt_tty() { local host="$1"; shift; remote_sh_tty "$host" "exec \"\$HOME/.local/bin/wt\" $(shell_join "$@")"; }
remote_run_cmd() {
  # shellcheck disable=SC2016  # $HOME belongs to the VM shell, not this Mac
  printf '"$HOME/.local/bin/wt" run %s -r %s' "$1" "$(shell_join "$2")"
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

host_new_preflight() { # read-only checks in the same non-interactive SSH environment as remote_wt
  remote_sh "$1" "sh -s -- $(shell_join "$2" "$3")" <"$WG_LIB_DIR/vm/host-new-preflight.sh"
}

host_new() { # create the worktree on the VM, then the cmux row here unless --no-workspace
  local host="$1" prompt="" repo_request="" requested_agent="" inspect="" no_workspace=0 args=(); shift
  # Consume both ways of giving a brief HERE, and relay them the same way. A forwarded --prompt-stdin would
  # read nothing locally and pipe an empty prompt into ssh. The VM would then create the task with no brief.
  local -A opts=()
  local spec
  spec=$(wt_spec new)
  spec=${spec/'--prompt-stdin|stdin_prompt|=1'/'--prompt-stdin|prompt|@stdin'}
  wt_opts "$spec" opts "$@"
  prompt=${opts[prompt]-$prompt}
  repo_request=${opts[repo]-$repo_request}
  requested_agent=${opts[agent]-$requested_agent}
  [[ ! -v opts[agent] ]] || valid_agent "$requested_agent"
  [[ ${opts[workspace]:-1} == 1 ]] || no_workspace=1
  wt_opt_args opts args prompt workspace
  if [[ $no_workspace -eq 0 ]]; then
    cmux_ok || die "cmux is not running; start cmux before creating a task on $host"
  fi
  host_new_preflight "$host" "$repo_request" "$requested_agent"
  inspect="wt -H $host list"
  [[ -z "$repo_request" ]] || inspect+=" -r $(shell_join "$repo_request")"
  local out name repo session rc result result_rc=0
  if out=$(printf '%s' "$prompt" | remote_wt_result_raw "$host" new --no-workspace --prompt-stdin "${args[@]}" 2>&1); then
    :
  else
    rc=$?
    [[ -z "$out" ]] || printf '%s\n' "$out" >&2
    if [[ "$out" == *'new: unknown option -m'* || "$out" == *'new: unknown option --model'* ]]; then
      warn "$host has an older wt without -m; update it with: wt -H $host update"
    fi
    if [[ $rc -eq 255 ]]; then
      warn "SSH disconnected during creation on $host; could not confirm whether a worktree was created; inspect with: $inspect"
      warn "a disconnected create may still be finishing; recheck before starting the same task elsewhere"
    fi
    return "$rc"
  fi
  printf '%s\n' "$out"
  result=$(wt_read_result "$out" new) || result_rc=$?
  case $result_rc in
    0)
      [[ $(jq -r .status <<<"$result") == created ]] || die "unexpected output from $host; the worktree may exist; inspect with: $inspect before retrying"
      name=$(jq -r .name <<<"$result"); repo=$(jq -r .repo <<<"$result"); session=$(jq -r .session <<<"$result") ;;
    2)
      name=$(printf '%s\n' "$out" | sed -n 's/^created //p' | head -1)
      repo=$(printf '%s\n' "$out" | sed -n 's/^ *repo: *//p' | head -1)
      session=$(printf '%s\n' "$out" | sed -n 's/^ *session: *//p' | head -1) ;;
    *) die "unexpected output from $host; the worktree may exist; inspect with: $inspect before retrying" ;;
  esac
  [[ -n "$name" && -n "$repo" && -n "$session" ]] || die "$host did not report created/repo/session; the worktree may exist; inspect with: $inspect before retrying"
  valid_name "$name" && [[ "$session" == "$(wt_session "$name" "$repo")" ]] || die "unexpected output from $host; the worktree may exist; inspect with: $inspect before retrying"
  if [[ $no_workspace -eq 1 ]]; then
    printf 'start later: wt -H %s attach -r %s %s\n' "$host" "$(shell_join "$repo")" "$(shell_join "$name")"
    return 0
  fi
  if [[ -n "$(cmux_row_field "$(row_title "$name")" "$repo" id "$host")" ]]; then
    warn "the worktree was created on $host, but a row for this task is already open; do not run new again"
    warn "close the stale row in cmux, then recover with: wt -H $host attach --restart-agent -r $(shell_join "$repo") $(shell_join "$name")"
    return 1
  fi
  if ! (remote_row "$host" "$session" "$(row_title "$name")" "$repo" "$(remote_run_cmd "$name" "$repo")" --no-focus); then
    warn "the worktree was created on $host; do not run new again"
    warn "inspect: wt -H $host show -r $(shell_join "$repo") $(shell_join "$name")"
    warn "if an agent is running: wt -H $host attach -r $(shell_join "$repo") $(shell_join "$name")"
    warn "if no agent pane exists: wt -H $host attach --restart-agent -r $(shell_join "$repo") $(shell_join "$name")"
    return 1
  fi
}

agent_on_vm() { # agent_on_vm <host> <session> — use the Mac's checked probe, even with an older wt on the VM.
  local script
  # shellcheck disable=SC2016  # $1 belongs to the remote Bash command.
  script="$(declare -f tmux_agent)"$'\n''tmux_agent "$1"'
  remote_sh "$1" "bash -c $(shell_join "$script" wt "$2")" >/dev/null
}

host_open() { # VS Code Remote-SSH on a VM worktree
  local host="$1" name="" repo=""; shift
  local -A opts=()
  wt_opts "$(wt_spec open)" opts "$@"
  name=${opts[name]-$name}
  repo=${opts[repo]-$repo}
  need_r "$host" open "$@"
  [[ -n "$name" ]] || die "open: worktree name required (wt -H $host open -r <repo> <name>)"
  local p; p=$(remote_wt "$host" path "$name" -r "$repo")
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
  remote_sh "$host" "exec tmux kill-session -t $(shell_join "=$session")" >/dev/null 2>&1 || true
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

host_update() { remote_wt_tty "$1" update "${@:2}"; }
