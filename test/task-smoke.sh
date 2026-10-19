#!/usr/bin/env bash
# Check task cleanup and the composable EXIT handler.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/task-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT

scenario_exit_handlers() {
  begin_scenario 'EXIT callbacks keep their order and the original status' || return 0
  local rc=0
  bash -c '
    source "$1/lib/workgrove/common.sh"
    first() { printf "first:%s\n" "$1" >>"$2"; return 9; }
    second() { printf "second:%s\n" "$1" >>"$2"; }
    # Callback functions receive one status argument.
    a() { first "$1" "$LOG"; }
    b() { second "$1" "$LOG"; }
    on_exit a
    on_exit b
    exit 7
  ' bash "$REPO" 2>"$TEST_ROOT/error" || rc=$?
  assert_eq 'the shell preserves the failing status' 7 "$rc"
  assert_eq 'callbacks run once and receive the failing status' $'first:7\nsecond:7' "$(cat "$TEST_ROOT/handlers")"
  end_scenario
}

scenario_task_signal() {
  begin_scenario 'wt task removes a sidecar temp file after TERM' || return 0
  local rc=0
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/project" "$TEST_ROOT/home"
  git init -qb main "$TEST_ROOT/project"
  git -C "$TEST_ROOT/project" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/fzf"
  # shellcheck disable=SC2016  # the stub reads its own argument
  printf '#!/bin/sh\n[ "$1" = -s ] && echo Darwin\n' >"$TEST_ROOT/bin/uname"
  cat >"$TEST_ROOT/bin/mv" <<'MV'
#!/usr/bin/env bash
case $1 in
  *.json.new.*)
    [[ -s $1 ]] || exit 2
    printf '%s\n' "$1" >"$SIGNAL_MARKER"
    kill -TERM "$PPID"
    exit 1 ;;
esac
exec /bin/mv "$@"
MV
  chmod +x "$TEST_ROOT/bin/"*
  printf 'signal-task\n' | env HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH" \
    SIGNAL_MARKER="$TEST_ROOT/interrupted" bash "$REPO/bin/wt" task --where local -a codex \
    -r "$TEST_ROOT/project" -p brief >"$TEST_ROOT/task-output" 2>&1 || rc=$?
  assert_eq 'TERM stops the task' 143 "$rc"
  if [[ -s $TEST_ROOT/interrupted ]]; then pass; else fail 'meta_set did not reach the rename'; fi
  local temp=''
  [[ ! -s $TEST_ROOT/interrupted ]] || temp=$(cat "$TEST_ROOT/interrupted")
  if [[ -n $temp && ! -e $temp ]]; then pass; else fail 'the sidecar temp file remains'; fi
  assert_eq 'no temp files remain in the sidecar directory' '' "$(find "$TEST_ROOT/project/.git/wt" -name '*.new.*' -print)"
  end_scenario
}
LOG="$TEST_ROOT/handlers"; export LOG
scenario_exit_handlers
scenario_task_signal
lib_summary
