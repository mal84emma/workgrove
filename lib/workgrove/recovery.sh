# shellcheck shell=bash
# Reads globals: RANDOM, WG_LIB_DIR.
# Requires cmux.sh: close_row, cmux_row_field, cmux_screen, cmux_select, row_label,
#   row_remote_field, row_shell_prompt, send_tmux_line.
# Requires common.sh: die, row_title, shell_join, tmux_cmd, usage, vm_result, vm_run_line,
#   vm_tmux, warn, wg_sleep.
# Requires options.sh: wt_opts, wt_spec.
# Requires remote.sh: agent_on_vm, remote_row, remote_sh, remote_sh_raw.
# Requires task.sh: cmux_require, row_tag.

vm_session_detached() { # vm_session_detached <host> <session> — 0 only when the VM has that tmux session and lists no
                        # client on it. One ssh call; any failure, ssh's own included, counts as "not proven"
  vm_tmux "$1" detached "$2" >/dev/null 2>&1
}

reattach_shell_row() { # reattach_shell_row <id> <session> <last line output> [host]
  # Send the tmux line only to a row at a shell prompt.
  # With a host after a reconnect, require a connected row and no client on the VM session.
  # Check these conditions in that order, immediately before the send.
  local __id="$1" __session="$2" __host="${4:-}"
  row_shell_prompt "$__id" "$3" || return 1
  if [[ -n "$__host" ]]; then   # the connection can drop again, and a restored pty can still hold tmux
    [[ "$(row_remote_field "$__id" state)" == connected ]] || return 1
    vm_session_detached "$__host" "$__session" || return 1
  fi
  cmux_require send_tmux_line "$__id" "$__session"
}

reinit_task_client() { # reinit_task_client <host> <id> <session> — restart this task row's attached tmux client
  local host="$1" id="$2" session="$3" line screen_rc=0 nonce proof screen _last
  [[ "$(row_remote_field "$id" state)" == connected ]] || return 2
  row_shell_prompt "$id" _last || screen_rc=$?
  [[ $screen_rc -eq 1 ]] || return 2   # skip a shell or an unreadable screen
  line=$(tmux_cmd "$session" "" "" reinit)
  nonce="WT_REINIT_${RANDOM}_${RANDOM}_$$_$(date +%s)"
  # A restored row may show a cached agent screen while its old client is on an abandoned pty.
  # A fresh tmux status message proves that this row shows that client's output. It sends no pane input.
  proof=$(remote_sh_raw "$host" "bash -s -- $(shell_join "=$session" "$nonce")" <"$WG_LIB_DIR/vm/reinit-client-proof.sh" 2>/dev/null) || return $?
  proof=${proof##*$'\n'}
  [[ "$proof" =~ ^[0-9]+[[:space:]]+/dev/pts/[0-9]+$ ]] || return 2
  screen=$(cmux_screen "$id" 2>/dev/null) || return 2
  [[ "$screen" == *"$nonce"* && "$(row_remote_field "$id" state)" == connected ]] || return 2
  # -E replaces the client process on its own pty. A fresh attach sends every terminal mode again.
  # If that attach fails, the row's shell gets its prompt back. Recheck the client after the screen proof.
  remote_sh_raw "$host" "bash -s -- $(shell_join "=$session" "$proof" "$line")" <"$WG_LIB_DIR/vm/reinit-client-detach.sh" >/dev/null 2>&1 || return 1
  # The row can reconnect again between the screen proof and the replacement. Confirm the new client
  # is visible there before reporting that its terminal modes were restored.
  nonce="WT_REINIT_${RANDOM}_${RANDOM}_$$_$(date +%s)"
  remote_sh_raw "$host" "bash -s -- $(shell_join "=$session" "${proof#* }" "$nonce")" <"$WG_LIB_DIR/vm/reinit-client-confirm.sh" >/dev/null 2>&1 || return 1
  screen=$(cmux_screen "$id" 2>/dev/null) || return 1
  [[ "$screen" == *"$nonce"* && "$(row_remote_field "$id" state)" == connected ]] || return 1
}

host_attach() { # re-attach to the VM's session; start an agent only for a task never started before
  local host="$1" restart=0 reattach=0 name="" repo=""; shift
  local -A opts=()
  wt_opts "$(wt_spec attach remote)" opts "$@"
  name=${opts[name]-$name}
  restart=${opts[restart]-$restart}
  reattach=${opts[reattach]-$reattach}
  repo=${opts[repo]-$repo}
  need_r "$host" attach "$@"
  [[ -n "$name" ]] || die "attach: worktree name required (wt -H $host attach -r <repo> <name>)"
  if [[ $restart -eq 1 && $reattach -eq 1 ]]; then die "attach: --reattach and --restart-agent do opposite things; pick one"; fi
  local out session state title id path what=selected rc result_rc=0 agent attached started
  local -A result=()
  vm_result "$host" show result out rc -- "$name" -r "$repo" || result_rc=$?
  [[ $rc != 255 ]] || die "host unreachable: is the VM running? (ssh $host)"
  if [[ $rc != 0 ]]; then
    [[ -z $out ]] || printf '%s\n' "$out" >&2
    return "$rc"
  fi
  case $result_rc in
    0) [[ ${result[status]} == found ]] || die "unexpected output from $host" ;;
    2) die "$host reported no session for $name (try: wt -H $host show $name -r $(shell_join "$repo"))" ;;
    3) die "unsupported result protocol from $host; run wt update on the Mac" ;;
    *) die "unexpected output from $host" ;;
  esac
  session=${result[session]} path=${result[repo]} state=${result[state]-}
  agent=${result[agent]-} attached=${result[attached]-} started=${result[started]-}
  # WT_COMPAT: Keep wording checks for VMs that omit the boolean fields.
  if [[ -z $agent ]]; then
    agent=false
    case $state in "agent running"|"agent running, detached") agent=true ;; esac
  fi
  if [[ -z $attached ]]; then
    attached=true
    [[ $state != *detached && $state != none ]] || attached=false
  fi
  title=$(row_title "$name")
  id=$(cmux_row_field "$title" "$path" id "$host" checked) || die "cannot list cmux rows; not creating a row on a lookup that failed"
  if [[ $reattach -eq 1 ]]; then
    # The flag confirms that the user sees a shell, even if the VM still lists its abandoned client.
    # Check the screen before sending the tmux line, so an agent prompt cannot receive it.
    [[ -n "$id" ]] || die "no row $title $(row_tag "$host" "$path") is open; wt -H $host attach -r $(shell_join "$repo") $name opens one"
    local shell_last
    reattach_shell_row "$id" "$session" shell_last \
      || die "$title $(row_tag "$host" "$path") does not end at a shell prompt naming user@host, on its own line or the one above (last line: ${shell_last:-empty}); it is probably still attached to tmux, or its prompt names no user@host. Select the row and look, then re-run, or attach by hand there: tmux attach -d -t '=$session'"
    cmux_require cmux_select "$id"
    printf 'row: %s %s (re-attached)\n' "$title" "$(row_tag "$host" "$path")"
    return 0
  fi
  if [[ $restart -eq 1 ]]; then
    local agent_rc=0
    agent_on_vm "$host" "$session" || agent_rc=$?
    case $agent_rc in
      0) die "$name on $host still has an agent running; wt -H $host attach -r $(shell_join "$repo") $name re-attaches it, or wt -H $host update if the VM's wt is older than the Mac's" ;;
      1) ;;
      *) die "cannot check the agent in tmux session $session on $host; kept the session" ;;
    esac
    vm_tmux "$host" kill-session "$session" >/dev/null 2>&1 || true
    cmux_require close_row "$(cmux_row_field "$title" "$path" id "$host")"
    for _ in 1 2 3; do                     # remote_row creates a row only when no row is left, so wait for that
      [[ -n "$(cmux_row_field "$title" "$path" id "$host")" ]] || break
      wg_sleep
    done
    [[ -z "$(cmux_row_field "$title" "$path" id "$host")" ]] \
      || die "row $(row_label "$title" "$path" "$host") is still open; close it in cmux, then re-run: wt -H $host attach --restart-agent -r $(shell_join "$repo") $name"
    remote_row "$host" "$session" "$title" "$path" "$(vm_run_line "$name" "$path")" --no-focus
    return 0
  fi
  if [[ $agent == false && $attached == false && -z $id ]]; then
    local never_started=1 session_rc=0
    if [[ -n $started ]]; then
      if [[ $started == false ]]; then
        vm_tmux "$host" has-session "$session" >/dev/null 2>&1 || session_rc=$?
        [[ $session_rc != 1 ]] || never_started=0
      fi
    # WT_COMPAT: Older VMs do not report whether the task has started.
    elif [[ $state == none ]]; then
      remote_sh "$host" "sh -s -- $(shell_join "$path" "$name" "$session")" <<'WT_STARTED' && never_started=0
test ! -e "$1/.git/wt/$2.started" && ! tmux has-session -t "=$3" 2>/dev/null
WT_STARTED
    fi
    if [[ $never_started == 0 ]]; then
      remote_row "$host" "$session" "$title" "$path" "$(vm_run_line "$name" "$path")" --no-focus
      return 0
    fi
  fi
  [[ $agent == true ]] || die "$name on $host has no agent pane ($state); restart it: wt -H $host attach --restart-agent -r $(shell_join "$repo") $name; if an agent is visibly running there, the VM's wt is older than the Mac's: wt -H $host update"
  [[ -n "$id" ]] || { remote_row "$host" "$session" "$title" "$path" ""; return 0; }
  local _last
  if [[ $attached == false ]]; then   # show may be stale; prove the prompt and detached session again
    if reattach_shell_row "$id" "$session" _last "$host"; then what=re-attached
    else warn "did not re-attach $title $(row_tag "$host" "$path"); inspect the row, then use: wt -H $host attach --reattach -r $(shell_join "$repo") $name"
    fi
  fi
  if [[ "$what" == selected ]]; then   # a detached report can be stale by the time the row is checked
    local reinit_rc=0
    reinit_task_client "$host" "$id" "$session" || reinit_rc=$?
    if [[ $reinit_rc -eq 0 ]]; then what=re-initialized
    elif [[ $reinit_rc -eq 2 ]]; then warn "could not confirm $session's client in this row; inspect it, then re-run attach if its terminal settings are missing; for a bare shell use: wt -H $host attach --reattach -r $(shell_join "$repo") $name"
    else warn "could not confirm $session's replacement client on $host; inspect the row, then re-run attach; for a bare shell use: wt -H $host attach --reattach -r $(shell_join "$repo") $name"
    fi
  fi
  cmux_require cmux_select "$id"
  printf 'row: %s %s (%s)\n' "$title" "$(row_tag "$host" "$path")" "$what"
  if [[ "$what" == re-initialized ]]; then
    printf 'if the replacement attach fails, the row returns to its shell prompt; recover with: wt -H %s attach --reattach -r %s %s\n' "$host" "$(shell_join "$repo")" "$name"
  fi
}
