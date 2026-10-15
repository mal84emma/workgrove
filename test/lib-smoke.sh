#!/usr/bin/env bash
# Test the shared shell functions with scratch SSH configuration and a stub tmux.
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

test_relay_env() {
  local PATH="$TEST_ROOT/bin:$PATH" TMUX=''
  local -x CMUX_SOCKET_PATH=127.0.0.1:1111 CMUX_WORKSPACE_ID=pane-workspace CMUX_SURFACE_ID=pane-surface
  local -x CMUX_PANEL_ID=pane-panel CMUX_TAB_ID=pane-tab CMUX_TERMINAL_LIFECYCLE_ID=pane-lifecycle
  local -x CMUX_TUI_SOCKET=/tmp/pane-native CMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local -x CMUX_TUI_SESSION_ID=pane-session
  local RELAY_SOCKET RELAY_WS RELAY_TUI_SOCKET RELAY_TUI_TERMINAL RELAY_IDENT
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

  begin_scenario 'relay identity without tmux'
  assert_result 'a pane identity is usable outside tmux' yes relay_env
  assert_eq 'the pane supplies the TCP socket' 127.0.0.1:1111 "$RELAY_SOCKET"
  assert_eq 'the pane supplies the workspace' pane-workspace "$RELAY_WS"
  assert_eq 'the pane supplies the native socket' /tmp/pane-native "$RELAY_TUI_SOCKET"
  assert_eq 'the pane supplies the native terminal' term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$RELAY_TUI_TERMINAL"
  assert_eq 'all nine pane variables reach the child' \
    $'CMUX_SOCKET_PATH=127.0.0.1:1111\nCMUX_WORKSPACE_ID=pane-workspace\nCMUX_SURFACE_ID=pane-surface\nCMUX_PANEL_ID=pane-panel\nCMUX_TAB_ID=pane-tab\nCMUX_TERMINAL_LIFECYCLE_ID=pane-lifecycle\nCMUX_TUI_SOCKET=/tmp/pane-native\nCMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nCMUX_TUI_SESSION_ID=pane-session' \
    "$(printf '%s\n' "${RELAY_IDENT[@]}")"
  assert_eq 'tmux is not queried outside tmux' '' "$(cat "$RELAY_TMUX_LOG")"
  TMUX=/tmp/fake
  PATH="$TEST_ROOT/no-tmux" assert_result 'a missing tmux command keeps the pane identity' yes relay_env
  assert_eq 'a missing tmux command keeps the socket' 127.0.0.1:1111 "$RELAY_SOCKET"
  end_scenario

  begin_scenario 'missing and unset session variables keep pane values'
  printf '%s\n' -CMUX_SOCKET_PATH CMUX_WORKSPACE_ID=current-workspace > "$RELAY_TMUX_ENV"
  assert_result 'an unset session socket keeps the pane relay' yes relay_env
  assert_eq 'an unset variable keeps the pane value' 127.0.0.1:1111 "$RELAY_SOCKET"
  assert_eq 'a session variable overrides the pane' current-workspace "$RELAY_WS"
  assert_eq 'an absent variable keeps the pane value' /tmp/pane-native "$RELAY_TUI_SOCKET"
  assert_eq 'one query reads the whole environment with an exact session target' \
    $'display-message -p #S\nshow-environment -t =task:identity' "$(cat "$RELAY_TMUX_LOG")"
  end_scenario

  begin_scenario 'empty session values clear stale pane values and child values'
  printf '%s\n' CMUX_SOCKET_PATH= CMUX_WORKSPACE_ID= CMUX_TUI_SOCKET= CMUX_TUI_TERMINAL_ID= CMUX_TUI_SESSION_ID= > "$RELAY_TMUX_ENV"
  assert_result 'cleared transports have no relay' no relay_env
  assert_eq 'the TCP socket is empty' '' "$RELAY_SOCKET"
  assert_eq 'the workspace is empty' '' "$RELAY_WS"
  assert_eq 'the native socket is empty' '' "$RELAY_TUI_SOCKET"
  assert_eq 'the native terminal is empty' '' "$RELAY_TUI_TERMINAL"
  # shellcheck disable=SC2016
  assert_eq 'a child cannot inherit the stale transport identities' '||||' \
    "$(env CMUX_SOCKET_PATH=stale CMUX_WORKSPACE_ID=stale CMUX_TUI_SOCKET=stale CMUX_TUI_TERMINAL_ID=stale CMUX_TUI_SESSION_ID=stale \
      "${RELAY_IDENT[@]}" "$BASH" -c 'printf "%s|%s|%s|%s|%s" "$CMUX_SOCKET_PATH" "$CMUX_WORKSPACE_ID" "$CMUX_TUI_SOCKET" "$CMUX_TUI_TERMINAL_ID" "$CMUX_TUI_SESSION_ID"')"
  end_scenario

  begin_scenario 'a native session replaces a TCP pane identity'
  printf '%s\n' CMUX_SOCKET_PATH= CMUX_WORKSPACE_ID= CMUX_SURFACE_ID= CMUX_PANEL_ID= CMUX_TAB_ID= \
    CMUX_TERMINAL_LIFECYCLE_ID= CMUX_TUI_SOCKET=/tmp/current-native \
    CMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb CMUX_TUI_SESSION_ID=current-session > "$RELAY_TMUX_ENV"
  : > "$RELAY_TMUX_LOG"
  assert_result 'the native session is usable' yes relay_env
  assert_eq 'the native session supplies the socket' /tmp/current-native "$RELAY_TUI_SOCKET"
  assert_eq 'the native session supplies the terminal' term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$RELAY_TUI_TERMINAL"
  assert_eq 'all nine native session values reach the child' \
    $'CMUX_SOCKET_PATH=\nCMUX_WORKSPACE_ID=\nCMUX_SURFACE_ID=\nCMUX_PANEL_ID=\nCMUX_TAB_ID=\nCMUX_TERMINAL_LIFECYCLE_ID=\nCMUX_TUI_SOCKET=/tmp/current-native\nCMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nCMUX_TUI_SESSION_ID=current-session' \
    "$(printf '%s\n' "${RELAY_IDENT[@]}")"
  assert_eq 'a native read makes only two tmux calls' \
    $'display-message -p #S\nshow-environment -t =task:identity' "$(cat "$RELAY_TMUX_LOG")"
  end_scenario

  begin_scenario 'a TCP session replaces a native pane identity'
  printf '%s\n' CMUX_SOCKET_PATH=127.0.0.1:2222 CMUX_WORKSPACE_ID=current-workspace CMUX_SURFACE_ID=current-surface \
    'CMUX_PANEL_ID=panel with spaces=and\backslashes' CMUX_TAB_ID=current-tab CMUX_TERMINAL_LIFECYCLE_ID=current-lifecycle \
    CMUX_TUI_SOCKET= CMUX_TUI_TERMINAL_ID= CMUX_TUI_SESSION_ID= > "$RELAY_TMUX_ENV"
  : > "$RELAY_TMUX_LOG"
  assert_result 'the TCP session is usable' yes relay_env
  assert_eq 'the TCP session supplies the socket' 127.0.0.1:2222 "$RELAY_SOCKET"
  assert_eq 'the TCP session supplies the workspace' current-workspace "$RELAY_WS"
  assert_eq 'the previous native socket is cleared' '' "$RELAY_TUI_SOCKET"
  assert_eq 'the previous native terminal is cleared' '' "$RELAY_TUI_TERMINAL"
  assert_eq 'all nine TCP session values reach the child without interpretation' \
    $'CMUX_SOCKET_PATH=127.0.0.1:2222\nCMUX_WORKSPACE_ID=current-workspace\nCMUX_SURFACE_ID=current-surface\nCMUX_PANEL_ID=panel with spaces=and\\backslashes\nCMUX_TAB_ID=current-tab\nCMUX_TERMINAL_LIFECYCLE_ID=current-lifecycle\nCMUX_TUI_SOCKET=\nCMUX_TUI_TERMINAL_ID=\nCMUX_TUI_SESSION_ID=' \
    "$(printf '%s\n' "${RELAY_IDENT[@]}")"
  assert_eq 'a TCP read makes only two tmux calls' \
    $'display-message -p #S\nshow-environment -t =task:identity' "$(cat "$RELAY_TMUX_LOG")"
  end_scenario

  begin_scenario 'tmux query failures keep pane values'
  RELAY_TMUX_FAIL=display-message
  : > "$RELAY_TMUX_LOG"
  assert_result 'a failed session lookup keeps the pane relay' yes relay_env
  assert_eq 'a failed session lookup keeps the pane socket' 127.0.0.1:1111 "$RELAY_SOCKET"
  assert_eq 'a failed session lookup skips the environment query' 'display-message -p #S' "$(cat "$RELAY_TMUX_LOG")"
  RELAY_TMUX_FAIL=show-environment
  assert_result 'a failed environment query keeps the pane relay' yes relay_env
  assert_eq 'a failed environment query keeps the pane socket' 127.0.0.1:1111 "$RELAY_SOCKET"
  end_scenario
}
test_relay_env

lib_summary 102
