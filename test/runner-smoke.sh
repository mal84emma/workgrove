#!/usr/bin/env bash
# Check runner scheduling, discovery, failure logs, and descendant cleanup with scratch suites.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/runner-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT
mkdir -p "$TEST_ROOT/suites with spaces"
export RUNNER_TEST_STATE=$TEST_ROOT
cat >"$TEST_ROOT/suites with spaces/worker.sh" <<'WORKER'
#!/usr/bin/env bash
name=${0##*/}
printf 'start %s\n' "$name" >>"$RUNNER_TEST_STATE/events"
printf 'output from %s\n' "$name"
sleep 0.15
printf 'end %s\n' "$name" >>"$RUNNER_TEST_STATE/events"
[[ $name != failure.sh ]] || exit 7
WORKER
for name in first second third failure; do
  cp "$TEST_ROOT/suites with spaces/worker.sh" "$TEST_ROOT/suites with spaces/$name.sh"
done

capture_runner() {
  RUNNER_RC=0
  RUNNER_OUT=$(env -u ONLY -u GITHUB_ACTIONS KEEP='' JOBS="${RUNNER_JOBS:-2}" \
    "$BASH" "$REPO/test/run.sh" "$@" 2>&1) || RUNNER_RC=$?
}
check_contains() {
  if [[ $2 == *"$3"* ]]; then pass; else fail "$1: missing '$3'"; fi
}
max_workers() {
  awk '$1 == "start" {active++; if(active > maximum) maximum=active} $1 == "end" {active--} END {print maximum+0}' "$TEST_ROOT/events"
}

scenario_scheduling() {
  begin_scenario 'runner bounds workers and executes each task once' || return 0
  local jobs name
  for jobs in 1 2; do
    : >"$TEST_ROOT/events"
    RUNNER_JOBS=$jobs capture_runner "$TEST_ROOT/suites with spaces/first.sh" \
      "$TEST_ROOT/suites with spaces/second.sh" "$TEST_ROOT/suites with spaces/third.sh"
    assert_eq "$jobs worker run succeeds" 0 "$RUNNER_RC"
    assert_eq "$jobs worker limit holds" "$jobs" "$(max_workers)"
    assert_eq 'each task starts once' 3 "$(awk '$1 == "start" {n++} END {print n+0}' "$TEST_ROOT/events")"
    assert_eq 'each task finishes once' 3 "$(awk '$1 == "end" {n++} END {print n+0}' "$TEST_ROOT/events")"
    for name in first.sh second.sh third.sh; do
      assert_eq "$name starts once" 1 "$(awk -v name="$name" '$1 == "start" && $2 == name {n++} END {print n+0}' "$TEST_ROOT/events")"
      assert_eq "$name finishes once" 1 "$(awk -v name="$name" '$1 == "end" && $2 == name {n++} END {print n+0}' "$TEST_ROOT/events")"
    done
    check_contains 'the runner reports task time' "$RUNNER_OUT" 'task time:'
    check_contains 'the runner reports suite span' "$RUNNER_OUT" 'suite time:'
    check_contains 'the runner reports wall time' "$RUNNER_OUT" 'total wall time:'
  done
  end_scenario
}
scenario_scheduling

scenario_failures() {
  begin_scenario 'runner retains failure logs and finishes remaining tasks' || return 0
  : >"$TEST_ROOT/events"
  RUNNER_JOBS=1 capture_runner "$TEST_ROOT/suites with spaces/failure.sh" "$TEST_ROOT/suites with spaces/third.sh"
  assert_eq 'a failed task fails the runner' 1 "$RUNNER_RC"
  assert_eq 'later tasks still finish' 2 "$(awk '$1 == "end" {n++} END {print n+0}' "$TEST_ROOT/events")"
  check_contains 'the failed task log is complete' "$RUNNER_OUT" 'output from failure.sh'
  check_contains 'the original exit status is reported' "$RUNNER_OUT" '(exit 7)'
  local logs=${RUNNER_OUT##*runner logs kept in }
  assert_eq 'failure logs remain available' yes "$([[ -d $logs ]] && echo yes || echo no)"
  [[ ! -d $logs ]] || rm -rf "$logs"
  end_scenario
}
scenario_failures

scenario_invalid_input() {
  begin_scenario 'runner rejects invalid workers and missing suites' || return 0
  local jobs
  for jobs in 0 -1 invalid 1.5 08; do
    RUNNER_JOBS=$jobs capture_runner "$TEST_ROOT/suites with spaces/first.sh"
    assert_eq "$jobs is not a positive decimal worker count" 2 "$RUNNER_RC"
  done
  capture_runner "$TEST_ROOT/missing.sh"
  assert_eq 'a missing suite is an input error' 2 "$RUNNER_RC"
  RUNNER_RC=0
  RUNNER_OUT=$(ONLY=anything "$BASH" "$REPO/test/run.sh" 2>&1) || RUNNER_RC=$?
  assert_eq 'ONLY requires an explicit suite' 2 "$RUNNER_RC"
  end_scenario
}
scenario_invalid_input

scenario_discovery() {
  begin_scenario 'wt scenario discovery skips fixtures and tool checks' || return 0
  local listing rc=0
  listing=$(env -u ONLY TMPDIR="$TEST_ROOT/not-created" WT_BASH=missing PATH=/nonexistent \
    "$BASH" "$REPO/test/wt-smoke.sh" --list-scenarios)
  check_contains 'the registry retains scenario 11' "$listing" $'scenario_shared_helpers\t11.'
  assert_eq 'discovery creates no scratch directory' no "$([[ -e $TEST_ROOT/not-created ]] && echo yes || echo no)"
  listing=$(ONLY='11.*' "$BASH" "$REPO/test/wt-smoke.sh" --list-scenarios)
  assert_eq 'filtered discovery selects one ID' scenario_shared_helpers "${listing%%$'\t'*}"
  rc=0
  ONLY=unmatched "$BASH" "$REPO/test/wt-smoke.sh" --list-scenarios >/dev/null 2>&1 || rc=$?
  assert_eq 'unmatched discovery fails' 1 "$rc"
  rc=0
  "$BASH" "$REPO/test/wt-smoke.sh" --scenario '' >/dev/null 2>&1 || rc=$?
  assert_eq 'an empty exact scenario is invalid' 2 "$rc"
  rc=0
  "$BASH" "$REPO/test/wt-smoke.sh" --scenario unknown >/dev/null 2>&1 || rc=$?
  assert_eq 'an unknown exact scenario fails' 1 "$rc"
  listing=$(cd "$REPO/test" && ONLY='11.*' "$BASH" wt-smoke.sh --list-scenarios)
  assert_eq 'discovery supports a slash-free invocation' scenario_shared_helpers "${listing%%$'\t'*}"
  listing=$(cd "$REPO/test" && "$BASH" run.sh --help)
  check_contains 'the runner supports a slash-free invocation' "$listing" 'usage:'
  end_scenario
}
scenario_discovery

scenario_selection() {
  begin_scenario 'runner filters wt scenarios and dispatches exact IDs' || return 0
  RUNNER_RC=0
  RUNNER_OUT=$(ONLY='11.*' JOBS=2 "$BASH" "$REPO/test/run.sh" "$REPO/test/wt-smoke.sh" 2>&1) || RUNNER_RC=$?
  assert_eq 'filtered execution succeeds' 0 "$RUNNER_RC"
  assert_eq 'only one scenario executes' 1 "$(printf '%s\n' "$RUNNER_OUT" | awk '/^ok   / {n++} END {print n+0}')"
  check_contains 'scenario 11 still executes' "$RUNNER_OUT" 'ok   11.'
  RUNNER_RC=0
  RUNNER_OUT=$(env -u ONLY "$BASH" "$REPO/test/wt-smoke.sh" --scenario scenario_guard 2>&1) || RUNNER_RC=$?
  assert_eq 'an exact scenario executes' 0 "$RUNNER_RC"
  assert_eq 'exact selection cannot broaden to 10 or 11' 1 "$(printf '%s\n' "$RUNNER_OUT" | awk '/^ok   / {n++} END {print n+0}')"
  end_scenario
}
scenario_selection

wait_for_file() {
  local attempt
  for ((attempt=0; attempt<150; attempt++)); do [[ -s $1 ]] && return 0; sleep 0.02; done
  fail "worker did not create $1"
  return 1
}
assert_stopped() {
  local pid=$2 attempt
  for ((attempt=0; attempt<150; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then pass; return 0; fi
    sleep 0.02
  done
  fail "$1: process $pid survived cleanup"
  kill -KILL "$pid" 2>/dev/null || true
}
scenario_interruption() {
  begin_scenario 'runner interruption stops workers and descendants' || return 0
  cat >"$TEST_ROOT/signal.sh" <<'WORKER'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$RUNNER_TEST_STATE/child.pid"
sleep 60 &
printf '%s\n' "$!" >"$RUNNER_TEST_STATE/grandchild.pid"
wait "$!"
WORKER
  local runner rc=0 logs
  rm -f "$TEST_ROOT/child.pid" "$TEST_ROOT/grandchild.pid"
  env -u ONLY JOBS=1 "$BASH" "$REPO/test/run.sh" "$TEST_ROOT/signal.sh" >"$TEST_ROOT/signal.log" 2>&1 &
  runner=$!
  if wait_for_file "$TEST_ROOT/grandchild.pid"; then
    kill -TERM "$runner"
    wait "$runner" || rc=$?
    assert_eq 'TERM exits with its signal status' 143 "$rc"
    assert_stopped 'the child stops' "$(cat "$TEST_ROOT/child.pid")"
    assert_stopped 'the grandchild stops' "$(cat "$TEST_ROOT/grandchild.pid")"
  else
    kill -TERM "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
  fi
  logs=$(sed -n 's/^runner logs kept in //p' "$TEST_ROOT/signal.log")
  [[ ! -d $logs ]] || rm -rf "$logs"
  end_scenario
}
scenario_interruption

scenario_ignores_term() {
  begin_scenario 'runner interruption kills workers that ignore TERM' || return 0
  cat >"$TEST_ROOT/signal.sh" <<'WORKER'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" >"$RUNNER_TEST_STATE/child.pid"
sleep 60 &
printf '%s\n' "$!" >"$RUNNER_TEST_STATE/grandchild.pid"
wait "$!"
WORKER
  local runner rc=0 logs
  rm -f "$TEST_ROOT/child.pid" "$TEST_ROOT/grandchild.pid"
  env -u ONLY JOBS=1 "$BASH" "$REPO/test/run.sh" "$TEST_ROOT/signal.sh" >"$TEST_ROOT/signal.log" 2>&1 &
  runner=$!
  if wait_for_file "$TEST_ROOT/grandchild.pid"; then
    kill -TERM "$runner"
    wait "$runner" || rc=$?
    assert_eq 'TERM exits with its signal status' 143 "$rc"
    assert_stopped 'the child stops' "$(cat "$TEST_ROOT/child.pid")"
    assert_stopped 'the grandchild stops' "$(cat "$TEST_ROOT/grandchild.pid")"
  else
    kill -TERM "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
  fi
  logs=$(sed -n 's/^runner logs kept in //p' "$TEST_ROOT/signal.log")
  [[ ! -d $logs ]] || rm -rf "$logs"
  end_scenario
}
scenario_ignores_term

scenario_worker_crash() {
  begin_scenario 'runner crash handling stops orphaned suite processes' || return 0
  cat >"$TEST_ROOT/crash.sh" <<'WORKER'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$RUNNER_TEST_STATE/orphan.pid"
kill -KILL "$PPID"
sleep 60
WORKER
  capture_runner "$TEST_ROOT/crash.sh"
  assert_eq 'a worker crash fails the runner' 1 "$RUNNER_RC"
  check_contains 'missing worker results are reported' "$RUNNER_OUT" 'worker exited before reporting its result'
  assert_stopped 'the orphan stops' "$(cat "$TEST_ROOT/orphan.pid")"
  local logs=${RUNNER_OUT##*runner logs kept in }
  [[ ! -d $logs ]] || rm -rf "$logs"
  end_scenario
}
scenario_worker_crash
lib_summary
