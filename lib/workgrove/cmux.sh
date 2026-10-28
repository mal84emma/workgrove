# shellcheck shell=bash
# Reads globals: CMUX_BUNDLED_CLI_PATH, CMUX_ROWS, CMUX_ROWS_FULL, CMUX_ROWS_JSON, CMUX_RUN,
#   CMUX_WORKSPACE_ID, CMUX_SAMPLE_RETRY, DEADLINE, HOME, REPO, ROW_AGENT, ROW_JQ, ROW_SEP, WS_JSON, WS_RC, WT_FS.
# The shared adapter owns cmux commands and row identity queries.
# CMUX_ERROR holds a diagnostic; callers choose whether to stop or log it.
# Callers read the exported diagnostics and creation state.
# shellcheck disable=SC2034
CMUX_ERROR="" CMUX_ROW_EXISTING="" CMUX_ROW_ID=""
# Only one cmux release is verified at a time.
WG_CMUX_SUPPORTED=0.65.1
CMUX_RUN=()

cmux_error() { CMUX_ERROR=$*; return 1; }

# Resolve the helper that wt run saves before it installs the task's hook wrapper.
cmux_tui_agent_helper() {
  local helper=${CMUX_TUI_HOOK:-}
  case $helper in */lib/workgrove/cmux-tui-hook.sh) helper=${WT_CMUX_TUI_HOOK:-} ;; esac
  case $helper in
    ''|*/lib/workgrove/cmux-tui-hook.sh) helper=${XDG_DATA_HOME:-$HOME/.local/share}/cmux-tui/bin/cmux-tui-hook ;;
  esac
  printf '%s' "$helper"
}

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

cmux_ref() { grep -oE 'workspace:[0-9]+' | sed -n '1p' || true; }
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
        --command "$(local_run_line "$HOME/.local/bin/wt" "$n" "$REPO")" 2>&1) || { cmux_error "cmux workspace create failed: $out"; return 1; }
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
    # Killing a VM session can close its row before this request reaches cmux.
    [[ $err == 'Error: not_found: Workspace not found' ]] && return 0
    CMUX_ERROR="could not close cmux row $1${err:+: $err}"$'\n'"on the Mac: cmux workspace close $1${args[*]:+ ${args[*]}}"
    return 1
  }
}

remote_row_idle() { # Forced relay closure requires a complete sample containing only the SSH transport tree.
  local row=$1 state pids pid root='' command start
  state=$(cmux_call top --workspace "$row" --json) || { cmux_error 'cannot inspect relay row processes; kept the row'; return 1; }
  jq -e --arg row "$row" '
    [.windows[].workspaces[] | select(.id == $row)] as $rows
    | ($rows | length) == 1 and ($rows[0].resources as $r
      | ($r.pids | type == "array") and ($r.pids | length) == $r.process_count
      and all($r.pids[]; type == "number" and . > 1 and floor == .)
      and ($r.pids | unique | length) == ($r.pids | length)
      and (($r.missing_pids // []) | type == "array" and length == 0))
    and (.coding_agents | type == "array")
    and all(.coding_agents[]; (.resources as $r
      | ($r.pids | type == "array") and ($r.pids | length) == $r.process_count
      and all($r.pids[]; type == "number" and . > 1 and floor == .)
      and ($r.pids | unique | length) == ($r.pids | length)))
    and ([$rows[0].resources.pids[]] as $pids
      | all(.coding_agents[].resources.pids[]; . as $pid | $pids | index($pid) == null))' <<<"$state" >/dev/null \
    || { cmux_error 'relay row agent ownership is busy or unknown; kept the row'; return 1; }
  local extras
  extras=$(cmux_extra_row_pids "$state" "$row") || { cmux_error 'relay row attribution is uncertain; kept the row'; return 1; }
  [[ -z $extras ]] || { cmux_error 'relay row attribution is uncertain; kept the row'; return 1; }
  pids=$(jq -r --arg row "$row" '.windows[].workspaces[] | select(.id == $row) | .resources.pids[]' <<<"$state") || return 1
  [[ -n $pids ]] || return 0
  while IFS= read -r pid; do
    command=$(ps -p "$pid" -o comm=) || { cmux_error 'cannot inspect relay row process; kept the row'; return 1; }
    if [[ ${command##*/} == ssh ]]; then
      if [[ -z $root ]] || process_descends "$root" "$pid"; then root=$pid; fi
    fi
  done <<<"$pids"
  [[ -n $root ]] || { cmux_error 'cannot identify relay SSH transport; kept the row'; return 1; }
  start=$(LC_ALL=C ps -p "$root" -o lstart=) || return 1
  while IFS= read -r pid; do
    process_descends "$pid" "$root" || process_descends "$root" "$pid" \
      || { cmux_error 'independent command in relay row; kept the row'; return 1; }
  done <<<"$pids"
  [[ $(LC_ALL=C ps -p "$root" -o lstart=) == "$start" ]]
}

check_row_removal() { # check_row_removal <title> <repo> <row output> <self output> [host] [worktree path]
  # Refuse unreadable rows or another running agent. Without a host, the path names the local worktree.
  local -n __rm_row=$3 __rm_self=$4
  __rm_row=""; __rm_self=""
  ROW_AGENT_PID='' ROW_AGENT_START=''
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
  local __rows __checks=() __check __kind __id __dir __root="" __self_row="" __self_pid='' __self_start=''
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
    local __task_path=${6:-}
    row_agent "$__id" "${__task_path##*/}" || return
    case $__kind/$ROW_AGENT in
      found/self|unclaimed/self) __self_row=$__id; __self_pid=$ROW_AGENT_PID; __self_start=$ROW_AGENT_START ;;
      found/busy) cmux_error "another agent is running in cmux row $__id; kept the worktree${CMUX_ERROR:+; $CMUX_ERROR}"; return 1 ;;
      unclaimed/busy) cmux_error "an agent is running in cmux row $__id, titled '$1', whose second line wt did not write; kept the worktree. Stop that agent or close that row, then re-run"; return 1 ;;
      dir/busy) cmux_error "an agent is running in cmux row $__id, whose current directory is in this worktree; kept the worktree. Stop that agent or close that row, then re-run"; return 1 ;;
    esac
  done
  if [[ -n "$__self_row" ]]; then
    __rm_row=$__self_row; __rm_self=self
    ROW_AGENT_PID=$__self_pid ROW_AGENT_START=$__self_start
  else ROW_AGENT_PID='' ROW_AGENT_START=''; fi
}

process_descends() { # process_descends <pid> <ancestor>; unreadable ancestry never proves ownership.
  local pid=$1 ancestor=$2 parent steps=0
  [[ $pid =~ ^[0-9]+$ && $ancestor =~ ^[0-9]+$ ]] || return 1
  while ((pid > 1 && steps < 128)); do
    [[ $pid != "$ancestor" ]] || return 0
    parent=$(ps -p "$pid" -o ppid= 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
    [[ $parent =~ ^[0-9]+$ && $parent != "$pid" ]] || return 1
    pid=$parent; steps=$((steps + 1))
  done
  return 1
}

codex_owned_launch() { # Validate the task-owned launcher independently of inherited caller hints.
  local task=$1 row=$2 root=$3 record generation binding launcher start current agent=''
  [[ -n $task && -n ${REPO:-} ]] || return 1
  if [[ -f $(wt_meta "$task") ]]; then
    record=$(cat "$(wt_meta "$task")") || return 1
  elif [[ -n ${WT_TEARDOWN_JSON:-} ]]; then
    record=$WT_TEARDOWN_JSON
    [[ $(jq -r .name <<<"$record") == "$task" && $(jq -r .repo <<<"$record") == "$REPO" ]] || return 1
  else return 1; fi
  agent=$(jq -r '.agent // ""' <<<"$record") || return 1
  generation=$(jq -r '.generation // ""' <<<"$record") || return 1
  binding=$(jq -c '.runtime // {}' <<<"$record") || return 1
  jq -e --arg row "$row" --arg generation "$generation" '
    .provider == "codex" and .mode == "no-daemon" and .row == $row and .generation == $generation
    and ($generation | length > 0) and (.launcher_pid | type == "number" and . > 1)
    and (.launcher_start | type == "string" and length > 0)' <<<"$binding" >/dev/null || return 1
  [[ $agent == codex ]] || return 1
  launcher=$(jq -r .launcher_pid <<<"$binding"); start=$(jq -r .launcher_start <<<"$binding")
  current=$(LC_ALL=C ps -p "$launcher" -o lstart= 2>/dev/null) || return 1
  [[ $start == "$current" ]] || return 1
  if [[ ${4:-} != observer ]]; then process_descends "$BASHPID" "$launcher" || return 1; fi
  process_descends "$root" "$launcher"
}

process_vanished() { # Only a successful absence check can excuse an expired sampled child.
  local output rc=0
  output=$(LC_ALL=C ps -p "$1" -o pid= 2>&1) || rc=$?
  [[ $rc == 1 && -z $output ]]
}

sampled_process_descends() { # Validate the complete native sample before following a vanished child's parents.
  local state=$1 row=$2 pid=$3 root=$4 records child parent walk steps=0
  local -A parents=() visited=()
  records=$(printf '%s' "$state" | jq -er --arg row "$row" '
    select(.include_processes == true)
    | [.windows[].workspaces[] | select(.id == $row)] as $rows
    | select(($rows | length) == 1)
    | $rows[0] as $r
    | [$r.panes[].surfaces[].processes[] | recurse(.children[]?)] as $nodes
    | select(all($nodes[]; .kind == "process" and (.pid | type == "number" and . > 1 and floor == .)
      and (.ppid | type == "number" and . >= 0 and floor == .)))
    | select(($nodes | map(.pid) | unique | length) == ($nodes | length))
    | select(($nodes | map(.pid) | sort) == ($r.resources.pids | sort))
    | $nodes[] | "\(.pid) \(.ppid)"') || return 1
  while read -r child parent; do
    [[ $child =~ ^[0-9]+$ && $parent =~ ^[0-9]+$ ]] || return 1
    parents[$child]=$parent
  done <<<"$records"
  for child in "${!parents[@]}"; do
    visited=(); walk=$child; steps=0
    while [[ -n ${parents[$walk]-} ]]; do
      [[ -z ${visited[$walk]-} && $steps -lt 128 ]] || return 1
      visited[$walk]=1; walk=${parents[$walk]}; steps=$((steps + 1))
    done
  done
  visited=(); steps=0
  [[ -n ${parents[$pid]-} && -n ${parents[$root]-} ]] || return 1
  while ((pid > 1 && steps < 128)); do
    [[ $pid != "$root" ]] || return 0
    [[ -z ${visited[$pid]-} && -n ${parents[$pid]-} ]] || return 1
    visited[$pid]=1
    pid=${parents[$pid]}; steps=$((steps + 1))
  done
  return 1
}

codex_launch_row() { # Idle rows can lack process attribution before their first provider starts.
  local row=$1 launcher=$2 state=$3 start tty tree rows surface=${CMUX_SURFACE_ID:-}
  if jq -e --arg id "$row" --argjson pid "$launcher" '
      any(.windows[].workspaces[]; .id == $id and (.resources.pids | index($pid)) != null)' <<<"$state" >/dev/null; then return 0; fi
  [[ -n $surface ]] || return 1
  start=$(LC_ALL=C ps -p "$launcher" -o lstart=) || return 1
  [[ -n $start ]] || return 1
  tty=$(ps -p "$launcher" -o tty=) || return 1
  tty=${tty//[[:space:]]/}; tty=${tty#/dev/}
  [[ $tty =~ ^ttys[0-9]+$ ]] || return 1
  tree=$(cmux_call --id-format uuids tree --all --json) || return 1
  rows=$(jq -cer --arg row "$row" --arg surface "$surface" --arg tty "$tty" '
    [.windows[].workspaces[]] as $rows
    | select(($rows | map(.id) | unique | length) == ($rows | length))
    | [$rows[] | .id as $row | .panes[].surfaces[] | . + {workspace:$row}] as $surfaces
    | select(all($surfaces[]; .type == "terminal" or (.type | type == "string")))
    | select(($surfaces | map(.id // .ref) | unique | length) == ($surfaces | length))
    | [$surfaces[] | select((.tty // "" | ltrimstr("/dev/")) == $tty)]
    | select(length == 1 and .[0].type == "terminal" and .[0].workspace == $row)
    | select(.[0].id == $surface or .[0].surface_id == $surface)
    | .[0]' <<<"$tree") || return 1
  [[ -n $rows && $(LC_ALL=C ps -p "$launcher" -o lstart=) == "$start" ]]
}

cmux_extra_row_pids() { # Unattributed terminal processes must never disappear from ownership checks.
  jq -er --arg row "$2" '
    [.windows[].workspaces[] | select(.id == $row)] as $rows
    | select(($rows | length) == 1)
    | select(($rows[0] | has("panes") | not) or ($rows[0].panes | type == "array"))
    | select(all($rows[0].panes[]?; (.surfaces | type == "array")))
    | [$rows[0].panes[]?.surfaces[]] as $surfaces
    | select(all($surfaces[];
      ((has("tty_process_pids") | not) or (.tty_process_pids | type == "array"))
      and ((has("unattributed_tty_process_pids") | not) or (.unattributed_tty_process_pids | type == "array"))
      and ((.unattributed_resources.pids // []) | type == "array")
      and ((.unattributed_resources.missing_pids // []) | length) == 0
      and (if has("unattributed_resources") then .unattributed_resources as $u
        | ($u.process_count | type == "number" and . >= 0 and floor == .)
        and ($u.pids | length) == $u.process_count
        and ($u.pids | unique | length) == $u.process_count else true end)
      and ((has("tty_ownership_reasons") | not) or (.tty_ownership_reasons | type == "object"))))
    | [$surfaces[] | (.unattributed_tty_process_pids // [])[], (.unattributed_resources.pids // [])[]] as $unattributed
    | $rows[0].resources.pids as $attributed
    | select(all($unattributed[]; . as $pid | ($attributed | index($pid)) == null))
    | [$surfaces[] | (.tty_process_pids // [])[], (.unattributed_tty_process_pids // [])[],
        (.unattributed_resources.pids // [])[], ((.tty_ownership_reasons // {}) | keys[] | tonumber)] | unique
    | select(all(.[]; type == "number" and . > 1 and floor == .))
    | . - $attributed
    | if length == 0 then "" else .[] end' <<<"$1"
}

row_agent() {
  local attempt result
  for attempt in 1 2 3; do
    CMUX_SAMPLE_RETRY=0
    CMUX_ERROR=''
    result=0; row_agent_once "$@" || result=$?
    [[ $result != 0 ]] || return 0
    [[ $CMUX_SAMPLE_RETRY == 1 && $attempt != 3 ]] || return "$result"
    sleep 0.1
  done
}

row_agent_once() { # row_agent <row id> — sets ROW_AGENT: "self" for the caller's own row, "busy" when an agent
  # runs in the row, else "idle". A failed check returns a diagnostic in CMUX_ERROR.
  local state
  ROW_AGENT=busy
  ROW_AGENT_PID='' ROW_AGENT_START=''
  state=$(cmux_call top --workspace "$1" --processes --json 2>/dev/null) \
    || { cmux_error "cannot check the agent in cmux row $1; kept the worktree"; return 1; }
  printf '%s' "$state" | jq -e '.coding_agents | type == "array"
    and all(.[]; .resources.process_count | type == "number" and . >= 0)' >/dev/null 2>&1 \
    || { cmux_error "cannot check the agent in cmux row $1; kept the worktree"; return 1; }
  printf '%s' "$state" | jq -e 'all(.coding_agents[];
    (.resources.pids | type == "array") and (.resources.pids | length) == .resources.process_count
    and all(.resources.pids[]; type == "number" and . > 1 and floor == .)
    and (.resources.pids | unique | length) == (.resources.pids | length))' >/dev/null 2>&1 \
    || { cmux_error "cannot verify agent process data; kept the worktree"; return 1; }
  ROW_AGENT=busy
  local pids row_pids extra_pids root='' root_start pid command provider declared_agent=''
  if [[ -n ${2:-} && -f $(wt_meta "$2") ]]; then declared_agent=$(jq -r .agent "$(wt_meta "$2")");
  elif [[ -n ${WT_TEARDOWN_JSON:-} ]]; then declared_agent=$(jq -r .agent <<<"$WT_TEARDOWN_JSON"); fi
  # cmux caller fields echo environment hints. Use attributed PIDs and OS ancestry instead.
  printf '%s' "$state" | jq -e --arg id "$1" '
    [.windows[].workspaces[] | select(.id == $id)] as $rows
    | ($rows | length) == 1 and ($rows[0].resources as $r
      | ($r.pids | type == "array") and ($r.pids | length) == $r.process_count
      and all($r.pids[]; type == "number" and . > 1 and floor == .)
      and ($r.pids | unique | length) == ($r.pids | length)
      and (($r.missing_pids // []) | type == "array" and length == 0))' >/dev/null 2>&1 \
    || { cmux_error "cannot verify ownership of the agent in cmux row $1; incomplete process sample; kept the worktree"; return 1; }
  extra_pids=$(cmux_extra_row_pids "$state" "$1") || { cmux_error 'cannot inspect unattributed row processes; kept the worktree'; return 1; }
  if ! printf '%s' "$state" | jq -e 'any(.coding_agents[]; .resources.process_count > 0)' >/dev/null; then
    [[ -z $extra_pids ]] || { cmux_error 'row process attribution is uncertain; kept the worktree'; return 1; }
    ROW_AGENT=idle; return 0
  fi
  pids=$(printf '%s' "$state" | jq -r --arg id "$1" '
    [.windows[].workspaces[] | select(.id == $id) | .resources.pids] as $rows
    | (if ($rows | length) != 1 or ($rows[0] | type) != "array" then error("missing row PIDs") else $rows[0] end) as $row
    | [.coding_agents[].resources.pids[] | select(. as $p | $row | index($p))] | unique
    | if any(.[]; type != "number" or . <= 1 or floor != .) then error("invalid agent PIDs")
      elif length == 0 then empty else .[] end' 2>/dev/null) || {
      cmux_error "cannot verify ownership of the agent in cmux row $1; kept the worktree (restart the task with updated wt run)"; return 1;
    }
  # Other rows can contribute to the global agent totals. No intersection means this row is idle.
  if [[ -z $pids ]]; then
    [[ -z $extra_pids ]] || { cmux_error 'row process attribution is uncertain; kept the worktree'; return 1; }
    ROW_AGENT=idle; return 0
  fi
  while IFS= read -r pid; do
    if process_descends "$BASHPID" "$pid"; then
      command=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
      case "${command%%' -- '*}" in
        *' app-server'|*' app-server '*|*' exec-server'|*' exec-server '*) continue ;;
      esac
      if [[ -z $root ]] || process_descends "$root" "$pid"; then root=$pid; fi
    fi
  done <<<"$pids"
  if [[ -z $root ]]; then
    cmux_error "agent session ownership is unverified in cmux row $1; kept the worktree. Shared-server sessions need a task-owned restart with wt run"
    return 1
  fi
  root_start=$(LC_ALL=C ps -p "$root" -o lstart=) || { cmux_error 'cannot identify the requesting provider; kept the worktree'; return 1; }
  [[ -n $root_start ]] || { cmux_error 'requesting provider identity is empty; kept the worktree'; return 1; }
  provider=$(ps -p "$root" -o comm= 2>/dev/null) || return 1
  provider=${provider##*/}
  if [[ $declared_agent == codex || ${provider,,} == codex* ]]; then
    codex_owned_launch "${2:-}" "$1" "$root" || {
      cmux_error "cannot verify task-owned Codex launch in row $1; legacy shared-server ancestry is insufficient; kept the worktree"
      return 1
    }
  fi
  while IFS= read -r pid; do
    if ! process_descends "$pid" "$root"; then
      CMUX_ERROR="additional provider process $pid does not belong to requesting agent $root"
      return 0
    fi
  done <<<"$pids"
  row_pids=$(printf '%s' "$state" | jq -r --arg id "$1" '
    .windows[].workspaces[] | select(.id == $id) | .resources.pids[]
    | if type == "number" and . > 1 and floor == . then . else error("invalid PID") end') || return 1
  row_pids+="${extra_pids:+$'\n'$extra_pids}"
  while IFS= read -r pid; do
    if process_descends "$pid" "$root" || process_descends "$root" "$pid"; then continue; fi
    if process_vanished "$pid"; then
      if sampled_process_descends "$state" "$1" "$pid" "$root"; then continue; fi
      CMUX_SAMPLE_RETRY=1
      cmux_error 'a row process disappeared without verified ownership; kept the worktree'
      return 1
    fi
    CMUX_ERROR="process $pid is independent of requesting agent $root, or its ancestry is unreadable"
    return 0
  done <<<"$row_pids"
  [[ $(LC_ALL=C ps -p "$root" -o lstart=) == "$root_start" ]] || { cmux_error 'requesting provider changed during ownership verification'; return 1; }
  ROW_AGENT=self
  ROW_AGENT_PID=$root ROW_AGENT_START=$root_start
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
    rc=$?
    CMUX_ROWS_FULL=0
    if [[ $policy == skip ]]; then CMUX_ROWS_JSON='{"workspaces":[]}'; return 0; fi
    [[ $policy != checked ]] || { cmux_error "cannot list cmux windows"; return 1; }
    CMUX_ERROR="cannot list cmux rows (exit $rc)"
    return "$rc"
  }
  if ! windows=$(printf '%s' "$windows" | jq -ec '
    if type == "array" and all(.[]; .id | type == "string" and test("^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"))
    then . else error("invalid cmux window list") end' 2>/dev/null); then
    CMUX_ROWS_FULL=0
    if [[ $policy == skip ]]; then CMUX_ROWS_JSON='{"workspaces":[]}'; return 0; fi
    cmux_error "cannot list cmux windows"
    return 1
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
# unclaimed_row finds descriptions that wt does not write. wt rm checks these rows for agents because users can edit descriptions.
# WT_COMPAT: Remove when no row retains a repository-prefixed title.
# shellcheck disable=SC2016
ROW_JQ='
  def desc($sep): (.description | if type == "string" then . else "" end) | split($sep);
  def on_host($h; $sep): if $h == "" then ((.remote.enabled // false) | not)
    else ((.remote.enabled // false) and ((.remote.destination // "") == $h or (desc($sep)[0] // "") == "@" + $h)) end;
  def task_row($t; $r; $h; $sep): on_host($h; $sep)
    and ((.title == $t and (desc($sep)[1:] | join($sep)) == $r) or ($r != "" and .title == $r + ":" + $t));
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
  [[ "$__shell_last" =~ $__end ]] || { cmux_error "no shell prompt in cmux row $__id"; return 1; }
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
  [[ -n $1 ]] || { cmux_error "no sending cmux row ID"; return 1; }
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
    body=$(printf '%s' "$body" | jq -c --arg id "$request_id" '. + {request_id:$id}') \
      || { cmux_error "cannot encode a native request; run the line below on the Mac"; return 1; }
    # Native terminal IDs differ from the Mac's workspace UUIDs. Do not pass --workspace.
    env -u CMUX_SOCKET "${relay_ident[@]}" "$c" --socket "$relay_tui_socket" notify --surface "$relay_tui_terminal" --title "$title" --body "$body" >/dev/null 2>&1 \
      || { cmux_error "cmux-tui notify failed; run the line below on the Mac"; return 1; }
    return 0
  fi
}

# cmux_row_create_ssh <host> <title> <description> <command> [--no-focus]
# The caller must provide a complete CMUX_ROWS_JSON snapshot from before creation.
cmux_row_create_ssh() {
  local host=$1 title=$2 description=$3 command=$4 out ref before focus=1 arg args=(); shift 4
  for arg; do
    if [[ $arg == --no-focus ]]; then focus=0; else args+=("$arg"); fi
  done
  [[ ${CMUX_ROWS_FULL:-0} == 1 ]] || { cmux_error "cannot create an SSH row without a complete row list"; return 1; }
  ssh_host_check "$host" || { cmux_error "SSH host validation failed for $host"; return 1; }
  before=$(printf '%s' "$CMUX_ROWS_JSON" | jq -c '[.workspaces[].id | ascii_downcase]') \
    || { cmux_error "cannot read existing cmux row IDs"; return 1; }
  # Focused native SSH creation can replace the requested title with a generated name.
  # Establish the row's identity before selecting it.
  out=$(cmux_call ssh "$host" --name "$title" --no-focus "${args[@]}" --command "$command" --json --id-format uuids 2>&1) || {
    cmux_error "cmux ssh failed: $out"; return 1;
  }
  # Measured on 0.65.1: JSON alone returns refs. Explicit UUID formatting identifies the created row.
  # Refuse ambiguous output, another host, and identities present before creation.
  ref=$(printf '%s' "$out" | jq -ers --arg h "$host" --argjson before "$before" '
    select(length == 1) | .[0] | select(type == "object")
    | select(.remote.enabled == true and .remote.destination == $h)
    | .workspace_id as $id
    | select($id | type == "string" and test("^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"))
    | select(.window_id != $id and .surface_id != $id)
    | select($before | index($id | ascii_downcase) == null)
    | $id' 2>/dev/null) || ref=''
  [[ -n $ref ]] || {
    cmux_error "cmux reported no row for $title on $host: $out; if a new row $title with no repo on its second line is open, close it"
    return 1;
  }
  if cmux_call workspace-action --workspace "$ref" --action set-description --description "$description" >/dev/null 2>&1; then
    if ((focus)); then cmux_select "$ref" || return; fi
    return 0
  fi
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
