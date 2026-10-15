#!/usr/bin/env bash
# Test the shared shell functions with scratch SSH configuration and fixed cmux responses.
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

assert_result() { # <what> <expected: yes|no> <function> <argument>
  local what=$1 expected=$2 actual=no
  shift 2
  if "$@"; then actual=yes; fi
  assert_eq "$what" "$expected" "$actual"
}

begin_scenario 'SSH alias syntax'
assert_result 'letter first' yes valid_host alpha
assert_result 'digit first and punctuation later' yes valid_host '9a._-'
assert_result 'capital letter' yes valid_host Alpha
assert_result 'hyphen first' no valid_host -alpha
assert_result 'dot first' no valid_host .alpha
assert_result 'slash' no valid_host alpha/beta
assert_result 'space' no valid_host 'alpha beta'
assert_result 'empty alias' no valid_host ''
end_scenario

begin_scenario 'paths accepted by the Mac hook'
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

begin_scenario 'task and repository identities'
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

begin_scenario 'cmux row lists across windows'
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

begin_scenario 'cmux window failures and older versions'
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

begin_scenario 'cmux checked row validation'
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

begin_scenario 'cmux row lookup by title, repository and host'
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
  begin_scenario 'SSH aliases from the config file'
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

lib_summary 213
