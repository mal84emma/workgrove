# shellcheck shell=bash
row_remote_field() { # row_remote_field <id> <field>… — this row's current remote fields (state, daemon slot) from one
                     # rows_json read, joined by $WT_FS. Never a tab: read would collapse it when a field is empty.
  local id="$1"; shift
  rows_json | jq -r --arg id "$id" --arg fs "$WT_FS" \
    'first((.workspaces? // .)[] | select(.id == $id) | .remote as $r
       | [$ARGS.positional[] as $k | ($r[$k] // "") | tostring] | join($fs)) // empty' --args "$@" 2>/dev/null || true
}

clear_stale_relay() { # clear_stale_relay <host> <slot> — signal only this user's sshd, and only when its session is
                      # not from the Mac's current address; the last line on stdout is `stopped <port> <pid>` or `free <port>`
  remote_sh_raw "$1" "bash -s -- $(shell_join "$2")" <"$WG_LIB_DIR/vm/clear-stale-relay.sh"
}

recover_suspended_row() { # reconnect one suspended row, after freeing only its own stale SSH forward
  local host="$1" id="$2" slot="$3" fallback="$4" c out rc=0 reason result reply body state tick port left=0
  local why="did not connect within 30 seconds"
  [[ -n "$slot" ]] || { warn "suspended row $id has no persistent daemon slot"; die "manual fallback: $fallback"; }
  # The relay script writes every refusal to its stderr. A VM's login files may print before its result.
  out=$(clear_stale_relay "$host" "$slot" 2>&1) || rc=$?
  [[ $rc -ne 255 ]] || die "host unreachable: is the VM running? (ssh $host)"
  if printf '%s\n' "$out" | grep -x 'keepalive missing' >/dev/null; then   # no -q: pipefail and SIGPIPE
    warn "$host's sshd has no ClientAliveInterval, so a stale SSH session holds its relay port until TCP keepalive gives up; apply docs/new-vm.md block 1's keepalive lines"
  fi
  if [[ $rc -ne 0 ]]; then   # the script's reason is its last line
    reason=$(printf '%s\n' "$out" | grep -vx 'keepalive missing' | sed '/^[[:space:]]*$/d' | tail -1 || true)
    warn "could not clear $id's stale relay on $host: ${reason:-no reason given}"; die "manual fallback: $fallback"
  fi
  result=$(printf '%s\n' "$out" | grep -E '^(stopped|free) ' | tail -1 || true)
  case "$result" in
    stopped\ *) port=${result#stopped }; port=${port%% *}
                printf 'relay: stopped stale user sshd %s on %s port %s\n' "${result##* }" "$host" "$port" ;;
    free\ *) printf 'relay: port %s on %s was free\n' "${result#free }" "$host" ;;
    *) warn "unexpected relay check: $out"; die "manual fallback: $fallback" ;;
  esac
  c=$(cmux_bin); body=$(jq -cn --arg id "$id" '{workspace_id: $id}')
  rc=0; reply=$(CMUX_QUIET=1 "$c" rpc workspace.remote.reconnect "$body" 2>&1) || rc=$?
  reply=${reply//$'\n'/ }   # kept for every failure message below
  [[ $rc -eq 0 ]] || die "cmux reconnect failed for $id (${reply:-no reply}); manual fallback: $fallback"
  for ((tick=0; tick<30; tick++)); do
    state=$(row_remote_field "$id" state)
    if [[ "$state" == connected ]]; then printf 'row: %s connected after reconnect\n' "$id"; return 0; fi
    # The first reads may still say suspended. Suspended again after any other state means cmux gave up.
    if [[ "$state" == suspended && $left -eq 1 ]]; then why="went back to suspended after cmux tried to reconnect it"; break; fi
    [[ -z "$state" || "$state" == suspended ]] || left=1
    sleep 1
  done
  die "row $id $why (last state: ${state:-missing}; cmux reconnect reply: ${reply:-empty}); manual fallback: $fallback"
}

ROW_SHELL_LAST=""
row_shell_prompt() { # row_shell_prompt <id> — 0 when the row's last non-blank line ends in $, # or % and names a
                     # user@host, or is that character alone under a line that does (a two-line theme such as
                     # workgrove's). A TUI footer such as `Context 100%` names none. 2: the screen is unavailable.
                     # ROW_SHELL_LAST holds that last line
  local id="$1" c screen lines above="" nl=$'\n' who='[[:alnum:]_.-]+@[[:alnum:]_.-]+' end='[$#%]$' bare='^[$#%]$'
  ROW_SHELL_LAST=""
  c=$(cmux_bin) || return 2
  screen=$(CMUX_QUIET=1 "$c" read-screen --workspace "$id" 2>/dev/null) || return 2
  lines=$(printf '%s\n' "$screen" | sed -e 's/[[:space:]]*$//' -e '/^$/d' | tail -2)
  ROW_SHELL_LAST=${lines##*"$nl"}
  [[ "$lines" != *"$nl"* ]] || above=${lines%%"$nl"*}
  [[ "$ROW_SHELL_LAST" =~ $end ]] || return 1
  [[ "$ROW_SHELL_LAST" =~ $who ]] || { [[ "$ROW_SHELL_LAST" =~ $bare && "$above" =~ $who ]]; }
}

send_tmux_line() { # send_tmux_line <id> <session> — type the row's tmux attach line into it and press return
  local c; c=$(cmux_bin)
  CMUX_QUIET=1 "$c" send --workspace "$1" "$(tmux_cmd "$2")" >/dev/null 2>&1 \
    || die "cmux send failed for $1; type this in the row instead: tmux attach -d -t '=$2'"
  CMUX_QUIET=1 "$c" send-key --workspace "$1" enter >/dev/null 2>&1 \
    || die "cmux send-key failed for $1; press return in the row to finish the attach"
}

vm_session_detached() { # vm_session_detached <host> <session> — 0 only when the VM has that tmux session and lists no
                        # client on it. One ssh call; any failure, ssh's own included, counts as "not proven"
  local q; q=$(shell_join "=$2")
  remote_sh_raw "$1" "tmux has-session -t $q 2>/dev/null && c=\$(tmux list-clients -t $q 2>/dev/null) && [ -z \"\$c\" ]" >/dev/null 2>&1
}

reattach_shell_row() { # reattach_shell_row <id> <session> [host] — send the tmux line only to a row at a shell prompt.
                       # With a host (after a reconnect), the row must also still be connected, and that VM must list
                       # no client on the session. The checks run in that order, immediately before the send
  local id="$1" session="$2" host="${3:-}"
  row_shell_prompt "$id" || return 1
  if [[ -n "$host" ]]; then   # the connection can drop again, and a restored pty can still hold tmux
    [[ "$(row_remote_field "$id" state)" == connected ]] || return 1
    vm_session_detached "$host" "$session" || return 1
  fi
  send_tmux_line "$id" "$session"
}

reattach_recovered_row() { # reattach_recovered_row <host> <id> <session> — a reconnected row can say connected before its
                           # new login shell paints a prompt, so try for 5 ticks ~1 s apart. Each tick reads the screen
                           # first (local) and asks the VM only when that shows a prompt. 1: never proven, nothing sent
  local tick
  for ((tick=0; tick<5; tick++)); do
    reattach_shell_row "$2" "$3" "$1" && return 0
    [[ $tick -eq 4 ]] || sleep 1
  done
  return 1
}

reinit_task_client() { # reinit_task_client <host> <id> <session> — restart this task row's attached tmux client
  local host="$1" id="$2" session="$3" line screen_rc=0 nonce proof screen c
  [[ "$(row_remote_field "$id" state)" == connected ]] || return 2
  row_shell_prompt "$id" || screen_rc=$?
  [[ $screen_rc -eq 1 ]] || return 2   # skip a shell or an unreadable screen
  line=$(tmux_cmd "$session" "" "" reinit)
  nonce="WT_REINIT_${RANDOM}_${RANDOM}_$$_$(date +%s)"
  # A restored row may show a cached agent screen while its old client is on an abandoned pty.
  # A fresh tmux status message proves that this row shows that client's output. It sends no pane input.
  proof=$(remote_sh_raw "$host" "bash -s -- $(shell_join "=$session" "$nonce")" <"$WG_LIB_DIR/vm/reinit-client-proof.sh" 2>/dev/null) || return $?
  proof=${proof##*$'\n'}
  [[ "$proof" =~ ^[0-9]+[[:space:]]+/dev/pts/[0-9]+$ ]] || return 2
  c=$(cmux_bin) || return 1
  screen=$(CMUX_QUIET=1 "$c" read-screen --workspace "$id" 2>/dev/null) || return 2
  [[ "$screen" == *"$nonce"* && "$(row_remote_field "$id" state)" == connected ]] || return 2
  # -E replaces the client process on its own pty. A fresh attach sends every terminal mode again.
  # If that attach fails, the row's shell gets its prompt back. Recheck the client after the screen proof.
  remote_sh_raw "$host" "bash -s -- $(shell_join "=$session" "$proof" "$line")" <"$WG_LIB_DIR/vm/reinit-client-detach.sh" >/dev/null 2>&1 || return 1
  # The row can reconnect again between the screen proof and the replacement. Confirm the new client
  # is visible there before reporting that its terminal modes were restored.
  nonce="WT_REINIT_${RANDOM}_${RANDOM}_$$_$(date +%s)"
  remote_sh_raw "$host" "bash -s -- $(shell_join "=$session" "${proof#* }" "$nonce")" <"$WG_LIB_DIR/vm/reinit-client-confirm.sh" >/dev/null 2>&1 || return 1
  screen=$(CMUX_QUIET=1 "$c" read-screen --workspace "$id" 2>/dev/null) || return 1
  [[ "$screen" == *"$nonce"* && "$(row_remote_field "$id" state)" == connected ]] || return 1
}

host_attach() { # re-attach to the VM's session; start an agent only for a task never started before
  local host="$1" restart=0 reattach=0 name="" repo=""; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --restart-agent) restart=1; shift ;;
      --reattach) reattach=1; shift ;;
      -r|--repo) [[ $# -ge 2 ]] || die "attach: $1 needs a repo"; repo="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "attach: unknown option $1" ;;
      *) [[ -z "$name" ]] || die "attach: unexpected argument $1"; name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || die "attach: worktree name required (wt -H $host attach -r <repo> <name>)"
  if [[ $restart -eq 1 && $reattach -eq 1 ]]; then die "attach: --reattach and --restart-agent do opposite things; pick one"; fi
  local out session state title id path c remote remote_state slot fallback recovered=0 what=selected result result_rc=0
  out=$(remote_wt_result "$host" show "$name" -r "$repo")
  result=$(wt_read_result "$out" show) || result_rc=$?
  case $result_rc in
    0)
      [[ $(jq -r .status <<<"$result") == found && $(jq -r .name <<<"$result") == "$name" ]] || die "unexpected output from $host"
      session=$(jq -r .session <<<"$result"); path=$(jq -r .repo <<<"$result"); state=$(jq -r .state <<<"$result") ;;
    2)
      session=$(printf '%s\n' "$out" | sed -n 's/^ *session: *//p' | head -1)
      path=$(printf '%s\n' "$out" | sed -n 's/^ *repo: *//p' | head -1)
      state="${session#*(}"; state="${state%)}"; session="${session%% *}" ;;
    *) die "unexpected output from $host" ;;
  esac
  [[ -n "$session" && -n "$path" ]] || die "$host reported no session for $name (try: wt -H $host show $name -r $(shell_join "$repo"))"
  valid_name "$name" && [[ "$session" == "$(wt_session "$name" "$path")" ]] || die "unexpected output from $host"
  title=$(row_title "$name")
  id=$(cmux_row_field "$title" "$path" id "$host")
  if [[ -n "$id" && $restart -eq 0 ]]; then
    remote=$(row_remote_field "$id" state persistent_daemon_slot)
    IFS="$WT_FS" read -r remote_state slot <<<"$remote"
    if [[ "$remote_state" == suspended ]]; then
      fallback="once $host has dropped the old SSH session (about a minute with docs/new-vm.md block 1's keepalive), press Reconnect on the row or re-run: wt -H $host attach -r $(shell_join "$repo") $name"
      recover_suspended_row "$host" "$id" "$slot" "$fallback"
      recovered=1
    fi
  fi
  if [[ $reattach -eq 1 ]]; then  # A dropped connection can leave the row with a fresh login shell while the VM
                                  # keeps the pty that holds tmux. The abandoned client is then still listed, and
                                  # session_state cannot call the session detached. The flag is the user's word
                                  # that the row shows a shell. The screen check is the backstop: it stops the
                                  # tmux line from going into a running agent's prompt. A row that reconnected
                                  # a moment ago may still show its pre-suspension screen, and its restored pty
                                  # may still hold tmux. The user cannot have seen that, so the row gets
                                  # reattach_recovered_row's proof.
    [[ -n "$id" ]] || die "no row $title $(row_tag "$host" "$path") is open; wt -H $host attach -r $(shell_join "$repo") $name opens one"
    c=$(cmux_bin)
    if [[ $recovered -eq 1 ]]; then
      if ! reattach_recovered_row "$host" "$id" "$session"; then
        CMUX_QUIET=1 "$c" workspace select "$id" >/dev/null 2>&1 || die "cmux workspace select failed for $id"
        die "$title $(row_tag "$host" "$path") reconnected, but its shell prompt and a detached VM session were not both confirmed (last line: ${ROW_SHELL_LAST:-empty}); look at the row and, if it shows a bare shell, re-run: wt -H $host attach --reattach -r $(shell_join "$repo") $name"
      fi
    else
      reattach_shell_row "$id" "$session" \
        || die "$title $(row_tag "$host" "$path") does not end at a shell prompt naming user@host, on its own line or the one above (last line: ${ROW_SHELL_LAST:-empty}); it is probably still attached to tmux, or its prompt names no user@host. Select the row and look, then re-run, or attach by hand there: tmux attach -d -t '=$session'"
    fi
    CMUX_QUIET=1 "$c" workspace select "$id" >/dev/null 2>&1 || die "cmux workspace select failed for $id"
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
    remote_sh "$host" "exec tmux kill-session -t $(shell_join "=$session")" >/dev/null 2>&1 || true
    close_row "$(cmux_row_field "$title" "$path" id "$host")"
    for _ in 1 2 3; do                     # remote_row creates a row only when no row is left, so wait for that
      [[ -n "$(cmux_row_field "$title" "$path" id "$host")" ]] || break
      sleep 1
    done
    [[ -z "$(cmux_row_field "$title" "$path" id "$host")" ]] \
      || die "row $(row_label "$title" "$path" "$host") is still open; close it in cmux, then re-run: wt -H $host attach --restart-agent -r $(shell_join "$repo") $name"
    remote_row "$host" "$session" "$title" "$path" "$(remote_run_cmd "$name" "$path")" --no-focus
    return 0
  fi
  if [[ "$state" == none && -z "$id" ]]; then
    # No tmux session and no started marker means that this task has never run. Restarting a lost agent
    # must stay a deliberate choice.
    if remote_sh "$host" "test ! -e $(shell_join "$path/.git/wt/$name.started") && ! tmux has-session -t $(shell_join "=$session") 2>/dev/null"; then
      remote_row "$host" "$session" "$title" "$path" "$(remote_run_cmd "$name" "$path")" --no-focus
      return 0
    fi
  fi
  case "$state" in
    "agent running"|"agent running, detached") ;;
    *) die "$name on $host has no agent pane ($state); restart it: wt -H $host attach --restart-agent -r $(shell_join "$repo") $name; if an agent is visibly running there, the VM's wt is older than the Mac's: wt -H $host update" ;;
  esac
  [[ -n "$id" ]] || { remote_row "$host" "$session" "$title" "$path" ""; return 0; }
  c=$(cmux_bin)
  if [[ $recovered -eq 1 ]]; then
    # The show above ran before the reconnect. A prompt-shaped footer alone says nothing about what holds
    # the pty. So wait for a prompt, and ask the VM again immediately before any send.
    if reattach_recovered_row "$host" "$id" "$session"; then what=re-attached; fi
  elif [[ "$state" == *detached ]]; then   # show may be stale; prove the prompt and detached session again
    if reattach_shell_row "$id" "$session" "$host"; then what=re-attached
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
  CMUX_QUIET=1 "$c" workspace select "$id" >/dev/null 2>&1 || die "cmux workspace select failed for $id"
  printf 'row: %s %s (%s)\n' "$title" "$(row_tag "$host" "$path")" "$what"
  if [[ "$what" == re-initialized ]]; then
    printf 'if the replacement attach fails, the row returns to its shell prompt; recover with: wt -H %s attach --reattach -r %s %s\n' "$host" "$(shell_join "$repo")" "$name"
  fi
  if [[ $recovered -eq 1 && "$what" == selected ]]; then
    warn "re-attach this row if it shows a bare shell: wt -H $host attach --reattach -r $(shell_join "$repo") $name"
  fi
}
