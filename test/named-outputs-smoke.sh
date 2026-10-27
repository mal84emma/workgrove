#!/usr/bin/env bash
# Check that internal locals cannot capture caller-named output variables.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/named-outputs-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=lib/workgrove/common.sh
source "$REPO/lib/workgrove/common.sh"
# shellcheck source=lib/workgrove/safety.sh
source "$REPO/lib/workgrove/safety.sh"
# shellcheck source=lib/workgrove/recovery.sh
source "$REPO/lib/workgrove/recovery.sh"
trap lib_cleanup EXIT


die() { printf '%s\n' "$*" >&2; return 1; }
warn() { printf '%s\n' "$*" >&2; }
wt_path() { printf '%s/project/.worktrees/%s' "$TEST_ROOT" "$1"; }
wt_branch() { printf 'wt/%s' "$1"; }
# shellcheck source=test/fakes/rows.sh
source "$REPO/test/fakes/rows.sh"
fake_cmux_init "$TEST_ROOT/cmux-state"
cmux_bin() { printf '%s/test/fakes/cmux' "$REPO"; }

git init -q -b main "$TEST_ROOT/project"
git -C "$TEST_ROOT/project" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
git -C "$TEST_ROOT/project" worktree add -qb wt/task "$TEST_ROOT/project/.worktrees/task"

test_require_wt() {
  local REPO="$TEST_ROOT/project" n=unchanged branch=unchanged
  begin_scenario 'worktree outputs can use an internal local name' || return 0
  if require_wt task n branch show; then pass; else fail 'require_wt failed'; fi
  assert_eq 'the caller receives its path' "$TEST_ROOT/project/.worktrees/task" "$n"
  assert_eq 'the caller receives its branch' wt/task "$branch"
  end_scenario
}
test_require_wt

test_require_wt_command() {
  local REPO="$TEST_ROOT/project" path='' branch='' sub=show output rc=0
  begin_scenario 'the command argument controls missing-worktree records' || return 0
  output=$(WG_MACHINE_RESULT=1 require_wt missing path branch path 2>&1) || rc=$?
  assert_eq 'a missing path command fails' 1 "$rc"
  assert_eq "the path argument emits a missing record despite sub=$sub" missing \
    "$(wt_read_result "$output" path | jq -r .status)"
  sub=path; rc=0
  output=$(WG_MACHINE_RESULT=1 require_wt missing path branch show 2>&1) || rc=$?
  assert_eq 'a missing show command fails' 1 "$rc"
  rc=0
  wt_read_result "$output" path >/dev/null || rc=$?
  assert_eq "the show argument emits no record despite sub=$sub" 2 "$rc"
  end_scenario
}
test_require_wt_command

test_branch_landed() {
  local REPO="$TEST_ROOT/project" b=unchanged status=0
  begin_scenario 'branch reasons can use an internal local name' || return 0
  branch_landed missing main b || status=$?
  assert_eq 'a missing branch fails the check' 1 "$status"
  assert_eq 'the caller receives the branch reason' 'missing has no common history with main' "$b"
  end_scenario
}
test_branch_landed

test_rm_reasons() {
  local REPO="$TEST_ROOT/project" path="$TEST_ROOT/project/.worktrees/task"
  local dirty=(old)
  begin_scenario 'removal reasons fill and clear a caller array' || return 0
  printf 'unsaved\n' >"$path/scratch.txt"
  rm_reasons task "$path" wt/task missing dirty >"$TEST_ROOT/reasons-stdout"
  assert_eq 'the caller receives two reasons' 2 "${#dirty[@]}"
  assert_eq 'the dirty reason comes first' '1 uncommitted change(s)' "${dirty[0]}"
  assert_eq 'the base reason stays exact' "base 'missing' cannot be compared with wt/task (gone, or the literal HEAD)" "${dirty[1]}"
  assert_eq 'reasons do not go to stdout' '' "$(cat "$TEST_ROOT/reasons-stdout")"
  rm "$path/scratch.txt"
  rm_reasons task "$path" wt/task main dirty
  assert_eq 'a safe worktree clears earlier reasons' 0 "${#dirty[@]}"
  printf 'tracked\n' >"$path/tracked.txt"
  git -C "$path" add tracked.txt
  git -C "$path" -c user.name=Test -c user.email=test@example.com commit -qm change
  rm_reasons task "$path" wt/task main dirty
  assert_eq 'unmerged commits require a reason' 1 "${#dirty[@]}"
  rm_reasons task "$path" wt/task main dirty 1
  assert_eq 'the argument waives the commit reason' 0 "${#dirty[@]}"
  rm_reasons task "$path" wt/task main dirty
  assert_eq 'the waiver does not affect the next call' 1 "${#dirty[@]}"
  end_scenario
}
test_rm_reasons

test_check_row_removal() {
  local c=unchanged id=unchanged ROW_AGENT=''
  fake_rows "$(fake_row row-1 task '@local · project')" >"$FAKE_CMUX_STATE/rows.json"
  rows_json() { cmux_call workspace list --json; }
  row_agent() { ROW_AGENT=self; }
  begin_scenario 'row outputs can use internal local names' || return 0
  if check_row_removal task /repo/project c id; then pass; else fail 'check_row_removal failed'; fi
  assert_eq 'the caller receives its row' row-1 "$c"
  assert_eq 'the caller receives its ownership marker' self "$id"
  assert_eq 'the row ownership check ran' self "$ROW_AGENT"
  end_scenario
}
test_check_row_removal

test_row_shell_prompt() {
  local NAMED_SCREEN="$FAKE_CMUX_STATE/read-screen.json"
  local screen=unchanged host=unchanged status=0
  row_remote_field() { printf connected; }
  vm_session_detached() { printf '%s' "$1" >"$TEST_ROOT/detached-host"; }
  send_tmux_line() { printf '%s|%s' "$1" "$2" >"$TEST_ROOT/sent-line"; }
  begin_scenario 'screen and forwarded outputs can use internal local names' || return 0
  printf 'tester@machine %%\n' >"$NAMED_SCREEN"
  if row_shell_prompt row-1 screen; then pass; else fail 'row_shell_prompt failed'; fi
  assert_eq 'the caller receives the last screen line' 'tester@machine %' "$screen"
  if reattach_shell_row row-1 task-session host test-vm; then pass; else fail 'reattach_shell_row failed'; fi
  assert_eq 'the caller receives the forwarded line' 'tester@machine %' "$host"
  assert_eq 'the VM check keeps its host argument' test-vm "$(cat "$TEST_ROOT/detached-host")"
  assert_eq 'the send keeps its row and session arguments' 'row-1|task-session' "$(cat "$TEST_ROOT/sent-line")"
  printf 'Context 100%%\n' >"$NAMED_SCREEN"
  row_shell_prompt row-1 screen || status=$?
  assert_eq 'a footer fails the prompt check' 1 "$status"
  assert_eq 'the caller receives the rejected line' 'Context 100%' "$screen"
  rm "$NAMED_SCREEN"
  status=0
  row_shell_prompt row-1 screen || status=$?
  assert_eq 'an unavailable screen returns its status' 2 "$status"
  assert_eq 'an unavailable screen clears the caller output' '' "$screen"
  end_scenario
}
test_row_shell_prompt

test_relay_env() {
  local TMUX=''
  local -x CMUX_SOCKET_PATH=127.0.0.1:1111 CMUX_WORKSPACE_ID=workspace
  local -x CMUX_TUI_SOCKET=/tmp/native CMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local value=unchanged native_terminal=unchanged socket=unchanged
  local identity=() relay_vars=(unchanged)
  begin_scenario 'relay scalar and array outputs can use internal local names' || return 0
  if relay_env identity value native_terminal; then pass; else fail 'scalar relay output failed'; fi
  assert_eq 'the caller receives its scalar socket' /tmp/native "$value"
  assert_eq 'the caller receives its native terminal' term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$native_terminal"
  assert_eq 'the identity includes the socket assignment' CMUX_TUI_SOCKET=/tmp/native "${identity[0]}"
  if relay_env relay_vars socket native_terminal; then pass; else fail 'array relay output failed'; fi
  assert_eq 'an array output keeps the scalar socket' /tmp/native "$socket"
  assert_eq 'the caller receives its identity array' CMUX_TUI_SOCKET=/tmp/native "${relay_vars[0]}"
  end_scenario
}
test_relay_env

test_session_outputs() {
  local REPO="$TEST_ROOT/project" name output status
  local PATH="$TEST_ROOT/session-bin:$PATH"
  begin_scenario 'session outputs can use internal local names' || return 0
  mkdir -p "$TEST_ROOT/session-bin"
  cp "${BASH_SOURCE[0]%/*}/fakes/tmux" "${BASH_SOURCE[0]%/*}/fakes/pgrep" "$TEST_ROOT/session-bin/"
  chmod +x "$TEST_ROOT/session-bin/"*
  for name in s clients rc present; do
    status=0
    output=$(local -A "$name"; session_state task "$name"; local -n session_values=$name
      printf '%s|%s|%s' "${session_values["state"]}" "${session_values["agent"]}" "${session_values["attached"]}") || status=$?
    assert_eq "$name session output succeeds" 0 "$status"
    assert_eq "$name receives the session display and facts" 'agent running|true|true' "$output"
  done
  end_scenario
}
test_session_outputs

test_agent_outputs() {
  local name output status
  local PATH="$TEST_ROOT/agent-bin:$PATH"
  begin_scenario 'agent outputs can use internal local names' || return 0
  mkdir -p "$TEST_ROOT/agent-bin"
  cp "$REPO/test/fakes/tmux" "$REPO/test/fakes/pgrep" "$TEST_ROOT/agent-bin/"
  chmod +x "$TEST_ROOT/agent-bin/"*
  for name in err panes t rc; do
    status=0
    output=$(local "$name=unchanged"; tmux_agent task-session "$name"; printf '%s' "${!name}") || status=$?
    assert_eq "$name agent output succeeds" 0 "$status"
    assert_eq "$name receives the session existence fact" true "$output"
  done
  end_scenario
}
test_agent_outputs

lib_summary
