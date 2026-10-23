#!/usr/bin/env bash
# Check Python isolation and the shared runtime entry point.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/python-runtime.XXXXXX")
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT

scenario_starts() {
  begin_scenario 'production Python starts use the shared runtime' || return 0
  local starts
  # shellcheck disable=SC2016  # Match shell variable names literally.
  starts=$(git -C "$REPO" grep -nE 'python3? |"\$wg_python"|"\$wg_candidate"' -- bin lib install.sh |
    grep -vE 'lib/workgrove/vm/python-runtime.sh:|install -y python3 |command -v python3 |wg_(select|run)_python[ ;]') || true
  assert_eq 'no shell starts outside the runtime' '' "$starts"
  end_scenario
}
scenario_starts

scenario_isolation() {
  begin_scenario 'POSIX runtime isolates imports and preserves arguments and status' || return 0
  mkdir -p "$TEST_ROOT/login" "$TEST_ROOT/modules"
  printf 'raise RuntimeError("login module imported")\n' >"$TEST_ROOT/login/json.py"
  printf 'raise RuntimeError("PYTHONPATH module imported")\n' >"$TEST_ROOT/modules/json.py"
  local rc=0
  (
    cd "$TEST_ROOT/login"
    PYTHONPATH="$TEST_ROOT/modules" PYTHONWARNINGS=error /bin/sh -c '
      . "$1"
      wg_run_python - "a value" "" <<'"'"'PYTHON'"'"'
import json, sys
assert sys.flags.isolated == 1
assert sys.dont_write_bytecode
assert sys.argv[1:] == ["a value", ""]
assert "error" not in sys.warnoptions
print(json.dumps("isolated"))
sys.exit(42)
PYTHON
    ' runtime "$REPO/lib/workgrove/vm/python-runtime.sh"
  ) >"$TEST_ROOT/output" 2>"$TEST_ROOT/error" || rc=$?
  assert_eq 'Python status survives the helper' 42 "$rc"
  assert_eq 'Python stdout survives the helper' '"isolated"' "$(cat "$TEST_ROOT/output")"
  assert_eq 'isolated imports produce no error' '' "$(cat "$TEST_ROOT/error")"
  end_scenario
}
scenario_isolation

scenario_exec() {
  begin_scenario 'runtime exec replaces the POSIX shell' || return 0
  local rc=0
  /bin/sh -c '
    . "$1"
    wg_run_python --exec -c "import os,sys; sys.exit(0 if os.getpid() == int(sys.argv[1]) else 2)" "$$"
    exit 3
  ' runtime "$REPO/lib/workgrove/vm/python-runtime.sh" || rc=$?
  assert_eq 'exec retains the shell process ID' 0 "$rc"
  end_scenario
}
scenario_exec
lib_summary
