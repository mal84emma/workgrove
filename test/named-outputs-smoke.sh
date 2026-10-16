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
trap lib_cleanup EXIT

eval "$(sed -n '/^require_wt()/,/^}/p' "$REPO/bin/wt")"

die() { printf '%s\n' "$*" >&2; return 1; }
warn() { printf '%s\n' "$*" >&2; }
wt_path() { printf '%s/project/.worktrees/%s' "$TEST_ROOT" "$1"; }
wt_branch() { printf 'wt/%s' "$1"; }

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

lib_summary 5
