#!/usr/bin/env bash
# Test the shared shell functions with scratch SSH configuration.
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

begin_scenario 'exact tmux command lines'
expected_task=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test' echo\ task\ ready\;\ exec\ bash 2>/dev/null; if [ -n "$CMUX_TUI_SOCKET" ]; then for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; tmux set-environment -t '=wt-test' WT_CMUX_CLOSE_ON_EXIT 1; exec tmux attach -d -t '=wt-test'; fi; [ -n "$CMUX_SOCKET_PATH" ] || export CMUX_SOCKET_PATH="$(tmux show-environment -t '=wt-test' CMUX_SOCKET_PATH 2>/dev/null | sed -n 's/^CMUX_SOCKET_PATH=//p')"; [ -n "$CMUX_WORKSPACE_ID" ] || export CMUX_WORKSPACE_ID="$(tmux show-environment -t '=wt-test' CMUX_WORKSPACE_ID 2>/dev/null | sed -n 's/^CMUX_WORKSPACE_ID=//p')"; [ -n "$CMUX_SOCKET_PATH" ] && tmux set-environment -t '=wt-test' CMUX_SOCKET_PATH "$CMUX_SOCKET_PATH"; [ -n "$CMUX_WORKSPACE_ID" ] && tmux set-environment -t '=wt-test' CMUX_WORKSPACE_ID "$CMUX_WORKSPACE_ID"; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; tmux attach -d -t '=wt-test'
COMMAND
)
assert_eq 'task command line with a command' "$expected_task." "$(tmux_cmd wt-test 'echo task ready'; printf '.')"
expected_shared=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test' echo\ task\ ready\;\ exec\ bash 2>/dev/null; tmux attach -t '=wt-test'
COMMAND
)
assert_eq 'shared command line with a command' "$expected_shared." "$(tmux_cmd wt-test 'echo task ready' shared; printf '.')"
expected_reinit=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; if [ -n "$CMUX_TUI_SOCKET" ]; then for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; exec tmux attach -d -t '=wt-test'; fi; [ -n "$CMUX_SOCKET_PATH" ] || export CMUX_SOCKET_PATH="$(tmux show-environment -t '=wt-test' CMUX_SOCKET_PATH 2>/dev/null | sed -n 's/^CMUX_SOCKET_PATH=//p')"; [ -n "$CMUX_WORKSPACE_ID" ] || export CMUX_WORKSPACE_ID="$(tmux show-environment -t '=wt-test' CMUX_WORKSPACE_ID 2>/dev/null | sed -n 's/^CMUX_WORKSPACE_ID=//p')"; [ -n "$CMUX_SOCKET_PATH" ] && tmux set-environment -t '=wt-test' CMUX_SOCKET_PATH "$CMUX_SOCKET_PATH"; [ -n "$CMUX_WORKSPACE_ID" ] && tmux set-environment -t '=wt-test' CMUX_WORKSPACE_ID "$CMUX_WORKSPACE_ID"; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; tmux attach -d -t '=wt-test'
COMMAND
)
assert_eq 'replacement command line' "$expected_reinit." "$(tmux_cmd wt-test '' '' reinit; printf '.')"
expected_task_shell=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; if [ -n "$CMUX_TUI_SOCKET" ]; then for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; tmux set-environment -t '=wt-test' WT_CMUX_CLOSE_ON_EXIT 1; exec tmux attach -d -t '=wt-test'; fi; [ -n "$CMUX_SOCKET_PATH" ] || export CMUX_SOCKET_PATH="$(tmux show-environment -t '=wt-test' CMUX_SOCKET_PATH 2>/dev/null | sed -n 's/^CMUX_SOCKET_PATH=//p')"; [ -n "$CMUX_WORKSPACE_ID" ] || export CMUX_WORKSPACE_ID="$(tmux show-environment -t '=wt-test' CMUX_WORKSPACE_ID 2>/dev/null | sed -n 's/^CMUX_WORKSPACE_ID=//p')"; [ -n "$CMUX_SOCKET_PATH" ] && tmux set-environment -t '=wt-test' CMUX_SOCKET_PATH "$CMUX_SOCKET_PATH"; [ -n "$CMUX_WORKSPACE_ID" ] && tmux set-environment -t '=wt-test' CMUX_WORKSPACE_ID "$CMUX_WORKSPACE_ID"; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; tmux attach -d -t '=wt-test'
COMMAND
)
assert_eq 'task command line without a command' "$expected_task_shell." "$(tmux_cmd wt-test; printf '.')"
expected_shared_shell=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; tmux attach -t '=wt-test'
COMMAND
)
assert_eq 'shared command line without a command' "$expected_shared_shell." "$(tmux_cmd wt-test '' shared; printf '.')"
end_scenario

lib_summary 65
