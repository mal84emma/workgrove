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

eval "$(sed -n '/^require_wt()/,/^}/p' "$REPO/bin/wt")"
eval "$(sed -n '/^check_row_removal()/,/^}/p' "$REPO/bin/wt")"

die() { printf '%s\n' "$*" >&2; return 1; }
warn() { printf '%s\n' "$*" >&2; }
wt_path() { printf '%s/project/.worktrees/%s' "$TEST_ROOT" "$1"; }
wt_branch() { printf 'wt/%s' "$1"; }
cmux_bin() { printf '%s/cmux' "$TEST_ROOT"; }

cat >"$TEST_ROOT/cmux" <<'CMUX'
#!/usr/bin/env bash
case $1 in
  read-screen) cat "$NAMED_SCREEN" ;;
  ping) exit 0 ;;
esac
CMUX
chmod +x "$TEST_ROOT/cmux"

git init -q -b main "$TEST_ROOT/project"
git -C "$TEST_ROOT/project" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
git -C "$TEST_ROOT/project" worktree add -qb wt/task "$TEST_ROOT/project/.worktrees/task"

test_require_wt() {
  local REPO="$TEST_ROOT/project" n=unchanged branch=unchanged
  begin_scenario 'worktree outputs can use an internal local name'
  if require_wt task n branch; then pass; else fail 'require_wt failed'; fi
  assert_eq 'the caller receives its path' "$TEST_ROOT/project/.worktrees/task" "$n"
  assert_eq 'the caller receives its branch' wt/task "$branch"
  end_scenario
}
test_require_wt

test_branch_landed() {
  local REPO="$TEST_ROOT/project" b=unchanged status=0
  begin_scenario 'branch reasons can use an internal local name'
  branch_landed missing main b || status=$?
  assert_eq 'a missing branch fails the check' 1 "$status"
  assert_eq 'the caller receives the branch reason' 'missing has no common history with main' "$b"
  end_scenario
}
test_branch_landed

test_check_row_removal() {
  local c=unchanged id=unchanged ROW_AGENT=''
  rows_json() { printf '%s\n' '{"workspaces":[{"id":"row-1","title":"task","description":"@local · project"}]}'; }
  row_agent() { ROW_AGENT=self; }
  begin_scenario 'row outputs can use internal local names'
  if check_row_removal task /repo/project c id; then pass; else fail 'check_row_removal failed'; fi
  assert_eq 'the caller receives its row' row-1 "$c"
  assert_eq 'the caller receives its ownership marker' self "$id"
  assert_eq 'the row ownership check ran' self "$ROW_AGENT"
  end_scenario
}
test_check_row_removal

test_row_shell_prompt() {
  local -x NAMED_SCREEN="$TEST_ROOT/screen"
  local screen=unchanged host=unchanged tick=unchanged status=0
  row_remote_field() { printf connected; }
  vm_session_detached() { printf '%s' "$1" >"$TEST_ROOT/detached-host"; }
  send_tmux_line() { printf '%s|%s' "$1" "$2" >"$TEST_ROOT/sent-line"; }
  begin_scenario 'screen and forwarded outputs can use internal local names'
  printf 'tester@machine %%\n' >"$NAMED_SCREEN"
  if row_shell_prompt row-1 screen; then pass; else fail 'row_shell_prompt failed'; fi
  assert_eq 'the caller receives the last screen line' 'tester@machine %' "$screen"
  if reattach_shell_row row-1 task-session host test-vm; then pass; else fail 'reattach_shell_row failed'; fi
  assert_eq 'the caller receives the forwarded line' 'tester@machine %' "$host"
  assert_eq 'the VM check keeps its host argument' test-vm "$(cat "$TEST_ROOT/detached-host")"
  assert_eq 'the send keeps its row and session arguments' 'row-1|task-session' "$(cat "$TEST_ROOT/sent-line")"
  if reattach_recovered_row test-vm row-1 task-session tick; then pass; else fail 'reattach_recovered_row failed'; fi
  assert_eq 'the caller receives the output through both helpers' 'tester@machine %' "$tick"
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

lib_summary 21
