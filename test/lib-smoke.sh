#!/usr/bin/env bash
# Test the shared shell functions with scratch SSH configuration, fixed cmux responses, and a stub tmux.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lib-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=lib/workgrove/common.sh
source "$REPO/lib/workgrove/common.sh"
trap lib_cleanup EXIT

scenario_results() {
  begin_scenario 'versioned wt results' || return 0
record=$(WG_MACHINE_RESULT=1 wt_result new created task '/repos/two words' wt-two-words-task)
assert_eq 'result round trip' 'created|task|/repos/two words|wt-two-words-task' \
  "$(wt_read_result "$record" new | jq -r '[.status,.name,.repo,.session] | join("|" )')"
assert_eq 'ordinary commands do not emit records' '' "$(WG_MACHINE_RESULT='' wt_result new created task /repos/project)"
for sample in text empty malformed duplicate blank-duplicate version command control missing duplicate-status duplicate-name duplicate-repo duplicate-version escaped-key nested multiple-objects; do
  rc=0
  case $sample in
    text) output='created task'; expected=2 ;;
    empty) output=$'WT_RESULT\t'; expected=1 ;;
    malformed) output=$'WT_RESULT\t{broken'; expected=1 ;;
    duplicate) output="$record"$'\n'"$record"; expected=1 ;;
    blank-duplicate) output=$'WT_RESULT\t\n'"$record"; expected=1 ;;
    version) output=${record/\"version\":1/\"version\":2}; expected=1 ;;
    command) output=${record/\"new\"/\"show\"}; expected=1 ;;
    control) output=${record/task/task\\n}; expected=1 ;;
    missing) output=$'WT_RESULT\t{"version":1,"command":"new"}'; expected=1 ;;
    duplicate-status) output=${record/\"status\":/\"status\":\"found\",\"status\":}; expected=1 ;;
    duplicate-name) output=${record/\"name\":/\"name\":\"other\",\"name\":}; expected=1 ;;
    duplicate-repo) output=${record/\"repo\":/\"repo\":\"\/other\",\"repo\":}; expected=1 ;;
    duplicate-version) output=${record/\"version\":/\"version\":2,\"version\":}; expected=1 ;;
    escaped-key) output=${record/\"status\":/\"st\\u0061tus\":\"found\",\"status\":}; expected=1 ;;
    nested) output=${record/\"status\":/\"extra\":\{\"value\":1\},\"status\":}; expected=1 ;;
    multiple-objects) output=$'WT_RESULT\t{"version":1} {"command":"new","status":"created","name":"task","repo":"/repo","session":"session","state":""}'; expected=1 ;;
  esac
  wt_read_result "$output" new >/dev/null || rc=$?
  assert_eq "$sample result status" "$expected" "$rc"
done
  end_scenario
}
scenario_results

assert_result() { # <what> <expected: yes|no> <function> <argument>
  local what=$1 expected=$2 actual=no
  shift 2
  if "$@"; then actual=yes; fi
  assert_eq "$what" "$expected" "$actual"
}

scenario_aliases() {
  begin_scenario 'SSH alias syntax' || return 0
assert_result 'letter first' yes valid_host alpha
assert_result 'digit first and punctuation later' yes valid_host '9a._-'
assert_result 'capital letter' yes valid_host Alpha
assert_result 'hyphen first' no valid_host -alpha
assert_result 'dot first' no valid_host .alpha
assert_result 'slash' no valid_host alpha/beta
assert_result 'space' no valid_host 'alpha beta'
assert_result 'empty alias' no valid_host ''
  end_scenario
}
scenario_aliases

scenario_paths() {
  begin_scenario 'paths accepted by the Mac hook' || return 0
assert_result 'absolute path' yes hook_safe_path '/tmp/task name/.hidden'
assert_result 'single component' yes hook_safe_path '/task'
assert_result 'root path' no hook_safe_path /
assert_result 'relative path' no hook_safe_path 'tmp/task'
assert_result 'trailing slash' no hook_safe_path '/tmp/task/'
assert_result 'newline' no hook_safe_path $'/tmp/a\nb'
assert_result 'single quote' no hook_safe_path "/tmp/a'b"
assert_result 'double quote' no hook_safe_path '/tmp/a"b'
assert_result 'backtick' no hook_safe_path '/tmp/a`b'
assert_result 'dollar sign' no hook_safe_path "/tmp/a\$b"
assert_result 'backslash' no hook_safe_path '/tmp/a\b'
assert_result 'semicolon' no hook_safe_path '/tmp/a;b'
assert_result 'double slash' no hook_safe_path '/tmp//task'
assert_result 'parent component' no hook_safe_path '/tmp/../task'
assert_result 'final parent component' no hook_safe_path '/tmp/..'
  end_scenario
}
scenario_paths

name63=$(printf 'a%.0s' {1..63})
name64=${name63}a
# The output functions format invalid names too. valid_name makes the refusal decision.
check_identity() { # <name> <repo id> <valid: yes|no>
  local name=$1 id=$2 valid=$3
  assert_eq "repo id for $name" "$id" "$(repo_id "/repos/$name")"
  assert_eq "row title for $name" "$name" "$(row_title "$name")"
  assert_eq "session for $name" "wt-$id-$name" "$(wt_session "$name" "/repos/$name")"
  assert_result "valid name for $name" "$valid" valid_name "$name"
}

scenario_identities() {
  begin_scenario 'task and repository identities' || return 0
check_identity task task yes
check_identity 'two words' two-words no
check_identity 'has.dot' has-dot no
check_identity Upper Upper no
check_identity "$name63" "$name63" yes
check_identity "$name64" "$name64" no
assert_eq 'repo id uses only the last path component' final "$(repo_id '/repos/other/final')"
assert_result 'underscore after the first character' yes valid_name task_2
assert_result 'underscore first' no valid_name _task
assert_result 'empty task name' no valid_name ''
  end_scenario
}
scenario_identities

ROW_WINDOW_ONE=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
ROW_WINDOW_TWO=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
ROW_WINDOW_THREE=CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC
ROW_ONE='{"id":"row-one","title":"task","description":"@local · repo"}'
ROW_TWO='{"id":"row-two","title":"task","description":"@test-vm · repo","remote":{"enabled":true,"destination":"test-vm"}}'
ROW_EXPECTED="{\"workspaces\":[$ROW_ONE,$ROW_TWO]}"

row_cmux_reset() {
  ROW_WINDOWS="* 0: $ROW_WINDOW_ONE"
  ROW_WINDOWS_RC=0 ROW_ONE_RC=0 ROW_TWO_RC=0 ROW_FALLBACK_RC=0
  ROW_ONE_LIST="[$ROW_ONE]"
  ROW_TWO_LIST="{\"workspaces\":[$ROW_TWO]}"
  ROW_FALLBACK_LIST="[$ROW_ONE]"
  : >"$TEST_ROOT/row-calls"
  : >"$TEST_ROOT/row-caps"
}
row_cmux() {
  printf '%s\n' "$*" >>"$TEST_ROOT/row-calls"
  case "$*" in
    list-windows) printf '%s' "$ROW_WINDOWS"; return "$ROW_WINDOWS_RC" ;;
    "workspace list --json --window $ROW_WINDOW_ONE") printf '%s' "$ROW_ONE_LIST"; return "$ROW_ONE_RC" ;;
    "workspace list --json --window $ROW_WINDOW_TWO") printf '%s' "$ROW_TWO_LIST"; return "$ROW_TWO_RC" ;;
    "workspace list --json --window $ROW_WINDOW_THREE") printf '[]' ;;
    'workspace list --json') printf '%s' "$ROW_FALLBACK_LIST"; return "$ROW_FALLBACK_RC" ;;
    *) return 64 ;;
  esac
}
row_capped() {
  printf '%s\n' "${*:2}" >>"$TEST_ROOT/row-caps"
  "$@"
}
check_rows_load() {
  local policy=$1 expected_rc=$2 expected_json=$3 expected_full=$4 rc=0
  cmux_rows_load "$policy" row_capped row_cmux || rc=$?
  assert_eq "$policy returns the expected status" "$expected_rc" "$rc"
  assert_eq "$policy returns the expected rows" "$expected_json" "$CMUX_ROWS_JSON"
  assert_eq "$policy records list completeness" "$expected_full" "$CMUX_ROWS_FULL"
  assert_eq "$policy wraps every cmux call" "$(cat "$TEST_ROOT/row-calls")" "$(cat "$TEST_ROOT/row-caps")"
}

scenario_row_windows() {
  begin_scenario 'cmux row lists across windows' || return 0
for policy in skip stop checked; do
  row_cmux_reset
  check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 1
  ROW_ONE_LIST="{\"workspaces\":[$ROW_ONE]}"
  check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 1
  ROW_WINDOWS+=$'\n'"  1: $ROW_WINDOW_TWO"
  check_rows_load "$policy" 0 "$ROW_EXPECTED" 1
  assert_eq "$policy queries windows by UUID" \
    "$(printf 'list-windows\nworkspace list --json --window %s\nworkspace list --json --window %s' "$ROW_WINDOW_ONE" "$ROW_WINDOW_TWO")" \
    "$(tail -3 "$TEST_ROOT/row-calls")"
done
  end_scenario
}
scenario_row_windows

scenario_row_failures() {
  begin_scenario 'cmux window failures and older versions' || return 0
for policy in skip stop checked; do
  row_cmux_reset
  ROW_WINDOWS+=$'\n'"  1: $ROW_WINDOW_TWO"$'\n'"  2: $ROW_WINDOW_THREE"
  ROW_TWO_RC=142
  if [[ $policy == skip ]]; then
    check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 0
    assert_grep 'display lookups continue after a failed window' "$TEST_ROOT/row-calls" "$ROW_WINDOW_THREE"
  else
    check_rows_load "$policy" 142 '' 0
    assert_eq "$policy stops at the failing window" "workspace list --json --window $ROW_WINDOW_TWO" "$(tail -1 "$TEST_ROOT/row-calls")"
  fi
  row_cmux_reset
  ROW_WINDOWS='' ROW_WINDOWS_RC=1
  if [[ $policy == checked ]]; then
    check_rows_load "$policy" 1 '' 0
    assert_eq 'checked requires successful enumeration' list-windows "$(cat "$TEST_ROOT/row-calls")"
  else
    check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 0
    assert_eq "$policy falls back without list-windows" $'list-windows\nworkspace list --json' "$(cat "$TEST_ROOT/row-calls")"
  fi
done
row_cmux_reset
ROW_WINDOWS='a window line in a new format'
check_rows_load stop 0 "{\"workspaces\":[$ROW_ONE]}" 0
check_rows_load checked 1 '' 0
row_cmux_reset
ROW_WINDOWS+=$'\n'"  1: unrecognized-window"
check_rows_load stop 0 "{\"workspaces\":[$ROW_ONE]}" 0
check_rows_load checked 1 '' 0
row_cmux_reset
ROW_WINDOWS=''
check_rows_load checked 0 "{\"workspaces\":[$ROW_ONE]}" 0
ROW_FALLBACK_RC=142
check_rows_load stop 142 '' 0
check_rows_load checked 142 '' 0
  end_scenario
}
scenario_row_failures

scenario_row_validation() {
  begin_scenario 'cmux checked row validation' || return 0
row_cmux_reset
ROW_ONE_LIST='[]'
check_rows_load checked 0 '{"workspaces":[]}' 1
for invalid in '' ' ' 'not json' '{}' 'null' '{"workspaces":{}}' \
  '[{"title":"task"}]' '[{"id":"","title":"task"}]' '[{"id":4,"title":"task"}]' \
  '[{"id":"row"}]' '[{"id":"row","title":4}]' '[{"id":"row","title":"task","description":4}]' \
  '[{"id":"row","title":"task","remote":false}]' \
  '[{"id":"row","title":"task","remote":{"enabled":"true"}}]' \
  '[{"id":"row","title":"task","remote":{"destination":4}}]'; do
  ROW_ONE_LIST=$invalid
  assert_result "checked rejects $invalid" no cmux_rows_load checked row_cmux
  assert_eq 'a failed validation clears the previous snapshot' '' "$CMUX_ROWS_JSON"
done
ROW_ONE_LIST='{"workspaces":['
assert_result 'the hook rejects invalid JSON' no cmux_rows_load stop row_cmux
row_cmux_reset
ROW_WINDOWS+=$'\n'"  1: $ROW_WINDOW_TWO"
ROW_TWO_LIST=''
check_rows_load stop 0 "{\"workspaces\":[$ROW_ONE]}" 0
check_rows_load checked 1 '' 0
  end_scenario
}
scenario_row_validation

scenario_row_lookup() {
  begin_scenario 'cmux row lookup by title, repository and host' || return 0
ROW_LOOKUP="[$ROW_TWO,{\"id\":\"other-repo\",\"title\":\"task\",\"description\":\"@local · other\"},$ROW_ONE,\
{\"id\":\"legacy\",\"title\":\"repo:old-task\"},\
{\"id\":\"description-host\",\"title\":\"task\",\"description\":\"@other-vm · repo\",\"remote\":{\"enabled\":true,\"destination\":\"user@other-vm\"}},\
{\"id\":\"disabled-remote\",\"title\":\"local-task\",\"description\":\"@test-vm · repo\",\"remote\":{\"enabled\":false,\"destination\":\"test-vm\"}},\
{\"id\":\"no-repo\",\"title\":\"driver\"}]"
assert_eq 'a local lookup ignores remote and other repository rows' row-one "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo id)"
assert_eq 'an object list finds the remote row' row-two "$(printf '{\"workspaces\":%s}' "$ROW_LOOKUP" | cmux_find_row task repo id test-vm)"
assert_eq 'a lookup can return another field' '@local · repo' "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo description)"
assert_eq 'an older title still matches' legacy "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row old-task repo id)"
assert_eq 'the description can identify the host' description-host "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo id other-vm)"
assert_eq 'a row with remote disabled is local' disabled-remote "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row local-task repo id)"
assert_eq 'a row can have no repository' no-repo "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row driver '' id)"
assert_eq 'a missing field prints an empty string' '' "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo current_directory)"
rc=0
out=$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo id missing-vm) || rc=$?
assert_eq 'a missing host prints nothing' '' "$out"
assert_eq 'a missing host returns a failure' 4 "$rc"
assert_result 'a remote description alone cannot enable a remote row' no cmux_find_row local-task repo id test-vm <<<"$ROW_LOOKUP"
assert_result 'another repository does not match' no cmux_find_row task absent id <<<"$ROW_LOOKUP"
assert_eq 'the first matching row wins' row-one "$(printf '[%s,{"id":"later-row","title":"task","description":"@local · repo"}]' "$ROW_ONE" | cmux_find_row task repo id)"
  end_scenario
}
scenario_row_lookup

mkdir -p "$TEST_ROOT/home/.ssh"
cat >"$TEST_ROOT/home/.ssh/config" <<'CONFIG'
# This line has no aliases.
Host beta alpha # later words are comments
  Host gamma beta
Host wildcard-* literal? !blocked delta
Host !negated epsilon
Host alpha
host lowercase
CONFIG

test_ssh_hosts() {
  local HOME="$TEST_ROOT/home"
  begin_scenario 'SSH aliases from the config file' || return 0
  assert_eq 'literal aliases are sorted and unique' $'alpha\nbeta\ndelta\nepsilon\ngamma' \
    "$(ssh_hosts)"
  assert_result 'known literal alias' yes known_host beta
  assert_result 'wildcard is absent' no known_host 'wildcard-*'
  assert_result 'question mark pattern is absent' no known_host 'literal?'
  assert_result 'negated alias is absent' no known_host '!blocked'
  assert_result 'comment is absent' no known_host later
  assert_result 'partial alias is absent' no known_host alp
  HOME="$TEST_ROOT/empty-home"
  assert_eq 'missing config has no aliases' '' "$(ssh_hosts)"
  assert_result 'missing config has no known alias' no known_host beta
  end_scenario
}
test_ssh_hosts

scenario_tmux_commands() {
  begin_scenario 'exact tmux command lines' || return 0
expected_task=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test' echo\ task\ ready\;\ exec\ bash 2>/dev/null; for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; tmux set-environment -t '=wt-test' WT_CMUX_CLOSE_ON_EXIT 1; exec tmux attach -d -t '=wt-test'
COMMAND
)
assert_eq 'task command line with a command' "$expected_task." "$(tmux_cmd wt-test 'echo task ready'; printf '.')"
expected_shared=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test' echo\ task\ ready\;\ exec\ bash 2>/dev/null; tmux attach -t '=wt-test'
COMMAND
)
assert_eq 'shared command line with a command' "$expected_shared." "$(tmux_cmd wt-test 'echo task ready' shared; printf '.')"
expected_reinit=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; exec tmux attach -d -t '=wt-test'
COMMAND
)
assert_eq 'replacement command line' "$expected_reinit." "$(tmux_cmd wt-test '' '' reinit; printf '.')"
expected_task_shell=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; tmux set-environment -t '=wt-test' WT_CMUX_CLOSE_ON_EXIT 1; exec tmux attach -d -t '=wt-test'
COMMAND
)
assert_eq 'task command line without a command' "$expected_task_shell." "$(tmux_cmd wt-test; printf '.')"
expected_shared_shell=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; tmux attach -t '=wt-test'
COMMAND
)
assert_eq 'shared command line without a command' "$expected_shared_shell." "$(tmux_cmd wt-test '' shared; printf '.')"
  end_scenario
}
scenario_tmux_commands

with_relay_env() {
  local PATH="$TEST_ROOT/bin:$PATH" TMUX=/tmp/fake
  local -x CMUX_SOCKET_PATH=127.0.0.1:1111 CMUX_WORKSPACE_ID=pane-workspace CMUX_SURFACE_ID=pane-surface
  local -x CMUX_PANEL_ID=pane-panel CMUX_TAB_ID=pane-tab CMUX_TERMINAL_LIFECYCLE_ID=pane-lifecycle
  local -x CMUX_TUI_SOCKET=/tmp/pane-native CMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local -x CMUX_TUI_SESSION_ID=pane-session
  local relay_tui_socket relay_tui_terminal relay_ident
  local -x RELAY_TMUX_ENV="$TEST_ROOT/tmux.env" RELAY_TMUX_LOG="$TEST_ROOT/tmux.log" RELAY_TMUX_FAIL=''
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/no-tmux"
  cat > "$TEST_ROOT/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELAY_TMUX_LOG"
[[ $1 == "$RELAY_TMUX_FAIL" ]] && exit 1
case $* in
  'display-message -p #S') echo task:identity ;;
  'show-environment -t =task:identity') cat "$RELAY_TMUX_ENV" ;;
  *) exit 1 ;;
esac
TMUX
  chmod +x "$TEST_ROOT/bin/tmux"
  : > "$RELAY_TMUX_LOG"
  : > "$RELAY_TMUX_ENV"

  "$@"
}

scenario_relay_without_tmux() {
  begin_scenario 'relay identity without tmux' || return 0
  TMUX=''
  assert_result 'a pane identity is usable outside tmux' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'the pane supplies the native socket' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'the pane supplies the native terminal' term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$relay_tui_terminal"
  assert_eq 'all three pane variables reach the child' \
    $'CMUX_TUI_SOCKET=/tmp/pane-native\nCMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nCMUX_TUI_SESSION_ID=pane-session' \
    "$(printf '%s\n' "${relay_ident[@]}")"
  assert_eq 'tmux is not queried outside tmux' '' "$(cat "$RELAY_TMUX_LOG")"
  TMUX=/tmp/fake
  PATH="$TEST_ROOT/no-tmux" assert_result 'a missing tmux command keeps the pane identity' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'a missing tmux command keeps the socket' /tmp/pane-native "$relay_tui_socket"
  end_scenario
}
with_relay_env scenario_relay_without_tmux

scenario_relay_missing_values() {
  begin_scenario 'missing and unset session variables keep pane values' || return 0
  printf '%s\n' -CMUX_TUI_SOCKET CMUX_TUI_SESSION_ID=current-session > "$RELAY_TMUX_ENV"
  assert_result 'an unset session socket keeps the pane relay' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'an unset variable keeps the pane value' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'a session variable overrides the pane' current-session "$(printf '%s\n' "${relay_ident[@]}" | sed -n 's/^CMUX_TUI_SESSION_ID=//p')"
  assert_eq 'an absent variable keeps the pane value' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'one query reads the whole environment with an exact session target' \
    $'display-message -p #S\nshow-environment -t =task:identity' "$(cat "$RELAY_TMUX_LOG")"
  end_scenario
}
with_relay_env scenario_relay_missing_values

scenario_relay_empty_values() {
  begin_scenario 'empty session values clear stale pane values and child values' || return 0
  printf '%s\n' CMUX_SOCKET_PATH= CMUX_WORKSPACE_ID= CMUX_TUI_SOCKET= CMUX_TUI_TERMINAL_ID= CMUX_TUI_SESSION_ID= > "$RELAY_TMUX_ENV"
  assert_result 'cleared transports have no relay' no relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'the native socket is empty' '' "$relay_tui_socket"
  assert_eq 'the native terminal is empty' '' "$relay_tui_terminal"
  # shellcheck disable=SC2016
  assert_eq 'a child cannot inherit the stale transport identities' '||' \
    "$(env CMUX_TUI_SOCKET=stale CMUX_TUI_TERMINAL_ID=stale CMUX_TUI_SESSION_ID=stale \
      "${relay_ident[@]}" "$BASH" -c 'printf "%s|%s|%s" "$CMUX_TUI_SOCKET" "$CMUX_TUI_TERMINAL_ID" "$CMUX_TUI_SESSION_ID"')"
  end_scenario
}
with_relay_env scenario_relay_empty_values

scenario_relay_session_identity() {
  begin_scenario 'a native session overrides the pane identity' || return 0
  printf '%s\n' CMUX_SOCKET_PATH= CMUX_WORKSPACE_ID= CMUX_SURFACE_ID= CMUX_PANEL_ID= CMUX_TAB_ID= \
    CMUX_TERMINAL_LIFECYCLE_ID= CMUX_TUI_SOCKET=/tmp/current-native \
    CMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb CMUX_TUI_SESSION_ID=current-session > "$RELAY_TMUX_ENV"
  : > "$RELAY_TMUX_LOG"
  assert_result 'the native session is usable' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'the native session supplies the socket' /tmp/current-native "$relay_tui_socket"
  assert_eq 'the native session supplies the terminal' term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$relay_tui_terminal"
  assert_eq 'all three native session values reach the child' \
    $'CMUX_TUI_SOCKET=/tmp/current-native\nCMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nCMUX_TUI_SESSION_ID=current-session' \
    "$(printf '%s\n' "${relay_ident[@]}")"
  assert_eq 'a native read makes only two tmux calls' \
    $'display-message -p #S\nshow-environment -t =task:identity' "$(cat "$RELAY_TMUX_LOG")"
  end_scenario
}
with_relay_env scenario_relay_session_identity

scenario_relay_query_failures() {
  begin_scenario 'tmux query failures keep pane values' || return 0
  RELAY_TMUX_FAIL=display-message
  : > "$RELAY_TMUX_LOG"
  assert_result 'a failed session lookup keeps the pane relay' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'a failed session lookup keeps the pane socket' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'a failed session lookup skips the environment query' 'display-message -p #S' "$(cat "$RELAY_TMUX_LOG")"
  RELAY_TMUX_FAIL=show-environment
  assert_result 'a failed environment query keeps the pane relay' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'a failed environment query keeps the pane socket' /tmp/pane-native "$relay_tui_socket"
  end_scenario
}
with_relay_env scenario_relay_query_failures

scenario_relay_unset_values() {
  begin_scenario 'unset pane variables stay unset unless the session assigns them' || return 0
  RELAY_TMUX_FAIL=''
  unset CMUX_TUI_SESSION_ID
  printf '%s\n' -CMUX_TUI_SESSION_ID > "$RELAY_TMUX_ENV"
  assert_result 'missing pane names do not prevent relay use' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  # shellcheck disable=SC2016
  assert_eq 'absent and removed names stay unset in the child' 'unset' \
    "$(env -u CMUX_TUI_SESSION_ID "${relay_ident[@]}" "$BASH" -c 'printf "%s" "${CMUX_TUI_SESSION_ID-unset}"')"
  printf '%s\n' CMUX_TUI_SESSION_ID= > "$RELAY_TMUX_ENV"
  assert_result 'explicit empty session assignments keep the relay usable' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  # shellcheck disable=SC2016
  assert_eq 'explicit empty session assignments reach the child' '' \
    "$(env -u CMUX_TUI_SESSION_ID "${relay_ident[@]}" "$BASH" -c 'printf "%s" "${CMUX_TUI_SESSION_ID-unset}"')"
  TMUX=''
  assert_result 'missing pane names outside tmux do not prevent relay use' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  # shellcheck disable=SC2016
  assert_eq 'names absent outside tmux stay unset in the child' 'unset' \
    "$(env -u CMUX_TUI_SESSION_ID "${relay_ident[@]}" "$BASH" -c 'printf "%s" "${CMUX_TUI_SESSION_ID-unset}"')"
  end_scenario
}
with_relay_env scenario_relay_unset_values

run_harness() {
  local filter=$1 body=$2
  HARNESS_RC=0
  # shellcheck disable=SC2016  # The child shell expands its positional arguments.
  HARNESS_OUT=$(ONLY="$filter" "$BASH" -eu -c 'source "$1"; eval "$2"; lib_summary' \
    _ "$REPO/test/lib.sh" "$body" 2>&1) || HARNESS_RC=$?
}

scenario_assertion_guard() {
  begin_scenario 'scenario assertion guard' || return 0
  run_harness '' 'begin_scenario empty; end_scenario'
  assert_eq 'an empty scenario fails' 1 "$HARNESS_RC"
  assert_eq 'an empty scenario reports the cause' yes \
    "$([[ $HARNESS_OUT == *'scenario made no assertions'* ]] && echo yes || echo no)"
  run_harness '' 'begin_scenario first; pass; end_scenario; begin_scenario empty; end_scenario'
  assert_eq 'a previous assertion cannot hide an empty scenario' 1 "$HARNESS_RC"
  run_harness '' 'begin_scenario broken; assert_eq value expected actual; end_scenario; begin_scenario good; pass; end_scenario'
  assert_eq 'a later pass cannot hide an earlier failure' 1 "$HARNESS_RC"
  run_harness '' 'empty() { begin_scenario empty; return 0; }; empty'
  assert_eq 'an empty early return fails' 1 "$HARNESS_RC"
  assert_eq 'an early return reports its unfinished scenario' yes \
    "$([[ $HARNESS_OUT == *'FAIL [empty] scenario did not call end_scenario'* ]] && echo yes || echo no)"
  run_harness '' 'begin_scenario unfinished; pass'
  assert_eq 'assertions cannot complete an unfinished scenario' 1 "$HARNESS_RC"
  run_harness '' 'begin_scenario first; pass; begin_scenario second; pass; end_scenario'
  assert_eq 'a later scenario cannot replace an unfinished scenario' 1 "$HARNESS_RC"
  assert_eq 'an overwritten scenario retains its name in the failure' yes \
    "$([[ $HARNESS_OUT == *'FAIL [first] scenario did not call end_scenario'* ]] && echo yes || echo no)"
  run_harness 'selected' 'begin_scenario selected; pass; begin_scenario skipped || :; end_scenario'
  assert_eq 'a skipped scenario does not replace an active scenario' 0 "$HARNESS_RC"
  run_harness '' 'end_scenario'
  assert_eq 'ending without a matching begin fails' 1 "$HARNESS_RC"
  assert_eq 'an unmatched end reports its cause' yes \
    "$([[ $HARNESS_OUT == *'end_scenario called without begin_scenario'* ]] && echo yes || echo no)"
  run_harness '' 'begin_scenario complete; pass; end_scenario; end_scenario'
  assert_eq 'ending the same scenario twice fails' 1 "$HARNESS_RC"
  run_harness '' 'begin_scenario good; pass; pass; end_scenario'
  assert_eq 'the summary derives the total' 0 "$HARNESS_RC"
  assert_eq 'the summary reports the derived total' yes \
    "$([[ $HARNESS_OUT == *'2 assertions: 2 passed, 0 failed'* ]] && echo yes || echo no)"
  end_scenario
}
scenario_assertion_guard

scenario_filter() {
  begin_scenario 'scenario name filter' || return 0
  local body
  body=$(cat <<'BODY'
first() { begin_scenario 'first scenario' || return 0; fail 'unselected scenario ran'; end_scenario; }
second() { begin_scenario 'second scenario' || return 0; pass; end_scenario; }
first
second
BODY
)
  local pattern
  for pattern in second 'sec*scenario' '?econd scenario'; do
    run_harness "$pattern" "$body"
    assert_eq "$pattern selects one scenario" 0 "$HARNESS_RC"
    assert_eq "$pattern skips the other assertions" yes \
      "$([[ $HARNESS_OUT == *'1 assertions: 1 passed, 0 failed'* && $HARNESS_OUT != *'unselected scenario ran'* ]] && echo yes || echo no)"
  done
  run_harness missing "$body"
  assert_eq 'an unmatched filter fails' 1 "$HARNESS_RC"
  assert_eq 'an unmatched filter reports the cause' yes \
    "$([[ $HARNESS_OUT == *'no scenarios matched ONLY=missing'* ]] && echo yes || echo no)"
  run_harness '' "$body"
  assert_eq 'an empty filter runs the failing scenario too' 1 "$HARNESS_RC"
  end_scenario
}
scenario_filter

scenario_poll_interval() {
  begin_scenario 'poll interval defaults and overrides' || return 0
  local out
  out=$(unset WG_POLL_INTERVAL; sleep() { printf '%s' "$1"; }; wg_sleep)
  assert_eq 'the production poll interval defaults to one second' 1 "$out"
  out=$(WG_POLL_INTERVAL=0; sleep() { printf '%s' "$1"; }; wg_sleep)
  assert_eq 'tests can select a zero interval' 0 "$out"
  out=$(WG_POLL_INTERVAL=0.25; sleep() { printf '%s' "$1"; }; wg_sleep)
  assert_eq 'the poll interval accepts fractional seconds' 0.25 "$out"
  end_scenario
}
scenario_poll_interval

lib_summary
