# shellcheck shell=bash
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
# shellcheck disable=SC2016   # $HOME must reach the VM unexpanded
status_bridge_ready() {
  [[ -f $HOME/.local/bin/cmux-hook ]] && grep -qF 'CMUX_NOTIFICATION_SUBTITLE' "$HOME/.local/bin/cmux-hook" &&
    jq -e 'any(.notifications.hooks[]?; .id == "wt" and .command == "~/.local/bin/cmux-hook")' \
      "$HOME/.config/cmux/cmux.json" >/dev/null 2>&1
}
remote_run_cmd() {
  status_bridge_ready && printf 'WT_STATUS_BRIDGE=1 '
  # shellcheck disable=SC2016  # $HOME belongs to the VM shell, not this Mac
  printf '"$HOME/.local/bin/wt" run %s -r %s' "$1" "$(shell_join "$2")"
}

row_ids() { # row_ids — one row id per line, from the full row list. It fails when any window's list fails,
            # because then new_row would take an older row that the partial list left out for a new one.
  local rows; rows=$(rows_json checked) || return 1
  printf '%s' "$rows" | jq -r '.workspaces[] | .id'
}

tag_row() { # tag_row <workspace ref or ""> <title> <repo> <host> [row ids before the create, or "-"] — write the description
  # A 5th argument marks a row that the caller has just created. "-" means that the list before the create
  # was unreadable.
  # A new row has no description yet, so a lookup by repo cannot find it. So when the create printed no ref,
  # take the row that new_row in ROW_JQ names. That needs the full list from before the create. Without it,
  # an older row with this title and no repo, such as the user's own `cmux ssh` row, would look new.
  # A task row's description holds the repo, so it is part of the row's identity. If it cannot be written on
  # a new task row, no later lookup finds that row, and the next attach builds a second row beside it. So
  # close that row and fail. A row with no repo (a shell row) is found by its title and host, so it stays.
  local ref="$1" tag; tag=$(row_tag "$4" "$3")
  [[ -n "$ref" || "${5:-}" != - ]] \
    || die "cmux printed no ref for the new row '$2' on $4, and the row list from before the create was unreadable; close that row in cmux"
  for _ in 1 2 3; do                    # no workspace:N in the output: the row list lags ~1s behind a create
    [[ -n "$ref" ]] && break
    sleep 1
    ref=$(rows_json | jq -r --arg t "$2" --arg h "$4" --arg before "${5:-}" --arg sep "$ROW_SEP" "$ROW_JQ"'
      first((.workspaces? // .)[] | select(new_row($t; $h; $before | split("\n"); $sep)) | .id // empty) // empty' \
      2>/dev/null || true)
  done
  [[ -n "$ref" ]] || die "cmux reported no row '$2' on $4; if cmux shows a new row '$2' with no repo on its second line, close it"
  CMUX_QUIET=1 "$(cmux_bin)" workspace-action --workspace "$ref" --action set-description --description "$tag" >/dev/null 2>&1 \
    && return 0
  [[ $# -ge 5 && -n "$3" ]] || die "cmux workspace-action failed; run: cmux workspace-action --workspace $ref --action set-description --description '$tag'"
  close_row "$ref" new || die "cmux could not write '$tag' on the new row $2, and wt could not close that row; close it in cmux"
  die "cmux could not write '$tag' on the new row $2, so wt closed that row"
}

remote_row() { # remote_row <host> <session> <title> <repo> <command> [shared] [cmux flags…] — the local ssh row
               # for a VM tmux session. <repo> is "" for a row with no repo. One row per title, repo and host.
               # A row that is already there is re-tagged and (unless --no-focus) selected. It is never typed
               # into, because its pane may hold a running agent whose prompt would swallow the tmux line.
               # Only host_attach's detached branch sends.
  local host="$1" session="$2" title="$3" repo="$4" cmd="$5" shared="" c id line out before; shift 5
  if [[ "${1:-}" == shared ]]; then shared=shared; shift; fi
  cmux_ok || die "cmux is not running; start cmux, then re-run this command"
  c=$(cmux_bin)
  id=$(cmux_row_field "$title" "$repo" id "$host")
  if [[ -n "$id" ]]; then
    tag_row "$id" "$title" "$repo" "$host"
    case " $* " in
      *" --no-focus "*) ;;
      *) CMUX_QUIET=1 "$c" workspace select "$id" >/dev/null 2>&1 || die "cmux workspace select failed for $id" ;;
    esac
    printf 'row: %s %s (already open)\n' "$title" "$(row_tag "$host" "$repo")"
    return 0
  fi
  before=$(row_ids) || before=-          # "-" tells tag_row that it cannot know which row is new
  line=$(tmux_cmd "$session" "$cmd" "$shared")
  out=$(CMUX_QUIET=1 "$c" ssh "$host" --name "$title" "$@" --command "$line" 2>&1) || die "cmux ssh failed: $out"
  tag_row "$(printf '%s' "$out" | grep -oE 'workspace:[0-9]+' | head -1 || true)" "$title" "$repo" "$host" "$before"
  printf 'row: %s %s\n' "$title" "$(row_tag "$host" "$repo")"
}

need_r() { # need_r <host> <sub> <args…> — a remote call has no cwd to infer the repo from, so -r is required.
  # This tests presence only. cmd_host has already normalized the value and refused an empty, relative,
  # '.' or '..' one. So nothing is left here that a command would have rejected for itself.
  # -h wins over the requirement. A question about what a command takes must get an answer, not a complaint
  # that an argument it asks about is missing. Each command's own parser then handles -h.
  local host="$1" sub="$2" a; shift 2
  for a in "$@"; do
    case "$a" in
      -h|--help) return 0 ;;
      -r|--repo) return 0 ;;
    esac
  done
  die "$sub: -r <repo> is required with -H (wt -H $host repos lists them)"
}

host_new_preflight() { # read-only checks in the same non-interactive SSH environment as remote_wt
  remote_sh "$1" "sh -s -- $(shell_join "$2" "$3")" <"$WG_LIB_DIR/vm/host-new-preflight.sh"
}

host_new() { # create the worktree on the VM, then the cmux row here unless --no-workspace
  local host="$1" prompt="" repo_request="" requested_agent="" inspect="" no_workspace=0 args=(); shift
  # Consume both ways of giving a brief HERE, and relay them the same way. A forwarded --prompt-stdin would
  # read nothing locally and pipe an empty prompt into ssh. The VM would then create the task with no brief.
  while [[ $# -gt 0 ]]; do case "$1" in
    -p|--prompt) [[ $# -ge 2 ]] || die "new: $1 needs a brief"; prompt="$2"; shift 2 ;;
    --prompt-stdin) IFS= read -r -d '' prompt || true; shift ;;
    -r|--repo) [[ $# -ge 2 ]] || die "new: $1 needs a repo"; repo_request="$2"; args+=("$1" "$2"); shift 2 ;;
    -a|--agent) [[ $# -ge 2 ]] || die "new: $1 needs an agent"; requested_agent="$2"; valid_agent "$requested_agent"; args+=("$1" "$2"); shift 2 ;;
    -m|--model) [[ $# -ge 2 ]] || die "new: $1 needs a model"; need_model "$2"; args+=("$1" "$2"); shift 2 ;;
    --no-workspace) no_workspace=1; shift ;;
    --model=*|-m?*) die "new: unknown option $1 (use -m <model>)" ;;
    -h|--help) usage; exit 0 ;;
    *) args+=("$1"); shift ;;
  esac; done
  if [[ $no_workspace -eq 0 ]]; then
    cmux_ok || die "cmux is not running; start cmux before creating a task on $host"
  fi
  host_new_preflight "$host" "$repo_request" "$requested_agent"
  inspect="wt -H $host list"
  [[ -z "$repo_request" ]] || inspect+=" -r $(shell_join "$repo_request")"
  local out name repo session rc result result_rc=0
  if out=$(printf '%s' "$prompt" | remote_wt_result_raw "$host" new "${args[@]}" --no-workspace --prompt-stdin 2>&1); then
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
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--repo) [[ $# -ge 2 ]] || die "open: $1 needs a repo"; repo="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "open: unknown option $1" ;;
      *) [[ -z "$name" ]] || die "open: unexpected argument $1"; name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || die "open: worktree name required (wt -H $host open -r <repo> <name>)"
  local p; p=$(remote_wt "$host" path "$name" -r "$repo")
  hook_safe_path "$p" || die "open: refusing an unsafe path from $host ($p)"
  open_code "vscode-remote://ssh-remote+$host$p/" "$host:$p"
}

host_rm() { # remove on the VM, close the row, then kill the session (closing first stops cmux recreating it)
  local host="$1" name="" repo="" args=(); shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--repo) [[ $# -ge 2 ]] || die "rm: $1 needs a repo"; repo="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) args+=("$1"); shift ;;
      *) [[ -z "$name" ]] || die "rm: unexpected argument $1"; name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || die "rm: worktree name required (wt -H $host rm -r <repo> <name>)"
  # The row's identity comes from -r. cmd_host has already refused -r unless it is an absolute path or
  # a plain repo name. A relative '.' or '..' would make repo_id '-', and close_row would close nothing.
  local session title; session=$(wt_session "$name" "$repo"); title=$(row_title "$name")
  check_row_removal "$title" "$repo" "$host"
  local agent_rc=0
  agent_on_vm "$host" "$session" || agent_rc=$?
  case $agent_rc in
    0) die "another agent is running in tmux session $session on $host; kept the worktree" ;;
    1) ;;
    *) die "cannot check the agent in tmux session $session on $host; kept the worktree" ;;
  esac
  remote_wt "$host" rm "$name" -r "$repo" "${args[@]}"
  close_row "$(cmux_row_field "$title" "$repo" id "$host")"
  remote_sh "$host" "exec tmux kill-session -t $(shell_join "=$session")" >/dev/null 2>&1 || true
}

cmd_host() { # wt -H <host> <sub> … — a stateless ssh passthrough; the Mac caches nothing about VMs
  local host="$1" sub="${2:-}" args=() v scoped=0; shift 2
  valid_host "$host" || die "invalid host '$host' (an ssh alias: letters, digits, '.', '_' and '-')"
  while [[ $# -gt 0 ]]; do   # normalize -r once: a trailing '/' would change repo_id, and so the identity
    case "$1" in
      -r|--repo) [[ $# -ge 2 ]] || die "$sub: $1 needs a repo"; v="$2"; while [[ "$v" == */ && "$v" != / ]]; do v="${v%/}"; done
                 # a relative path means nothing on the VM, and its basename is not the repo's. host_rm would
                 # then look for a row of repo '-' ('.' -> '-') and close a row that does not exist
                 case "$v" in /*) ;; ""|.|..|*/*) die "$sub: -r must be an absolute path on $host, or a repo name there (wt -H $host repos lists them)" ;; esac
                 args+=("$1" "$v"); shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]}"
  case "$sub" in
    new)       host_new "$host" "$@" ;;
    attach)    need_r "$host" "$sub" "$@"; host_attach "$host" "$@" ;;
    open)      need_r "$host" "$sub" "$@"; host_open "$host" "$@" ;;
    rm)        need_r "$host" "$sub" "$@"; host_rm "$host" "$@" ;;
    list)      for v in "$@"; do case "$v" in -r|--repo) scoped=1 ;; esac; done
               if [[ $scoped -eq 1 ]]; then remote_wt "$host" list "$@"
               else remote_wt "$host" list --all "$@"; fi ;;
    show|path) need_r "$host" "$sub" "$@"; remote_wt "$host" "$sub" "$@" ;;
    repos)     if [[ -t 1 ]]; then case " $* " in *" --porcelain "*|*" --table "*) ;; *) set -- "$@" --table ;; esac; fi
               remote_wt "$host" repos "$@" ;;     # ssh gives the VM no terminal, so ask for the table explicitly
    update)    remote_wt_tty "$host" "$sub" "$@" ;;   # the VM asks before it installs, so it needs a terminal
    help)      remote_wt "$host" "$sub" "$@" ;;
    *) die "wt -H: '$sub' does not run remotely (new attach list show rm path open repos update help)" ;;
  esac
}
