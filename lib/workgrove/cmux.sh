# shellcheck shell=bash
# Reads globals: CMUX_BUNDLED_CLI_PATH, CMUX_ROWS, CMUX_ROWS_FULL, CMUX_ROWS_JSON, CMUX_RUN,
#   CMUX_WORKSPACE_ID, DEADLINE, HOME, REPO, ROW_AGENT, ROW_JQ, ROW_SEP, WS_JSON, WS_RC, WT_FS.
# Requires common.sh: relay_env, repo_id, shell_join, tmux_cmd, wg_sleep.
# Requires task.sh: meta_set, path_within, physical_dir, row_tag, task_title, wt_path.
# The shared adapter owns cmux commands and row identity queries.
# CMUX_ERROR holds a diagnostic; callers choose whether to stop or log it.
# Callers read the exported diagnostics and creation state.
# shellcheck disable=SC2034
CMUX_ERROR="" CMUX_ROW_EXISTING="" CMUX_ROW_ID=""
CMUX_RUN=()

cmux_error() { CMUX_ERROR=$*; return 1; }

cmux_bin() {
  local c="${CMUX_BUNDLED_CLI_PATH:-}"
  [[ -x "$c" ]] || c=$(command -v cmux 2>/dev/null || true)
  [[ -x "$c" ]] || c="$HOME/.cmux/bin/cmux"                        # cmux uploads its CLI here on a VM
  [[ -x "$c" ]] || c=/Applications/cmux.app/Contents/Resources/bin/cmux
  [[ -x "$c" ]] && printf '%s' "$c"
}
cmux_ok() { cmux_call ping >/dev/null 2>&1; }

# The hook sets CMUX_RUN to its capped runner. Other callers use the quiet CLI.
cmux_call() {
  local c rc=0
  if ((${#CMUX_RUN[@]} == 0)); then
    c=$(cmux_bin) || { cmux_error "cmux CLI not found"; return 1; }
    CMUX_RUN=(env CMUX_QUIET=1 "$c")
  fi
  "${CMUX_RUN[@]}" "$@" || rc=$?
  if ((rc != 0)); then CMUX_ERROR="cmux $* failed (exit $rc)"; fi
  return "$rc"
}

cmux_ref() { grep -oE 'workspace:[0-9]+' | head -1 || true; }
cmux_select() { cmux_call workspace select "$1" >/dev/null 2>&1 || cmux_error "cmux workspace select failed for $1"; }
cmux_screen() { cmux_call read-screen --workspace "$1"; }
cmux_create() { cmux_call workspace create "$@"; }
cmux_diff() { cmux_call diff "$@"; }
cmux_notifications() { cmux_call --json list-notifications; }
cmux_dismiss() { cmux_call dismiss-notification --id "$1"; }

# rows_json [checked] prints all cmux rows as one {"workspaces":[…]} document.
rows_json() {
  cmux_rows_load "${1:-skip}" || return
  printf '%s\n' "$CMUX_ROWS_JSON"
}

# cmux_row_field <title> <repo> <field> [host] [policy] prints a matching field.
# The repo can be a path, a name, or empty. An omitted host selects a local row.
cmux_row_field() {
  cmux_bin >/dev/null || { [[ ${5:-} != checked ]]; return; }
  local rows repo=''
  if [[ -n $2 ]]; then repo=$(repo_id "$2"); fi
  rows=$(rows_json "${5:-skip}") || return
  printf '%s' "$rows" | cmux_find_row "$1" "$repo" "$3" "${4:-}" || true
}

row_label() { # row_label <title> <repo> [host] — the matching row as the sidebar shows it. An older wt's row
  # keeps its old title, so this reads the row's own title and description. A row that is gone by then
  # reads as the label that wt would give it.
  local t d
  t=$(cmux_row_field "$1" "$2" title "${3:-}")
  if [[ -z "$t" ]]; then printf '%s %s' "$1" "$(row_tag "${3:-}" "$2")"; return 0; fi
  d=$(cmux_row_field "$1" "$2" description "${3:-}")
  printf '%s%s' "$t" "${d:+ $d}"
}

open_workspace() { # open_workspace <name> — always unfocused: a new task row must never steal the window
  local n="$1" out title                 # from whatever the user is doing; they select it when they want it
  cmux_ok || { CMUX_ERROR="cmux is not running; skipped workspace creation (cd $(wt_path "$n"))"; return 0; }
  title=$(task_title "$n")
  # shellcheck disable=SC2153
  out=$(cmux_create --name "$title" --description "$(row_tag "" "$REPO")" --cwd "$(wt_path "$n")" --focus false \
        --command "$(shell_join "$HOME/.local/bin/wt" run "$n" -r "$REPO")" 2>&1) || { cmux_error "cmux workspace create failed: $out"; return 1; }
  local ref; ref=$(printf '%s' "$out" | cmux_ref)
  meta_set "$n" "title=$title"
  printf 'workspace: %s\n' "${ref:-$out}"
}

close_workspace() { # close_workspace <name> [title] — use the saved title after rm deletes the sidecar
  local title="${2:-}"
  [[ -n "$title" ]] || title=$(task_title "$1")
  cmux_ok || { CMUX_ERROR="cmux is unreachable; skipped row cleanup for $title $(row_tag "" "$REPO") (titled $(repo_id "$REPO"):$1 if an older wt made it)"; return 0; }
  close_row "$(cmux_row_field "$title" "$REPO" id)"
}

close_row() { # close_row <row id> [self|new] — silent when the row is already gone
  # cmux asks for --force before it closes a row in which a local agent runs, such as the caller's own row
  # ("self"). "new" is a VM row that wt has just created. cmux 0.65 closes such a row without --force, as
  # measured on a VM. wt passes --force anyway, as the hook does, because the row runs only what wt started.
  [[ -n "$1" ]] || return 0
  local err args=()
  [[ ${2:-} == self || ${2:-} == new ]] && args=(--force)
  err=$(cmux_call workspace close "$1" "${args[@]}" 2>&1) || {
    CMUX_ERROR="could not close cmux row $1${err:+: $err}"$'\n'"on the Mac: cmux workspace close $1${args[*]:+ ${args[*]}}"
    return 1
  }
}

check_row_removal() { # check_row_removal <title> <repo> <row output> <self output> [host] [worktree path]
  # Refuse unreadable rows or another running agent. Without a host, the path names the local worktree.
  local -n __rm_row=$3 __rm_self=$4
  __rm_row=""; __rm_self=""
  local __err
  if ! cmux_bin >/dev/null; then
    [[ -z ${CMUX_WORKSPACE_ID:-} ]] || { cmux_error "cmux CLI not found; kept the worktree"; return 1; }
    return 0
  fi
  if ! __err=$(cmux_call ping 2>&1); then
    # Without a caller row, a missing socket means cmux is absent. Other failures cannot prove that.
    case "$__err" in 'Error: Socket not found at '*) [[ -n ${CMUX_WORKSPACE_ID:-} ]] || return 0 ;; esac
    cmux_error "cannot reach cmux${__err:+: $__err}; kept the worktree"; return 1
  fi
  # The user can edit or clear a row's description in cmux, and then task_row no longer finds the task's row.
  # So check the agent in every row that may be this task's, not only in the row that task_row finds:
  # - by title: each row that task_row finds ("found"), and each row that unclaimed_row finds ("unclaimed");
  # - by directory: each local row whose current directory is in the worktree ("dir").
  # Refuse when another agent runs in any of them. Close only the first row that task_row finds, or the
  # caller's own row when the title matches it. A row found only by its directory may belong to anything,
  # such as the driver, so wt never closes it.
  local __rows __checks=() __check __kind __id __dir __root="" __self_row=""
  __rows=$(rows_json checked) || { cmux_error "cannot list cmux rows; kept the worktree"; return 1; }
  # One line for each row to check: "found <id>", "unclaimed <id>" or "dir <id> <current directory>". A
  # directory with a newline in it would split its line, so such a row is not checked by its directory.
  mapfile -t __checks < <(printf '%s' "$__rows" | jq -r --arg t "$1" --arg r "$(if [[ -n "$2" ]]; then repo_id "$2"; fi)" \
      --arg h "${5:-}" --arg d "${6:-}" --arg sep "$ROW_SEP" "$ROW_JQ"'
      .workspaces[] | (.current_directory | if type == "string" then . else "" end) as $c
      | if task_row($t; $r; $h; $sep) then "found " + .id
        elif unclaimed_row($t; $h; $sep) then "unclaimed " + .id
        elif $h == "" and $d != "" and on_host($h; $sep) and $c != "" and ($c | contains("\n") | not)
        then "dir " + .id + " " + $c
        else empty end')
  wait $! || { cmux_error "cannot list cmux rows; kept the worktree"; return 1; }
  # A row's directory can name the worktree through a symlink or in another letter case. So a directory that
  # does not match as written is compared again as its physical path.
  if [[ -n "${6:-}" ]]; then __root=$(physical_dir "$6"); fi
  for __check in "${__checks[@]}"; do
    __kind=${__check%% *}; __id=${__check#* }
    if [[ $__kind == dir ]]; then
      __dir=${__id#* }; __id=${__id%% *}
      path_within "$__dir" "${6:-}" || path_within "$(physical_dir "$__dir")" "$__root" || continue
    fi
    [[ $__kind != found || -n "$__rm_row" ]] || __rm_row=$__id
    row_agent "$__id" || return
    case $__kind/$ROW_AGENT in
      found/self|unclaimed/self) __self_row=$__id ;;
      found/busy) cmux_error "another agent is running in cmux row $__id; kept the worktree"; return 1 ;;
      unclaimed/busy) cmux_error "an agent is running in cmux row $__id, titled '$1', whose second line wt did not write; kept the worktree. Stop that agent or close that row, then re-run"; return 1 ;;
      dir/busy) cmux_error "an agent is running in cmux row $__id, whose current directory is in this worktree; kept the worktree. Stop that agent or close that row, then re-run"; return 1 ;;
    esac
  done
  if [[ -n "$__self_row" ]]; then __rm_row=$__self_row; __rm_self=self; fi
}

row_agent() { # row_agent <row id> — sets ROW_AGENT: "self" for the caller's own row, "busy" when an agent
  # runs in the row, else "idle". A failed check returns a diagnostic in CMUX_ERROR.
  local state
  state=$(cmux_call top --workspace "$1" --json 2>/dev/null) \
    || { cmux_error "cannot check the agent in cmux row $1; kept the worktree"; return 1; }
  printf '%s' "$state" | jq -e '.coding_agents | type == "array"
    and all(.[]; .resources.process_count | type == "number" and . >= 0)' >/dev/null 2>&1 \
    || { cmux_error "cannot check the agent in cmux row $1; kept the worktree"; return 1; }
  if printf '%s' "$state" | jq -e --arg id "$1" '.caller.workspace_id == $id' >/dev/null; then
    ROW_AGENT=self
  elif printf '%s' "$state" | jq -e 'any(.coding_agents[]; .resources.process_count > 0)' >/dev/null; then
    ROW_AGENT=busy
  else
    ROW_AGENT=idle
  fi
}

# cmux_rows_load <skip|stop|checked> [command...] sets CMUX_ROWS_JSON and CMUX_ROWS_FULL.
# CMUX_RUN wraps each CLI call. Tests can supply a runner directly.
# skip ignores windows that close during enumeration. stop returns the first failing call's status.
# checked requires readable window lists and validates every row before removal can trust the result.
# CMUX_ROWS_FULL is 1 only when every window has a UUID and returns nonblank output.
# workspace list covers one window. Window UUIDs stay fixed when cmux changes window indices.
# shellcheck disable=SC2034
cmux_rows_load() {
  local policy=$1 windows window out docs='' rc=0 window_ids=() runner=(cmux_call)
  shift
  (($# == 0)) || runner=("$@")
  CMUX_ROWS_JSON='' CMUX_ROWS_FULL=1
  windows=$("${runner[@]}" --json list-windows 2>/dev/null) || {
    CMUX_ROWS_FULL=0
    [[ $policy != checked ]] || { cmux_error "cannot list cmux windows"; return 1; }
    [[ $policy != stop ]] || windows=''
  }
  if ! windows=$(printf '%s' "$windows" | jq -ec '
    if type == "array" and all(.[]; .id | type == "string" and test("^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"))
    then . else error("invalid cmux window list") end' 2>/dev/null); then
    CMUX_ROWS_FULL=0
    [[ $policy != checked ]] || { cmux_error "cannot list cmux windows"; return 1; }
    windows='[]'
  fi
  mapfile -t window_ids < <(printf '%s' "$windows" | jq -r '.[].id')
  for window in "${window_ids[@]}"; do
    out=$("${runner[@]}" workspace list --json --window "$window" 2>/dev/null) || {
      rc=$?
      CMUX_ROWS_FULL=0
      [[ $policy == skip ]] || { CMUX_ERROR="cannot list cmux rows (exit $rc)"; return "$rc"; }
      continue
    }
    if [[ -z ${out//[[:space:]]/} ]]; then
      CMUX_ROWS_FULL=0
      [[ $policy != checked ]] || { cmux_error "cannot list cmux windows"; return 1; }
    fi
    docs="$docs$out"
  done
  if [[ -z $docs ]]; then
    docs=$("${runner[@]}" workspace list --json 2>/dev/null) || {
      rc=$?
      CMUX_ROWS_FULL=0
      [[ $policy == skip ]] || { CMUX_ERROR="cannot list cmux rows (exit $rc)"; return "$rc"; }
    }
  fi
  if [[ $policy == checked ]]; then
    CMUX_ROWS_JSON=$(printf '%s' "$docs" | jq -e -s -c '
      map(if type == "array" then . elif type == "object" then .workspaces else null end) as $rows
      | if ($rows | length > 0) and all($rows[]; type == "array"
          and all(.[]; (.id | type == "string" and length > 0) and (.title | type == "string")
            and (.remote == null or (.remote | type == "object"))
            and (.remote.enabled == null or (.remote.enabled | type == "boolean"))
            and (.remote.destination == null or (.remote.destination | type == "string"))
            and (.description == null or (.description | type == "string"))))
        then {workspaces: ($rows | add)} else error("invalid cmux row list") end' 2>/dev/null) || { rc=$?; CMUX_ERROR="invalid cmux row list"; return "$rc"; }
    return
  fi
  CMUX_ROWS_JSON=$(printf '%s' "$docs" | jq -s -c '{workspaces: (map(.workspaces? // .) | add // [])}' 2>/dev/null) || {
    [[ $policy == skip ]] && return 0
    cmux_error "invalid cmux row list"
    return 1
  }
}

# A host alias and repo_id cannot contain this separator: space, U+00B7 MIDDLE DOT, space.
ROW_SEP=' · '
# An empty host selects local rows. Other hosts require an SSH row with a matching destination or description.
# task_row accepts both current titles and the <repo>:<name> titles from older wt versions, regardless of their descriptions.
# An empty repo ID matches a row with no repo.
# new_row finds a created row when cmux ssh prints no ref. It excludes known IDs and descriptions with a repo.
# unclaimed_row finds descriptions that wt does not write. wt rm checks these rows for agents because users can edit descriptions.
# shellcheck disable=SC2016
ROW_JQ='
  def desc($sep): (.description | if type == "string" then . else "" end) | split($sep);
  def on_host($h; $sep): if $h == "" then ((.remote.enabled // false) | not)
    else ((.remote.enabled // false) and ((.remote.destination // "") == $h or (desc($sep)[0] // "") == "@" + $h)) end;
  def task_row($t; $r; $h; $sep): on_host($h; $sep)
    and ((.title == $t and (desc($sep)[1:] | join($sep)) == $r) or ($r != "" and .title == $r + ":" + $t));
  def new_row($t; $h; $ids; $sep): .title == $t and on_host($h; $sep) and (desc($sep) | length < 2)
    and (.id as $i | all($ids[]; . != $i));
  def unclaimed_row($t; $h; $sep): .title == $t and on_host($h; $sep)
    and ((.description | if type == "string" then . else "" end) | test("^@[^ ]+(" + $sep + "[A-Za-z0-9-]+)?$") | not);
'

# cmux_find_row <title> <repo id> <field> [host] reads a row list from stdin.
# It prints the first matching field, or nothing with a nonzero status when no row matches.
cmux_find_row() {
  jq -er --arg t "$1" --arg r "$2" --arg k "$3" --arg h "${4:-}" --arg sep "$ROW_SEP" "$ROW_JQ"'
    first((.workspaces? // .)[] | select(task_row($t; $r; $h; $sep)) | .[$k] // "") // empty' 2>/dev/null
}

row_remote_field() { # row_remote_field <id> <field>… — this row's current remote fields (such as state) from one
                     # rows_json read, joined by $WT_FS. Never a tab: read would collapse it when a field is empty.
  local id="$1"; shift
  rows_json | jq -r --arg id "$id" --arg fs "$WT_FS" \
    'first((.workspaces? // .)[] | select(.id == $id) | .remote as $r
       | [$ARGS.positional[] as $k | ($r[$k] // "") | tostring] | join($fs)) // empty' --args "$@" 2>/dev/null || true
}

row_shell_prompt() { # row_shell_prompt <id> <last line output>
  # Return 0 when the last nonblank line is a shell prompt that names user@host.
  # Accept a lone $, #, or % below a line that names user@host for two-line prompts.
  # A prompt must end in $, #, or %. A TUI footer such as `Context 100%` names no user@host.
  # Return 2 when the screen is unavailable.
  local -n __shell_last=$2
  local __id="$1" __screen __lines __above="" __nl=$'\n' __who='[[:alnum:]_.-]+@[[:alnum:]_.-]+' __end='[$#%]$' __bare='^[$#%]$'
  __shell_last=""
  __screen=$(cmux_call read-screen --workspace "$__id" 2>/dev/null) || return 2
  __lines=$(printf '%s\n' "$__screen" | sed -e 's/[[:space:]]*$//' -e '/^$/d' | tail -2)
  __shell_last=${__lines##*"$__nl"}
  [[ "$__lines" != *"$__nl"* ]] || __above=${__lines%%"$__nl"*}
  [[ "$__shell_last" =~ $__end ]] || return 1
  [[ "$__shell_last" =~ $__who ]] || { [[ "$__shell_last" =~ $__bare && "$__above" =~ $__who ]]; }
}

send_tmux_line() { # send_tmux_line <id> <session> — type the row's tmux attach line into it and press return
  cmux_call send --workspace "$1" "$(tmux_cmd "$2")" >/dev/null 2>&1 \
    || { cmux_error "cmux send failed for $1; type this in the row instead: tmux attach -d -t '=$2'"; return 1; }
  cmux_call send-key --workspace "$1" enter >/dev/null 2>&1 \
    || { cmux_error "cmux send-key failed for $1; press return in the row to finish the attach"; return 1; }
}

WS_JSON=""; WS_RC=""
# ws_load [fresh] caches all rows in WS_JSON and the list status in WS_RC. fresh resets the cache.
# A failed list must not look like an absent row: attach_row could create a duplicate.
ws_load() {
  [[ ${1:-} == fresh ]] && WS_RC=""
  [[ -n $WS_RC ]] && return "$WS_RC"
  WS_RC=0
  cmux_rows_load stop || WS_RC=$?
  if [[ $WS_RC -eq 0 ]]; then WS_JSON=$CMUX_ROWS_JSON; fi
  case $WS_RC in
    0) ;;
    142) CMUX_ERROR="the cmux row list hit the hook deadline (capped exit 142)" ;;
    *)   CMUX_ERROR="the cmux row list failed (exit $WS_RC)" ;;
  esac
  return "$WS_RC"; }
# row_by_title <title> <repo id> <host> prints the matching row ID from a successful snapshot.
row_by_title() {
  ws_load || return
  printf '%s' "$WS_JSON" | cmux_find_row "$1" "$2" id "$3"; }
from_row_on_host() { # from_row_on_host <workspace uuid> <host> — the notifying row is an SSH row to that host.
  # The native automation event supplies the row ID. Check that row's SSH destination against the request.
  # This runs in the caller's shell, not a subshell, so attach_row then uses the snapshot that this loads.
  [[ -n $1 ]] || return 1
  ws_load || return 1
  printf '%s' "$WS_JSON" \
    | jq -e --arg w "$1" --arg h "$2" 'any((.workspaces? // .)[]; .id == $w and .remote.enabled and (.remote.destination // "") == $h)' >/dev/null 2>&1; }

cmux_notify() {
  local title=$1 body=$2 c request_id
  local relay_tui_socket relay_tui_terminal relay_ident=()
  relay_env relay_ident relay_tui_socket relay_tui_terminal || { cmux_error "no cmux relay socket in this session; run the line below on the Mac"; return 1; }
  if [[ $relay_tui_socket == /* && $relay_tui_terminal =~ ^term_[a-f0-9]{32}$ ]]; then
    c=$(command -v cmux-tui || true)
    [[ -x $c ]] || { cmux_error "cmux-tui CLI not found here; run the line below on the Mac"; return 1; }
    # cmux suppresses identical terminal/title/body content for five seconds, regardless of notification ID.
    request_id=$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [[ $request_id =~ ^[a-f0-9]{32}$ ]] || { cmux_error "cannot create a native request ID; run the line below on the Mac"; return 1; }
    body=$(printf '%s' "$body" | jq -c --arg id "$request_id" '. + {request_id:$id}') || return 1
    # Native terminal IDs differ from the Mac's workspace UUIDs. Do not pass --workspace.
    env -u CMUX_SOCKET "${relay_ident[@]}" "$c" --socket "$relay_tui_socket" notify --surface "$relay_tui_terminal" --title "$title" --body "$body" >/dev/null 2>&1 \
      || { cmux_error "cmux-tui notify failed; run the line below on the Mac"; return 1; }
    return 0
  fi
}

# cmux_row_create_ssh <host> <title> <description> <command> [--no-focus]
# The caller must provide a complete CMUX_ROWS_JSON snapshot from before creation.
cmux_row_create_ssh() {
  local host=$1 title=$2 description=$3 command=$4 out ref before; shift 4
  [[ ${CMUX_ROWS_FULL:-0} == 1 ]] || { cmux_error "cannot create an SSH row without a complete row list"; return 1; }
  before=$(printf '%s' "$CMUX_ROWS_JSON" | jq -r '.workspaces[].id') || return 1
  out=$(cmux_call ssh "$host" --name "$title" "$@" --command "$command" 2>&1) || {
    cmux_error "cmux ssh failed: $out"; return 1;
  }
  ref=$(printf '%s' "$out" | cmux_ref)
  if [[ -z $ref ]]; then
    # Measured: the row list lags about one second behind creation without a workspace:N ref.
    # Use the hook's single lookup, so both callers report a missing row after the same wait.
    wg_sleep
    if cmux_rows_load checked; then
      ref=$(printf '%s' "$CMUX_ROWS_JSON" | jq -r --arg t "$title" --arg h "$host" --arg before "$before" --arg sep "$ROW_SEP" "$ROW_JQ"'
        first(.workspaces[] | select(new_row($t; $h; $before | split("\n"); $sep)) | .id // empty) // empty' 2>/dev/null)
    fi
  fi
  [[ -n $ref ]] || {
    cmux_error "cmux reported no row for $title on $host: $out; if a new row $title with no repo on its second line is open, close it"
    return 1;
  }
  cmux_call workspace-action --workspace "$ref" --action set-description --description "$description" >/dev/null 2>&1 && return 0
  # The second line identifies the repo. Close an untagged new row to prevent duplicate rows on the next attach.
  # Keep the hook's three-second cleanup allowance when set-description exhausts its deadline.
  if DEADLINE=$(( ${DEADLINE:-0} + 3 )) close_row "$ref" new; then
    cmux_error "set-description $description failed for the new row $ref, so it was closed"
  else
    cmux_error "set-description $description failed for the new row $ref, and closing it failed: close it in cmux"
  fi
  return 1
}

# cmux_row_open_ssh shares existing-row selection and new-row creation between wt and the hook.
# CMUX_ROW_ID identifies the existing row when CMUX_ROW_EXISTING is set.
# CMUX_ERROR can hold a nonfatal description diagnostic.
cmux_row_open_ssh() {
  local host=$1 title=$2 description=$3 command=$4 repo ref; shift 4
  CMUX_ROW_EXISTING='' CMUX_ROW_ID='' CMUX_ERROR=''
  # Use the hook's fail-closed policy: a failed window list cannot prove that this row is absent.
  cmux_rows_load checked || { cmux_error "cannot list cmux rows; not creating a row on a lookup that failed"; return 1; }
  repo=${description#*"$ROW_SEP"}; [[ $description == *"$ROW_SEP"* ]] || repo=''
  ref=$(printf '%s' "$CMUX_ROWS_JSON" | cmux_find_row "$title" "$repo" id "$host") || true
  if [[ -z $ref ]]; then
    cmux_row_create_ssh "$host" "$title" "$description" "$command" "$@"
    return
  fi
  # shellcheck disable=SC2034
  CMUX_ROW_EXISTING=1 CMUX_ROW_ID=$ref
  case " $* " in *' --no-focus '*) ;; *) cmux_select "$ref" || return ;; esac
  cmux_call workspace-action --workspace "$ref" --action set-description --description "$description" >/dev/null 2>&1 && return 0
  # Use the hook's nonfatal policy: the existing row already has its identity, so a failed rewrite changes nothing.
  # shellcheck disable=SC2034
  CMUX_ERROR="set-description $description failed for $ref"
  return 0
}
