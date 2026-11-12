# shellcheck shell=bash
# Reads globals: CMUX_ERROR, REPO, WG_LIB_DIR, WG_MACHINE_RESULT, WG_TEARDOWN_CONTROL_FD, WG_TEARDOWN_WORKER_PID,
#   WG_TEARDOWN_LOCK_PATH, WT_BASE_FETCH_NOTIFIED, WT_TEARDOWN_FILE, WT_TEARDOWN_JSON.
# Receipts survive the task directory and distinguish Git removal from session cleanup.
# receipts.py owns receipt policy and atomic writes; Bash owns checkpoint timing and live checks.
WT_TEARDOWN_FILE='' WT_TEARDOWN_JSON='' WG_TEARDOWN_CLOSE_PHASE=0
teardown_interpreter() {
  # shellcheck source=lib/workgrove/vm/python-runtime.sh
  source "${BASH_SOURCE[0]%/*}/vm/python-runtime.sh" || return
  wg_run_python "$@"
}

teardown_control() {
  teardown_interpreter -c '
import json, socket, sys
channel = socket.socket(fileno=int(sys.argv[1]))
channel.sendall((json.dumps({"op":sys.argv[2],"path":sys.argv[3]}) + "\n").encode())
reply = b""
while not reply.endswith(b"\n") and len(reply) < 16384:
    part = channel.recv(4096)
    if not part:
        sys.exit("wt: teardown coordinator exited")
    reply += part
if reply != b"ok\n":
    sys.exit("wt: " + reply.decode().strip())
' "$WG_TEARDOWN_CONTROL_FD" "$1" "$WG_TEARDOWN_LOCK_PATH"
}

teardown_lock() { # Only the finite coordinator holds the lock descriptor; commands inherit a control channel.
  local name=$1 lock_path="$REPO/.git/wt/teardown/$1.lock"
  shift
  if [[ ${WG_TEARDOWN_LOCK_PATH:-} == "$lock_path" && ${WG_TEARDOWN_WORKER_PID:-} == "$BASHPID" ]]; then
    teardown_control acquire || die 'cannot validate teardown coordinator'
    return 0
  fi
  local rc=0
  WT_BASE_FETCH_NOTIFIED=$WT_BASE_FETCH_NOTIFIED teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/coordinator.py" \
    "$lock_path" "$name" "$BASH" "$WG_LIB_DIR/../../bin/wt" "${WG_MACHINE_RESULT:-}" "$@" || rc=$?
  exit "$rc"
}

teardown_release() { # Permit an independent observer after all Git cleanup has finished.
  teardown_control release || die 'cannot release cleanup lock'
  WG_TEARDOWN_CLOSE_PHASE=1
}

teardown_save() { # teardown_save <stage>; flush the receipt before the next destructive operation.
  WT_TEARDOWN_JSON=$(jq -c --arg stage "$1" '.stage=$stage' <<<"$WT_TEARDOWN_JSON") || die 'cannot encode teardown receipt'
  if [[ ${WG_TEARDOWN_CLOSE_PHASE:-0} == 1 ]]; then teardown_control acquire; else teardown_control check; fi \
    || die 'teardown lock is unavailable'
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/receipts.py" write "$WT_TEARDOWN_FILE" <<<"$WT_TEARDOWN_JSON" || die "cannot persist teardown receipt $WT_TEARDOWN_FILE"
  if [[ ${WG_TEARDOWN_CLOSE_PHASE:-0} == 1 ]]; then teardown_control release || die 'cannot release receipt lock'; fi
}

teardown_preflight() { # teardown_preflight <worktree path>
  local executable location root target parent hops commands=(git jq "$BASH" rm ps uname env cat grep basename dirname sed tr readlink mktemp pgrep sleep awk od)
  if have shasum; then commands+=(shasum); elif have sha256sum; then commands+=(sha256sum); fi
  if have cmux-tui; then commands+=(cmux-tui); fi
  wg_select_python || die 'teardown requires Python 3.9 or later'
  commands+=("${wg_python}")
  if is_remote; then commands+=(tmux); else
    location=$(cmux_bin || true)
    [[ -z $location ]] || commands+=("$location")
  fi
  root=$(physical_dir "$1")
  for executable in "${commands[@]}"; do
    location=$(type -P "$executable") || die "teardown requires $executable"
    path_within "$location" "$root" && die "$executable is inside the worktree; use an installation outside it"
    parent=${location%/*}; [[ $parent != "$location" ]] || parent=.
    target=$(cd "$parent" && printf '%s/%s' "$(pwd -P)" "${location##*/}")
    path_within "$target" "$root" && die "$executable is inside the worktree; use an installation outside it"
    location=$target
    hops=0
    while [[ -L $location && $hops -lt 32 ]]; do
      target=$(readlink "$location") || die "cannot resolve $executable"
      case $target in /*) location=$target ;; *) location="${location%/*}/$target" ;; esac
      hops=$((hops + 1))
    done
    [[ ! -L $location ]] || die "cannot resolve $executable"
    parent=${location%/*}; [[ $parent != "$location" ]] || parent=.
    location=$(cd "$parent" && printf '%s/%s' "$(pwd -P)" "${location##*/}")
    path_within "$location" "$root" && die "$executable is inside the worktree; use an installation outside it"
  done
  location=$(physical_dir "$WG_LIB_DIR")
  path_within "$location" "$root" && die 'wt libraries are inside the target worktree; use an installation outside it'
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" probe || die 'kernel task command identities are unavailable; kept the task'
  return 0
}

teardown_commands_observe() {
  local manifest generation self
  manifest=$(jq -c 'if has("commands") then .commands else null end' <<<"$WT_TEARDOWN_JSON") || return 1
  if [[ $manifest == null ]]; then
    self=$(jq -r .self <<<"$WT_TEARDOWN_JSON")
    [[ $self == '' ]]
    return
  fi
  generation=$(jq -r .generation <<<"$WT_TEARDOWN_JSON")
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" observe "$generation" <<<"$manifest"
}

teardown_commands_stop() {
  local manifest generation
  manifest=$(jq -c 'if has("commands") then .commands else null end' <<<"$WT_TEARDOWN_JSON") || return 1
  [[ $manifest != null ]] || { teardown_commands_observe; return; }
  generation=$(jq -r .generation <<<"$WT_TEARDOWN_JSON")
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" stop "$generation" "$1" <<<"$manifest"
}

teardown_commands_capture() { # Stop proven task commands before the last work-preservation check.
  local root=$1 start=$2 observers=${3:-[]} generation manifest refreshed stage
  generation=$(jq -r .generation <<<"$WT_TEARDOWN_JSON")
  manifest=$(jq -c 'if has("commands") then .commands else null end' <<<"$WT_TEARDOWN_JSON") || return 1
  stage=$(jq -r .stage <<<"$WT_TEARDOWN_JSON")
  refreshed=$(teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" capture "$generation" "$root" "$start" \
    "$WG_TEARDOWN_ORIGIN_PID" "$observers" <<<"$manifest") || return 1
  WT_TEARDOWN_JSON=$(jq -c --argjson commands "$refreshed" '.commands=$commands' <<<"$WT_TEARDOWN_JSON") || return 1
  teardown_save "$stage"
  teardown_commands_stop commands
}

teardown_preservation() { # Recheck the frozen proof before deleting the remaining branch.
  local name=$1 branch=$2 head=$3 proof base expected current canonical='' rc=0 retained
  proof=$(jq -r .proof <<<"$WT_TEARDOWN_JSON")
  base=$(jq -r .base <<<"$WT_TEARDOWN_JSON")
  [[ $proof != discard ]] || return 0
  case $proof in ancestry|content|published) ;; *) return 1 ;; esac
  if [[ $proof == published || $base =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    retained="refs/wt/preserved/$(jq -r .generation <<<"$WT_TEARDOWN_JSON")"
    git -C "$REPO" check-ref-format "$retained" >/dev/null 2>&1 || return 1
    git -C "$REPO" symbolic-ref -q "$retained" >/dev/null 2>&1 && return 1
    [[ $? == 1 ]] || return 1
    current=$(preservation_git -C "$REPO" rev-parse -q --verify "$retained^{commit}") || return 1
    [[ $current == "$head" ]]
    return
  fi
  meta_require "$name"
  comparison_ref "$base" "$branch" canonical || return 1
  forget_base "$base" || return 1
  fetch_base "$base" || rc=$?
  [[ $rc != 1 ]] || return 1
  expected=$(jq -r .base_object <<<"$WT_TEARDOWN_JSON")
  current=$(preservation_git -C "$REPO" rev-parse -q --verify "$canonical^{commit}") || return 1
  [[ $current == "$expected" ]]
}

teardown_sidecars_snapshot() {
  local metadata prompt started
  metadata=$(metadata_fingerprint "$(wt_meta "$1")") || return 1
  prompt=$(metadata_fingerprint "$(wt_prompt "$1")") || return 1
  started=$(metadata_fingerprint "$(wt_started "$1")") || return 1
  jq -cn --arg metadata "$metadata" --arg prompt "$prompt" --arg started "$started" '$ARGS.named'
}

teardown_remove_registration() { # One task's recovery must never prune another task's registration.
  local path=$1 listing registered
  task_admin_preserved "$path" || return 1
  listing=$(git -C "$REPO" -c core.quotePath=true worktree list --porcelain) || return 1
  registered=$(teardown_interpreter -c '
import ast, os, sys
target = os.fsencode(sys.argv[1])
if b"\n" in target:
    sys.exit("wt: cannot safely inspect a multiline worktree path")
found = False
for line in sys.stdin.buffer.read().split(b"\n"):
    if not line.startswith(b"worktree "):
        continue
    path = line[len(b"worktree "):]
    if path.startswith(b"\""):
        path = ast.literal_eval("b" + path.decode("ascii"))
    if not isinstance(path, bytes):
        sys.exit("wt: invalid worktree path record")
    found |= path == target
print("present" if found else "absent")
' "$path" <<<"$listing") || return 1
  if [[ $registered == present ]]; then git -C "$REPO" worktree remove --force "$path"
  else [[ ! -e $path && ! -L $path ]]; fi
}

teardown_sidecars_check() { # Absence is valid only after durable sidecar-removal intent.
  local name=$1 snapshot=$2 allow_absent=${3:-0} key path expected current
  for key in metadata prompt started; do
    case $key in metadata) path=$(wt_meta "$name") ;; prompt) path=$(wt_prompt "$name") ;; started) path=$(wt_started "$name") ;; esac
    expected=$(jq -er --arg key "$key" '.[$key] | select(type == "string")' <<<"$snapshot") || return 1
    [[ $expected == absent || $expected =~ ^[0-9a-f]{64}$ ]] || return 1
    current=$(metadata_fingerprint "$path") || return 1
    [[ $allow_absent != 1 || $current != absent ]] || continue
    [[ $current == "$expected" ]] || return 1
  done
}

# Inputs: task name, keep flag, and caller-named dispatch output. The receipt can have any supported stage.
# Outputs: new or resume. Mutations: load WT_TEARDOWN_JSON; persist the keep flag for recovery.
teardown_rm_recovery() {
  local __rm_name=$1 __rm_keep=$2
  local -n __rm_dispatch=$3
  __rm_dispatch=new
  if [[ ! -d $(wt_path "$__rm_name") && -f $WT_TEARDOWN_FILE ]]; then
    WT_TEARDOWN_JSON=$(cat "$WT_TEARDOWN_FILE")
    teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/receipts.py" validate "$REPO" "$__rm_name" "$(wt_path "$__rm_name")" \
      <<<"$WT_TEARDOWN_JSON" \
      || die 'invalid teardown receipt'
    if [[ $(jq -r .stage <<<"$WT_TEARDOWN_JSON") != complete || ! -f $(wt_meta "$__rm_name") ]]; then
      if [[ $__rm_keep == 1 ]]; then
        WT_TEARDOWN_JSON=$(jq -c '.keep="1"' <<<"$WT_TEARDOWN_JSON")
        teardown_save "$(jq -r .stage <<<"$WT_TEARDOWN_JSON")"
      fi
      __rm_dispatch=resume
    fi
  fi
}

# Inputs: name, path, branch, force, discard-commits, keep, row host, and caller-named evidence map.
# Outputs: captured verified facts in the map and WT_TEARDOWN_JSON, before the new prepared checkpoint.
# Mutations: refresh preservation caches and ownership globals; retain a preservation ref when required.
# Call this phase directly so errexit still protects assignments such as the title lookup.
teardown_rm_evidence() {
  local __evidence_name=$1 __evidence_path=$2 __evidence_branch=$3 __evidence_force=$4 __evidence_discard_commits=$5 __evidence_keep=$6 __evidence_row_host=$7
  local -n __evidence_evidence=$8
  local __evidence_self_remote=0 __evidence_host='' __evidence_session='' __evidence_title='' __evidence_native=0
  teardown_preflight "$__evidence_path"
  local __evidence_verified_head __evidence_verified_base='' __evidence_proof='' __evidence_generation
  __evidence_verified_head=$(preservation_git -C "$REPO" rev-parse --verify "refs/heads/$__evidence_branch") || die 'cannot resolve task head'
  local __evidence_here __evidence_there; __evidence_here=$(pwd -P); __evidence_there=$(cd "$__evidence_path" 2>/dev/null && pwd -P) || __evidence_there="$__evidence_path"   # a symlinked cwd is still inside
  [[ "$__evidence_here" == "$__evidence_there" || "$__evidence_here" == "$__evidence_there/"* ]] && die "you are inside $__evidence_name; cd out first (e.g. cd $REPO)"
  local __evidence_verified_metadata __evidence_verified_sidecars __evidence_verified_branch_config __evidence_metadata_path
  __evidence_metadata_path=$(wt_meta "$__evidence_name")
  __evidence_verified_sidecars=$(teardown_sidecars_snapshot "$__evidence_name") || die 'cannot fingerprint task metadata or sidecars'
  __evidence_verified_metadata=$(jq -r .metadata <<<"$__evidence_verified_sidecars")
  __evidence_verified_branch_config=$(teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/branch_config.py" snapshot "$REPO" "$__evidence_branch") || die 'cannot snapshot local branch configuration'
  meta_require "$__evidence_name"
  [[ $(metadata_fingerprint "$__evidence_metadata_path") == "$__evidence_verified_metadata" ]] || die 'task metadata changed while loading'
  local __evidence_base; __evidence_base=${WT_META[base]-}; [[ -n "$__evidence_base" ]] || __evidence_base=$(default_base)
  if [[ $__evidence_force -eq 0 ]]; then
    local __evidence_reasons=()
    rm_reasons "$__evidence_name" "$__evidence_path" "$__evidence_branch" "$__evidence_base" __evidence_reasons "$__evidence_discard_commits"
    if [[ ${#__evidence_reasons[@]} -gt 0 ]]; then
      printf 'wt: refusing to remove %s: %s\n' "$__evidence_name" "$(IFS=';'; echo "${__evidence_reasons[*]}")" >&2
      printf 'wt: inspect with: wt show %s — then push/merge, check the branch out again or copy the file back, or re-run with --force to discard.\n' "$__evidence_name" >&2
      case "${__evidence_reasons[*]}" in *' not merged into '*) printf 'wt: --discard-commits waives only the commit reason (a squash merge the base later edited or reverted); the other checks stay.\n' >&2 ;; esac
      exit 3
    fi
  fi
  if [[ $__evidence_force == 1 ]]; then __evidence_proof=discard
  else
    __evidence_base=${WT_RM_BASE:-$__evidence_base}; __evidence_proof=${WT_RM_PROOF:-}
    if [[ -z $__evidence_proof && $__evidence_discard_commits == 1 ]]; then __evidence_proof=discard; fi
    [[ -n $__evidence_proof ]] || die 'work preservation proof is missing; kept the worktree'
  fi
  __evidence_verified_base=$(preservation_git -C "$REPO" rev-parse -q --verify "$__evidence_base^{commit}" 2>/dev/null || true)
  if is_remote && [[ -n ${TMUX:-} ]]; then
    local __evidence_current
    __evidence_session=$(wt_session "$__evidence_name" "$REPO")
    [[ ${TMUX_PANE:-} =~ ^%[0-9]+$ ]] || die 'cannot identify the caller tmux pane; kept the worktree'
    __evidence_current=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>&1) \
      || die "cannot read the current tmux session: $__evidence_current; rerun this command with escalation if a sandbox blocks the socket"
    [[ -n "$__evidence_current" ]] || die "cannot read the current tmux session: tmux returned no session name"
    if [[ "$__evidence_current" == "$__evidence_session" ]]; then
      local __evidence_pane_pid
      __evidence_pane_pid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}') || die 'cannot identify tmux pane process'
      process_descends "$BASHPID" "$__evidence_pane_pid" || die 'cannot verify caller tmux ownership; kept the worktree'
      local __evidence_ownership_rc=0
      tmux_self_ownership "$__evidence_session" "$__evidence_name" || __evidence_ownership_rc=$?
      case $__evidence_ownership_rc in
        0) __evidence_self_remote=1 ;;
        1) die 'another agent is running in this tmux session; kept the worktree' ;;
        3) die "unowned process blocks this tmux session: $TMUX_BLOCKER; kept the worktree" ;;
        *) die 'cannot verify exclusive agent ownership in this tmux session; kept the worktree' ;;
      esac
    fi
  fi
  local __evidence_row="" __evidence_self=""
  __evidence_title=$(task_title "$__evidence_name")
  if is_remote; then
    [[ -n "$__evidence_session" ]] || __evidence_session=$(wt_session "$__evidence_name" "$REPO")
    if [[ $__evidence_self_remote -eq 0 ]]; then
      local __evidence_agent_rc=0
      tmux_agent "$__evidence_session" || __evidence_agent_rc=$?
      case $__evidence_agent_rc in
        0) die "another agent is running in tmux session $__evidence_session; kept the worktree" ;;
        1) ;;
        *) die "cannot check the agent in tmux session $__evidence_session; kept the worktree" ;;
      esac
    fi
    if [[ $__evidence_self_remote -eq 1 && $(tmux show-environment -t "=$__evidence_session" WT_CMUX_CLOSE_ON_EXIT 2>/dev/null) == WT_CMUX_CLOSE_ON_EXIT=1 ]]; then
      __evidence_native=1
    fi
  else
    cmux_require check_row_removal "$__evidence_title" "$REPO" __evidence_row __evidence_self "" "$(wt_path "$__evidence_name")"
  fi
  if is_remote; then
    __evidence_host=${WT_META[row_host]:-}
    valid_host "$__evidence_host" || die 'task row host is unverified; kept the worktree'
    [[ -z $__evidence_row_host || $__evidence_row_host == "$__evidence_host" ]] \
      || die 'Mac row host changed; use the original SSH alias for cleanup'
  fi
  if [[ $__evidence_self_remote -eq 1 && $__evidence_native -eq 0 ]]; then
    # Check the relay setup only after the reasons above, while the worktree is still intact.
    hook_ok_repo || die "cannot request Mac row cleanup for $REPO"
    local __evidence__ident=() __evidence__tui_socket __evidence__tui_terminal
    if ! relay_env __evidence__ident __evidence__tui_socket __evidence__tui_terminal; then
      [[ -z ${CMUX_TUI_SOCKET:-} ]] \
        || die "this row predates native teardown; close and reopen this row on the Mac: wt -H $__evidence_host attach -r $(shell_join "$REPO") $__evidence_name, then retry"
      die "cannot find the Mac cmux relay in this session"
    fi
    have cmux-tui || die 'legacy self-cleanup requires cmux-tui outside the task worktree'
  fi
  __evidence_host=${__evidence_host:-${WT_HOST:-}}
  local __evidence_tmux_identity='null' __evidence_tmux_owner='null'
  if is_remote; then
    local __evidence_identity_rc=0
    __evidence_tmux_identity=$(task_tmux_identity "$__evidence_session") || __evidence_identity_rc=$?
    [[ $__evidence_identity_rc != 2 ]] || die 'cannot identify the task tmux session'
    [[ $__evidence_identity_rc == 0 ]] || __evidence_tmux_identity=null
    if [[ $__evidence_identity_rc == 0 ]]; then
      if [[ $__evidence_self_remote == 1 ]]; then __evidence_tmux_owner=$WT_TMUX_OWNER
      else __evidence_tmux_owner=$(tmux_idle_owner "$__evidence_session") || die 'cannot record idle task pane processes'; fi
    fi
  fi
  [[ $(preservation_git -C "$REPO" rev-parse --verify "refs/heads/$__evidence_branch") == "$__evidence_verified_head" ]] || die 'task head changed during teardown'
  [[ $(preservation_git -C "$REPO" rev-parse -q --verify "$__evidence_base^{commit}" 2>/dev/null || true) == "$__evidence_verified_base" ]] || die 'comparison base changed during teardown'
  __evidence_generation=${WT_META[generation]:-$__evidence_verified_head}
  if [[ $__evidence_proof == published || $__evidence_base =~ ^[0-9a-f]{40,64}$ ]]; then
    local __evidence_retained=''
    local __evidence_anchor_rc=0
    git -C "$REPO" symbolic-ref -q "refs/wt/preserved/$__evidence_generation" >/dev/null 2>&1 || __evidence_anchor_rc=$?
    [[ $__evidence_anchor_rc == 1 ]] || die 'preservation anchor must be a direct ref; kept the worktree'
    __evidence_retained=$(preservation_git -C "$REPO" rev-parse -q --verify "refs/wt/preserved/$__evidence_generation" 2>/dev/null || true)
    if [[ $__evidence_retained != "$__evidence_verified_head" ]]; then
      git -C "$REPO" update-ref --no-deref "refs/wt/preserved/$__evidence_generation" "$__evidence_verified_head" '' || die 'cannot retain preserved work'
    fi
    warn "retained published commits at refs/wt/preserved/$__evidence_generation"
  fi
  if [[ $__evidence_self_remote == 1 ]]; then __evidence_self=remote; fi
  local __evidence_remote=0; is_remote && __evidence_remote=1
  local __evidence_previous_commands=null
  if [[ -f $WT_TEARDOWN_FILE ]]; then
    local __evidence_previous_record __evidence_previous_generation
    __evidence_previous_record=$(jq -ec --arg repo "$REPO" --arg name "$__evidence_name" 'select(.repo == $repo and .name == $name)' "$WT_TEARDOWN_FILE") \
      || die 'previous cleanup identity is unverified; kept its command evidence'
    __evidence_previous_generation=$(jq -r .generation <<<"$__evidence_previous_record")
    if [[ $__evidence_previous_generation == "$__evidence_generation" ]]; then
      __evidence_previous_commands=$(jq -c 'if has("commands") then .commands else null end' <<<"$__evidence_previous_record") || die 'invalid previous command evidence'
    elif [[ $(jq -r .stage <<<"$__evidence_previous_record") == complete ]]; then
      (WT_TEARDOWN_JSON=$__evidence_previous_record; teardown_commands_observe) \
        || die 'previous generation has unverified task commands; kept its receipt'
    else die 'previous cleanup generation changed; kept its command evidence'; fi
  fi
  if [[ $__evidence_previous_commands != null ]]; then
    teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/commands.py" validate "$__evidence_generation" <<<"$__evidence_previous_commands" \
      || die 'previous task command evidence is invalid; kept the worktree'
  fi
  WT_TEARDOWN_JSON=$(jq -cn --arg name "$__evidence_name" --arg repo "$REPO" --arg path "$__evidence_path" --arg branch "$__evidence_branch" \
    --arg head "$__evidence_verified_head" --arg metadata_hash "$__evidence_verified_metadata" --arg base "$__evidence_base" --arg base_object "$__evidence_verified_base" --arg proof "$__evidence_proof" \
    --argjson branch_config "$__evidence_verified_branch_config" --argjson sidecars "$__evidence_verified_sidecars" --arg generation "$__evidence_generation" --arg agent "${WT_META[agent]-}" --argjson runtime "${WT_META[runtime]:-null}" --arg row "$__evidence_row" --arg self "$__evidence_self" --arg session "$__evidence_session" \
    --argjson commands "$__evidence_previous_commands" --argjson tmux_identity "$__evidence_tmux_identity" --argjson tmux_owner "$__evidence_tmux_owner" --arg title "$__evidence_title" --arg host "$__evidence_host" --arg workspace "${WT_META[workspace]:-1}" --arg keep "$__evidence_keep" --arg native "$__evidence_native" --arg remote "$__evidence_remote" '$ARGS.named')
  __evidence_evidence=(
    [verified_head]="$__evidence_verified_head"
    [verified_base]="$__evidence_verified_base"
    [base]="$__evidence_base"
    [verified_metadata]="$__evidence_verified_metadata"
    [verified_sidecars]="$__evidence_verified_sidecars"
    [metadata_path]="$__evidence_metadata_path"
    [self_remote]="$__evidence_self_remote"
    [row]="$__evidence_row"
    [self]="$__evidence_self"
    [title]="$__evidence_title"
    [session]="$__evidence_session"
    [tmux_identity]="$__evidence_tmux_identity"
    [tmux_owner]="$__evidence_tmux_owner"
    [previous_commands]="$__evidence_previous_commands"
  )
}

# Inputs: name, path, and captured evidence map. The receipt stage is prepared.
# Outputs: none. Mutations: refresh ownership globals, save command evidence, and stop task commands.
teardown_rm_cancel() {
  local name=$1 path=$2
  local -n __cancel_evidence=$3
  local self=${__cancel_evidence[self]} self_remote=${__cancel_evidence[self_remote]}
  local title=${__cancel_evidence[title]} row=${__cancel_evidence[row]} session=${__cancel_evidence[session]}
  local previous_commands=${__cancel_evidence[previous_commands]}
  if [[ $self == self ]]; then
    local capture_row='' capture_self=''
    cmux_require check_row_removal "$title" "$REPO" capture_row capture_self '' "$path"
    [[ $capture_row == "$row" && $capture_self == self ]] || die 'self ownership changed before command cancellation'
    teardown_commands_capture "$ROW_AGENT_PID" "$ROW_AGENT_START" "$ROW_AGENT_OBSERVERS" || die 'task command cancellation is incomplete; kept the worktree'
  elif [[ $self_remote == 1 ]]; then
    tmux_self_ownership "$session" "$name" || die 'self ownership changed before command cancellation'
    teardown_commands_capture "$(jq -r .pid <<<"$WT_TMUX_OWNER")" "$(jq -r .start <<<"$WT_TMUX_OWNER")" \
      || die 'task command cancellation is incomplete; kept the worktree'
  elif [[ $previous_commands != null ]]; then
    teardown_commands_stop commands || die 'recorded task command cancellation is incomplete; kept the worktree'
  fi
}

# Inputs: name, path, branch, force, discard-commits, and captured evidence map. The receipt stage is prepared.
# Outputs: none. Mutations: refresh preservation caches, metadata, and ownership globals from live observations.
teardown_rm_revalidate() {
  local name=$1 path=$2 branch=$3 force=$4 discard_commits=$5
  local -n __recheck_evidence=$6
  local base=${__recheck_evidence[base]} verified_head=${__recheck_evidence[verified_head]}
  local verified_base=${__recheck_evidence[verified_base]} tmux_identity=${__recheck_evidence[tmux_identity]}
  local tmux_owner=${__recheck_evidence[tmux_owner]} self_remote=${__recheck_evidence[self_remote]}
  local title=${__recheck_evidence[title]} row=${__recheck_evidence[row]} self=${__recheck_evidence[self]}
  local session=${__recheck_evidence[session]} final_reasons=()
  if [[ $force == 0 ]]; then
    forget_base "$base" || die 'comparison base is no longer valid'
    rm_reasons "$name" "$path" "$branch" "$base" final_reasons "$discard_commits"
    ((${#final_reasons[@]} == 0)) || die "work changed after preflight: ${final_reasons[*]}"
  fi
  [[ $(preservation_git -C "$REPO" rev-parse --verify "refs/heads/$branch") == "$verified_head" ]] || die 'task head changed after preflight'
  [[ $(preservation_git -C "$REPO" rev-parse -q --verify "$base^{commit}" 2>/dev/null || true) == "$verified_base" ]] || die 'comparison base changed after preflight'
  if is_remote; then
    local final_identity='' final_identity_rc=0
    final_identity=$(task_tmux_identity "$session") || final_identity_rc=$?
    [[ $final_identity_rc != 2 ]] || die 'cannot verify tmux identity after preflight'
    [[ $final_identity_rc == 0 ]] || final_identity=null
    [[ $(jq -cS . <<<"$final_identity") == $(jq -cS . <<<"$tmux_identity") ]] \
      || die 'tmux session identity changed after preflight'
    if [[ $self_remote == 1 ]]; then
      tmux_self_ownership "$session" "$name" || die 'tmux ownership changed after preflight'
    elif [[ $final_identity_rc == 0 ]]; then
      tmux_recorded_owner "$session" "$name" "$tmux_owner" || die 'idle tmux ownership changed after preflight'
    fi
  fi
  if ! is_remote; then
    local final_row='' final_self=''
    cmux_require check_row_removal "$title" "$REPO" final_row final_self '' "$path"
    [[ $final_row == "$row" && $final_self == "$self" ]] || die 'row ownership changed after preflight'
  fi
}

# Inputs: name, path, and captured evidence map. The receipt stage is prepared.
# Outputs: none. Mutations: remove the worktree or only its registration after fresh boundary checks.
teardown_rm_worktree() {
  local name=$1 path=$2
  local -n __remove_evidence=$3
  local metadata_path=${__remove_evidence[metadata_path]} verified_metadata=${__remove_evidence[verified_metadata]}
  local verified_sidecars=${__remove_evidence[verified_sidecars]}
  [[ $(metadata_fingerprint "$metadata_path") == "$verified_metadata" ]] || die 'task metadata changed before worktree removal; kept the worktree'
  teardown_sidecars_check "$name" "$verified_sidecars" || die 'sidecars changed before worktree removal; kept the worktree'
  task_admin_preserved "$path" || die 'private submodule Git data prevents worktree removal'
  teardown_control check || die 'teardown coordinator exited before worktree removal'
  if [[ -d $path ]]; then
    git -C "$REPO" worktree remove --force "$path" || die "git worktree remove failed; receipt: $WT_TEARDOWN_FILE"
  else teardown_remove_registration "$path" || die 'cannot remove the missing task registration'; fi
}

teardown_row_context() {
  local row_closed=$1 row_host=$2
  [[ $(jq -r .remote <<<"$WT_TEARDOWN_JSON") == 1 ]] || return 0
  local expected
  expected=$(jq -er '.host | strings | select(length > 0)' <<<"$WT_TEARDOWN_JSON") || return 1
  valid_host "$expected" || return 1
  [[ ${row_closed:-0} == 1 || -n ${row_host:-} ]] || return 0
  [[ ${row_host:-} == "$expected" ]]
}

# Inputs: name, path, branch, keep, row, remote, row-closed, and observe-only flags; any supported receipt stage.
# Outputs: verified absence or refusal. Mutations: save complete after fresh observations; never delete work or close sessions.
teardown_observe() {
  local row_closed=$7 observe_only=$8
  local name=$1 path=$2 branch=$3 keep=$4 row=$5 remote=$6 registrations current rc=0 rows error
  [[ ! -e $path && ! -L $path ]] || return 1
  [[ ! -e $REPO/.git/wt/teardown/$name.branch-locks && ! -L $REPO/.git/wt/teardown/$name.branch-locks ]] || return 1
  [[ $(teardown_sidecars_snapshot "$name") == '{"metadata":"absent","prompt":"absent","started":"absent"}' ]] || return 1
  task_admin_preserved "$path" || return 1
  teardown_commands_observe || return 1
  registrations=$(git -C "$REPO" worktree list --porcelain) || return 1
  ! grep -qxF "worktree $path" <<<"$registrations" || return 1
  if [[ $keep == 0 ]]; then
    git -C "$REPO" show-ref -q --verify "refs/heads/$branch" && return 1
    rc=$?; [[ $rc == 1 ]] || return 1
    [[ $(teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/branch_config.py" snapshot "$REPO" "$branch") == '""' ]] || return 1
  fi
  if [[ $remote == 1 ]]; then
    [[ ${row_closed:-0} == 1 ]] || return 1
    current=$(task_tmux_identity "$(jq -r .session <<<"$WT_TEARDOWN_JSON")") && rc=0 || rc=$?
    [[ $rc == 1 ]] || return 1
  else
    rows='{"workspaces":[]}'
    if ! cmux_bin >/dev/null; then
      [[ -z $row && -z ${CMUX_WORKSPACE_ID:-} ]] || return 1
    elif error=$(cmux_call ping 2>&1); then
      rows=$(rows_json checked) || return 1
    else
      [[ -z $row && -z ${CMUX_WORKSPACE_ID:-} && $error == 'Error: Socket not found at '* ]] || return 1
    fi
    rc=0
    jq -e --arg row "$row" --arg name "$(row_title "$name")" --arg title "$(jq -r '.title // .name' <<<"$WT_TEARDOWN_JSON")" \
      --arg repo "$(repo_id "$REPO")" --arg path "$path" --arg sep "$ROW_SEP" "$ROW_JQ"'
      any(.workspaces[]; ($row != "" and .id == $row) or task_row($name; $repo; ""; $sep) or task_row($title; $repo; ""; $sep)
        or unclaimed_row($name; ""; $sep) or unclaimed_row($title; ""; $sep)
        or (on_host(""; $sep) and ((.current_directory // "") as $cwd
          | ($cwd | type) == "string" and ($cwd == $path or ($cwd | startswith($path + "/"))))))' \
      <<<"$rows" >/dev/null || rc=$?
    [[ $rc == 1 ]] || return 1
  fi
  teardown_save complete
  if [[ $remote == 1 && ${row_closed:-0} == 1 && ${observe_only:-0} == 1 ]]; then
    printf 'closed receipt %s\n' "$(metadata_fingerprint "$WT_TEARDOWN_FILE")"
  fi
}

# Inputs: name, branch, expected head, and keep flag. The receipt stage is prepared or worktree_removed.
# Outputs: none. Mutations: refresh preservation evidence, delete the verified branch, and save branch_config_removing.
teardown_stage_branch() {
  local name=$1 branch=$2 head=$3 keep=$4 current
  local ref_rc=0
  git -C "$REPO" show-ref -q --verify "refs/heads/$branch" || ref_rc=$?
  case $ref_rc in
    0) current=$(preservation_git -C "$REPO" rev-parse --verify "refs/heads/$branch") || die 'cannot resolve remaining task branch' ;;
    1) current='' ;;
    *) die 'cannot inspect remaining task branch; cleanup remains pending' ;;
  esac
  [[ $(metadata_fingerprint "$(wt_meta "$name")") == $(jq -r .metadata_hash <<<"$WT_TEARDOWN_JSON") ]] \
    || die 'task metadata changed before branch removal; kept the branch and metadata'
  if [[ $keep == 0 && -n $current ]]; then
    [[ $current == "$head" ]] || die "worktree removed, but $branch changed; kept branch and receipt $WT_TEARDOWN_FILE (retry with --keep-branch to preserve it)"
    local registrations
    registrations=$(git -C "$REPO" worktree list --porcelain) || die 'cannot check branch registrations'
    if grep -qxF "branch refs/heads/$branch" <<<"$registrations"; then die "branch $branch is checked out elsewhere; kept it"; fi
    teardown_preservation "$name" "$branch" "$head" || die 'preservation evidence changed; kept branch and metadata (retry with --keep-branch to preserve it)'
    [[ $(metadata_fingerprint "$(wt_meta "$name")") == $(jq -r .metadata_hash <<<"$WT_TEARDOWN_JSON") ]] \
      || die 'task metadata changed before branch removal; kept the branch and metadata'
    teardown_control check || die 'teardown coordinator exited before branch removal'
    git -C "$REPO" update-ref --no-deref -d "refs/heads/$branch" "$head" || die "worktree removed, but branch deletion failed; retry wt rm $name -r $(shell_join "$REPO")"
  fi
  teardown_save branch_config_removing
}

# Inputs: name, branch, and keep flag. The receipt stage is branch_config_removing.
# Outputs: none. Mutations: recover cleanup locks, remove frozen configuration, and save sidecars_removing.
teardown_stage_config() {
  local name=$1 branch=$2 keep=$3
  teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/branch_config.py" recover "$REPO" "$branch" null "$(jq -r .generation <<<"$WT_TEARDOWN_JSON")" \
    || die 'cannot recover recorded branch cleanup locks; kept sidecars and receipt'
  if [[ $keep == 0 ]]; then
    teardown_interpreter "$WG_VERSION_ROOT/lib/workgrove/branch_config.py" remove "$REPO" "$branch" "$(jq -c '.branch_config // null' <<<"$WT_TEARDOWN_JSON")" "$(jq -r .generation <<<"$WT_TEARDOWN_JSON")" \
      || die 'Git branch cleanup remains pending; kept sidecars and receipt'
  fi
  local snapshot
  snapshot=$(jq -c '.sidecars // null' <<<"$WT_TEARDOWN_JSON")
  if [[ $snapshot == null ]]; then
    snapshot=$(teardown_sidecars_snapshot "$name") || die 'cannot fingerprint remaining sidecars'
    WT_TEARDOWN_JSON=$(jq -c --argjson sidecars "$snapshot" '.sidecars=$sidecars' <<<"$WT_TEARDOWN_JSON")
  fi
  [[ $(jq -r .metadata <<<"$snapshot") == $(jq -r .metadata_hash <<<"$WT_TEARDOWN_JSON") ]] || die 'metadata snapshot changed; kept sidecars and receipt'
  teardown_sidecars_check "$name" "$snapshot" || die 'sidecars changed before cleanup; kept sidecars and receipt'
  teardown_save sidecars_removing
}

# Inputs: name, path, branch, and keep flag. The receipt stage is sidecars_removing.
# Outputs: none. Mutations: unlink each unchanged sidecar, save git_removed, and print the removal result.
teardown_stage_sidecars() {
  local name=$1 path=$2 branch=$3 keep=$4
  [[ ! -e $path && ! -L $path ]] || die 'worktree reappeared; kept sidecars and receipt'
  if [[ $keep == 0 ]]; then
    local branch_rc=0
    git -C "$REPO" show-ref -q --verify "refs/heads/$branch" || branch_rc=$?
    [[ $branch_rc == 1 ]] || die 'task branch reappeared or is unreadable; kept sidecars and receipt'
  fi
  local sidecars key sidecar
  sidecars=$(jq -c .sidecars <<<"$WT_TEARDOWN_JSON")
  teardown_sidecars_check "$name" "$sidecars" 1 || die 'sidecars changed during cleanup; kept sidecars and receipt'
  for key in metadata prompt started; do
    teardown_sidecars_check "$name" "$sidecars" 1 || die 'sidecars changed during cleanup; kept sidecars and receipt'
    case $key in metadata) sidecar=$(wt_meta "$name") ;; prompt) sidecar=$(wt_prompt "$name") ;; started) sidecar=$(wt_started "$name") ;; esac
    teardown_control check || die 'teardown coordinator exited before sidecar removal'
    rm -f "$sidecar" || die 'worktree removed, but sidecar cleanup failed'
  done
  [[ $(teardown_sidecars_snapshot "$name") == '{"metadata":"absent","prompt":"absent","started":"absent"}' ]] || die 'sidecars reappeared during cleanup'
  teardown_save git_removed
  printf 'removed %s%s\n' "$name" "$(if [[ $keep == 1 ]]; then printf ' (branch %s kept)' "$branch"; fi)"
}

# Inputs: name, path, branch, keep, row, remote, row-closed, defer-close, and observe-only flags.
# The receipt stage is git_removed or close_requested, including an uninterrupted sidecar continuation.
# Outputs: completion or pending status. Mutations: save close_requested, release the coordinator, and close owned sessions.
# This phase also stops remaining recorded commands and saves complete only after independent observation.
teardown_stage_close() {
  local name=$1 path=$2 branch=$3 keep=$4 row=$5 remote=$6 row_closed=$7 defer_close=$8 observe_only=$9
  local self session native host title rc=0
  [[ ! -e $path && ! -L $path ]] || die 'worktree reappeared; session cleanup remains pending'
  [[ $(teardown_sidecars_snapshot "$name") == '{"metadata":"absent","prompt":"absent","started":"absent"}' ]] || die 'sidecars reappeared; session cleanup remains pending'
  row=$(jq -r .row <<<"$WT_TEARDOWN_JSON"); self=$(jq -r .self <<<"$WT_TEARDOWN_JSON")
  session=$(jq -r .session <<<"$WT_TEARDOWN_JSON"); native=$(jq -r .native <<<"$WT_TEARDOWN_JSON")
  remote=$(jq -r .remote <<<"$WT_TEARDOWN_JSON"); host=$(jq -r .host <<<"$WT_TEARDOWN_JSON")
  title=$(jq -r .title <<<"$WT_TEARDOWN_JSON")
  teardown_save close_requested
  teardown_release
  # Self-closure may kill this process before it can record a confirmed outcome.
  if [[ $remote == 1 ]]; then
    # shellcheck disable=SC2034  # tmux_agent writes the checked existence output.
    local identity='' identity_rc=0 saved_identity agent_rc=0 exists=false caller_session='' pane_pid=''
    identity=$(task_tmux_identity "$session") || identity_rc=$?
    [[ $identity_rc != 2 ]] || die 'cannot identify pending tmux cleanup; kept the session'
    saved_identity=$(jq -c '.tmux_identity // null' <<<"$WT_TEARDOWN_JSON")
    if [[ $identity_rc == 0 ]]; then
      [[ $(jq -cS . <<<"$identity") == $(jq -cS . <<<"$saved_identity") ]] || die 'tmux session identity changed; kept the replacement session'
    fi
    if [[ ${defer_close:-0} == 1 ]]; then
      if [[ $identity_rc == 0 ]]; then
        tmux_recorded_owner "$session" "$name" "$(jq -c .tmux_owner <<<"$WT_TEARDOWN_JSON")" \
          || die 'recorded owner validation blocks deferred cleanup'
      fi
      printf 'Git cleanup complete; Mac controller must finish session cleanup\n'
      return 0
    fi
    if [[ ${row_closed:-0} == 1 ]]; then
      if [[ $identity_rc == 0 ]]; then
        tmux_recorded_owner "$session" "$name" "$(jq -c .tmux_owner <<<"$WT_TEARDOWN_JSON")" \
          || die 'another agent or command blocks recorded session cleanup'
        tmux kill-session -t "$(jq -r .id <<<"$identity")" || die 'could not stop the recorded tmux session'
        identity_rc=0; identity=$(task_tmux_identity "$session") || identity_rc=$?
        [[ $identity_rc == 1 ]] || die 'tmux session absence is unverified'
      fi
    else
      if [[ -n ${TMUX:-} && ${TMUX_PANE:-} =~ ^%[0-9]+$ ]]; then
        caller_session=$(tmux display-message -p -t "$TMUX_PANE" '#S') || return 1
        pane_pid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}') || return 1
      fi
      if [[ $identity_rc == 0 && $caller_session == "$session" ]] && process_descends "$BASHPID" "$pane_pid"; then
        tmux_self_ownership "$session" "$name" || die 'session ownership changed; cleanup remains pending'
        if [[ $(jq -r '.mode // "agent"' <<<"$WT_TMUX_OWNER") == shell ]]; then
          local saved_owner saved_shell saved_start
          saved_owner=$(jq -c .tmux_owner <<<"$WT_TEARDOWN_JSON")
          saved_shell=$(jq -r .pid <<<"$WT_TMUX_OWNER"); saved_start=$(jq -r .start <<<"$WT_TMUX_OWNER")
          jq -e --arg pid "$saved_shell" --arg start "$saved_start" \
            '(.pid == $pid and .start == $start) or any(.ancestors[]; .pid == $pid and .start == $start)' \
            <<<"$saved_owner" >/dev/null || die 'recorded task shell changed; cleanup remains pending'
          WT_TEARDOWN_JSON=$(jq -c --argjson owner "$WT_TMUX_OWNER" '.tmux_owner=$owner' <<<"$WT_TEARDOWN_JSON")
          teardown_save close_requested
        else
          [[ $(jq -c '[.pid,.start]' <<<"$WT_TMUX_OWNER") == "$(jq -c '.tmux_owner | [.pid,.start]' <<<"$WT_TEARDOWN_JSON")" ]] \
            || die 'recorded task provider changed; cleanup remains pending'
        fi
        teardown_commands_capture "$(jq -r .pid <<<"$WT_TMUX_OWNER")" "$(jq -r .start <<<"$WT_TMUX_OWNER")" \
          || die 'task command cancellation is incomplete; session cleanup remains pending'
        if [[ $native == 1 ]]; then
          tmux kill-session -t "$(jq -r .id <<<"$identity")" || rc=$?
        elif notify_mac wt-close host "$host" repo "$REPO" task "$name"; then
          local i wait_seconds=${WT_CLOSE_WAIT_SECONDS:-22}
          [[ $wait_seconds =~ ^[0-9]+$ ]] || wait_seconds=22
          for ((i=0; i<wait_seconds; i++)); do sleep 1; done
          rc=1
        else rc=1; fi
      else rc=1; fi
      if [[ $rc == 0 && $native == 1 ]]; then
        # A surviving caller cannot independently confirm that its Mac terminal closed.
        rc=1
      fi
    fi
  elif [[ -n $row ]]; then
    local checked_row='' checked_self=''
    check_row_removal "$title" "$REPO" checked_row checked_self '' "$path" || die "$CMUX_ERROR; cleanup remains pending in $WT_TEARDOWN_FILE"
    # A reused title must never redirect a saved cleanup operation.
    [[ -z $checked_row || $checked_row == "$row" ]] || die 'task row identity changed; cleanup remains pending'
    local existing_rows
    existing_rows=$(rows_json checked) || die 'cannot verify saved row absence; cleanup remains pending'
    if [[ -z $checked_row ]] && jq -e --arg id "$row" 'any(.workspaces[]; .id == $id)' <<<"$existing_rows" >/dev/null; then
      die 'saved row still exists with changed identity; cleanup remains pending'
    fi
    if [[ -n $checked_row ]]; then
      if [[ $checked_self == self ]]; then
        teardown_commands_capture "$ROW_AGENT_PID" "$ROW_AGENT_START" "$ROW_AGENT_OBSERVERS" \
          || die 'task command cancellation is incomplete; row cleanup remains pending'
      fi
      close_row "$row" "$checked_self" || { warn "$CMUX_ERROR"; rc=1; }
      if [[ $rc == 0 ]]; then
        local rows
        rows=$(rows_json checked) || rc=1
        if [[ $rc == 0 ]] && jq -e --arg id "$row" 'any(.workspaces[]; .id == $id)' <<<"$rows" >/dev/null; then rc=1; fi
      fi
    fi
  fi
  if [[ $rc != 0 ]]; then
    if [[ $remote == 1 ]]; then
      warn 'Git cleanup completed; Mac row or tmux session closure is unverified; cleanup is pending'
      warn "on the Mac: wt -H $host rm $name -r $(shell_join "$REPO")"
    else
      warn "Git cleanup completed; session cleanup is pending. Retry: wt rm $name -r $(shell_join "$REPO")"
    fi
    warn "receipt: $WT_TEARDOWN_FILE"
    return 1
  fi
  teardown_commands_stop all || die 'Git and row cleanup completed, but task command cleanup remains pending'
  teardown_commands_observe || die 'task runtime or command absence is unverified; cleanup remains pending'
  teardown_observe "$name" "$path" "$branch" "$keep" "$row" "$remote" "$row_closed" "$observe_only" || die 'cleanup absence cannot be verified'
  printf 'teardown complete %s\n' "$name"
}

# Inputs: observe-only, row-closed, defer-close, and row-host flags; WT_TEARDOWN_JSON supplies recorded identity and stage.
# Outputs: completion or pending status. Mutations: run only the remaining named receipt stages.
# cmd_rm owns initial removal; this continuation also dispatches interrupted cleanup from its recorded stage.
teardown_finish() {
  local observe_only=${1:-0} row_closed=${2:-0} defer_close=${3:-0} row_host=${4:-}
  local name path branch head keep row remote stage
  name=$(jq -r .name <<<"$WT_TEARDOWN_JSON"); path=$(jq -r .path <<<"$WT_TEARDOWN_JSON")
  branch=$(jq -r .branch <<<"$WT_TEARDOWN_JSON"); head=$(jq -r .head <<<"$WT_TEARDOWN_JSON")
  keep=$(jq -r .keep <<<"$WT_TEARDOWN_JSON"); stage=$(jq -r .stage <<<"$WT_TEARDOWN_JSON")
  row=$(jq -r .row <<<"$WT_TEARDOWN_JSON"); remote=$(jq -r .remote <<<"$WT_TEARDOWN_JSON")
  teardown_row_context "$row_closed" "$row_host" || die 'Mac row host is unverified or changed; use the original SSH alias for confirmation'
  if [[ ${observe_only:-0} == 1 ]]; then
    teardown_observe "$name" "$path" "$branch" "$keep" "$row" "$remote" "$row_closed" "$observe_only" || die 'cleanup absence cannot be verified'
    return 0
  fi
  if [[ ${row_closed:-0} == 1 && $remote != 1 ]]; then die 'row acknowledgment is only valid for VM cleanup'; fi
  if [[ $stage == complete ]]; then
    teardown_observe "$name" "$path" "$branch" "$keep" "$row" "$remote" "$row_closed" "$observe_only" || die 'cleanup absence cannot be verified'
    printf 'teardown complete %s\n' "$name"; return 0
  fi
  task_admin_preserved "$path" || die 'private submodule Git data prevents cleanup; kept the task registration'
  if [[ $stage == prepared ]]; then
    # An interrupted removal may have deleted the directory before updating its receipt.
    [[ ! -e $path ]] || die "teardown is prepared but the worktree remains; rerun normal removal"
    teardown_remove_registration "$path" || die 'could not remove the recorded task registration'
  fi
  if [[ $stage == prepared || $stage == worktree_removed ]]; then
    teardown_stage_branch "$name" "$branch" "$head" "$keep"
    stage=branch_config_removing
  fi
  if [[ $stage == branch_config_removing ]]; then
    teardown_stage_config "$name" "$branch" "$keep"
    stage=sidecars_removing
  fi
  if [[ $stage == sidecars_removing ]]; then
    teardown_stage_sidecars "$name" "$path" "$branch" "$keep"
  fi
  teardown_stage_close "$name" "$path" "$branch" "$keep" "$row" "$remote" "$row_closed" "$defer_close" "$observe_only"
}
