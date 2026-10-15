# shellcheck shell=bash
# lib/workgrove/common.sh — shell functions that more than one script in bin/ needs.
# bin/wt, bin/cmux-hook and bin/agent-notify source this file after they hand off to bash 5.
# This file needs bash 5. Bash reads a sourced file one command at a time, so an older bash returns at
# the next line before it parses the rest, and its source fails cleanly.
# Apart from that version check, this file defines functions and row identity constants.
# It sets no shell options, so it works under the "set -euo pipefail" of bin/wt and the "set -u" of the hooks.
if ((BASH_VERSINFO[0] < 5)); then return 1; fi

# valid_host <alias> — an ssh alias: letters, digits, '.', '_' and '-', with a letter or digit first.
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# The Mac hook (bin/cmux-hook) drops any other path, so never relay a path that fails this.
hook_safe_path() { [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *//* && "$1" != */ && "$1" != *'/../'* && "$1" != */.. && "$1" != *[\'\"\`\$\\\;]* ]]; }

# Identity. bin/wt and bin/cmux-hook take a task's row title, repo id and tmux session from these functions.
# A row's title tells which task it is. Its description (row_tag in bin/wt) tells which machine
# and which repo. Two repos can have tasks with the same name, so the title alone does not identify a row.
# attach_row in bin/cmux-hook writes the description of the rows that it relays in the same format as
# row_tag, so keep the two byte-compatible.
repo_id()    { printf '%s' "${1##*/}" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'; }
row_title()  { printf '%s' "$1"; }                                          # row_title <name> — a task row's title
wt_session() { printf 'wt-%s-%s' "$(repo_id "$2")" "$1"; }                  # wt_session <name> <repo>
# valid_name <name> — a task name: lowercase letters, digits, '_' and '-', max 63, no '.'.
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; }

# cmux_rows_load <skip|stop|checked> <command...> sets CMUX_ROWS_JSON and CMUX_ROWS_FULL.
# The command runs every cmux call. The hook passes capped and its cmux path.
# skip ignores windows that close during enumeration. stop returns the first failing call's status.
# checked requires readable window lists and validates every row before removal can trust the result.
# CMUX_ROWS_FULL is 1 only when every window line names a UUID and every window returns nonblank output.
# workspace list covers one window. Window UUIDs stay fixed when cmux changes window indices.
# shellcheck disable=SC2034
cmux_rows_load() {
  local policy=$1 windows window out docs='' rc=0 lines=() window_ids=()
  shift
  CMUX_ROWS_JSON='' CMUX_ROWS_FULL=1
  windows=$("$@" list-windows 2>/dev/null) || {
    CMUX_ROWS_FULL=0
    [[ $policy != checked ]] || return 1
    [[ $policy != stop ]] || windows=''
  }
  mapfile -t lines <<<"$windows"
  mapfile -t window_ids < <(printf '%s\n' "$windows" | awk '{print ($1 == "*" ? $3 : $2)}' | grep -Ex '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}')
  if (( ${#window_ids[@]} == 0 || ${#window_ids[@]} != ${#lines[@]} )); then
    CMUX_ROWS_FULL=0
    [[ $policy != checked || -z $windows ]] || return 1
  fi
  for window in "${window_ids[@]}"; do
    out=$("$@" workspace list --json --window "$window" 2>/dev/null) || {
      rc=$?
      CMUX_ROWS_FULL=0
      [[ $policy == skip ]] || return "$rc"
      continue
    }
    if [[ -z ${out//[[:space:]]/} ]]; then
      CMUX_ROWS_FULL=0
      [[ $policy != checked ]] || return 1
    fi
    docs="$docs$out"
  done
  if [[ -z $docs ]]; then
    docs=$("$@" workspace list --json 2>/dev/null) || {
      rc=$?
      [[ $policy == skip ]] || return "$rc"
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
        then {workspaces: ($rows | add)} else error("invalid cmux row list") end' 2>/dev/null)
    return
  fi
  CMUX_ROWS_JSON=$(printf '%s' "$docs" | jq -s -c '{workspaces: (map(.workspaces? // .) | add // [])}' 2>/dev/null) || {
    [[ $policy == skip ]] && return 0
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

ssh_hosts() { # non-wildcard Host aliases in ~/.ssh/config, one per line. known_host reads the same list.
  { awk '$1=="Host"{for(i=2;i<=NF;i++){if($i ~ /^#/)break; if($i !~ /^[!]/ && $i !~ /[*?]/) print $i}}' "$HOME/.ssh/config" 2>/dev/null || true; } | sort -u
}
# known_host <alias> — the alias is one that ssh_hosts prints. grep reads all its input (no -q),
# so sort never gets SIGPIPE, and the answer stays correct under pipefail.
known_host() { ssh_hosts | grep -xF -- "$1" >/dev/null; }

tmux_cmd() { # tmux_cmd <session> [command] [shared] [reinit]
  # The line that a VM row's shell runs. It creates that tmux session (running <command>, then a shell) or
  # takes over the session that is already there. A task row owns its session, so it attaches with -d. It
  # hands the session THIS row's relay socket and workspace id. That makes `cmux notify` from inside the
  # session light up this row.
  # After "remote session was lost", cmux starts a shell that carries none of the CMUX_* variables.
  # The file ~/.tmux.conf lists CMUX_SOCKET_PATH and CMUX_WORKSPACE_ID in update-environment (install.sh
  # links home/.tmux.conf with --with-tmux-conf, or appends that one line to the file you already have).
  # So an attach from that shell would mark them removed in the session and silence `cmux notify` there.
  # Therefore, when the shell has none, the line takes each variable from the session (the row's old relay
  # port stays bound to the row). It sets each one only when it is non-empty.
  # A native attachment clears TCP values. A TCP attachment clears native values to override stale panes.
  # A session that you may also be in yourself (the VM shell, a repo shell) gets "shared" instead. Then the
  # row joins your clients and does not evict them, and it leaves their relay socket as it is.
  # Native cmux closes a row when its terminal exits. Exec the tmux client so self-removal ends that terminal.
  local run="" native_mark=""
  # Replacing an old client does not replace its parent shell. Preserve its original cleanup contract.
  [[ ${4:-} == reinit ]] || native_mark="tmux set-environment -t '=$1' WT_CMUX_CLOSE_ON_EXIT 1; "
  [[ -n "${2:-}" ]] && printf -v run '%q' "$2; exec bash"
  if [[ "${3:-}" == shared ]]; then
    printf "tmux new-session -d -s '%s' %s 2>/dev/null; tmux attach -t '=%s'" "$1" "$run" "$1"
  else
    printf "tmux new-session -d -s '%s' %s 2>/dev/null; " "$1" "$run"
    # Bind the current transport before reading the old session's identity.
    printf "if [ -n \"\$CMUX_TUI_SOCKET\" ]; then for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export \"\$v=\"; tmux set-environment -t '=%s' \"\$v\" ''; done; " "$1"
    printf "for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=%s' \"\$v\" \"\$(printenv \"\$v\")\"; done; %sexec tmux attach -d -t '=%s'; fi; " "$1" "$native_mark" "$1"
    printf "[ -n \"\$CMUX_SOCKET_PATH\" ] || export CMUX_SOCKET_PATH=\"\$(tmux show-environment -t '=%s' CMUX_SOCKET_PATH 2>/dev/null | sed -n 's/^CMUX_SOCKET_PATH=//p')\"; [ -n \"\$CMUX_WORKSPACE_ID\" ] || export CMUX_WORKSPACE_ID=\"\$(tmux show-environment -t '=%s' CMUX_WORKSPACE_ID 2>/dev/null | sed -n 's/^CMUX_WORKSPACE_ID=//p')\"; [ -n \"\$CMUX_SOCKET_PATH\" ] && tmux set-environment -t '=%s' CMUX_SOCKET_PATH \"\$CMUX_SOCKET_PATH\"; [ -n \"\$CMUX_WORKSPACE_ID\" ] && tmux set-environment -t '=%s' CMUX_WORKSPACE_ID \"\$CMUX_WORKSPACE_ID\"; " "$1" "$1" "$1" "$1"
    printf "for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do export \"\$v=\"; tmux set-environment -t '=%s' \"\$v\" ''; done; tmux attach -d -t '=%s'" "$1" "$1"
  fi
}
