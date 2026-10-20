#!/usr/bin/env bash
# Run suites and intact wt scenarios with one worker limit and separate logs.
set -euo pipefail
if ((BASH_VERSINFO[0] < 5)); then
  echo 'test/run.sh needs bash 5 or later on PATH' >&2
  exit 2
fi
STARTED=${EPOCHREALTIME/./}
SOURCE_DIR=${BASH_SOURCE[0]%/*}
[[ $SOURCE_DIR != "${BASH_SOURCE[0]}" ]] || SOURCE_DIR=.
REPO=$(cd "$SOURCE_DIR/.." && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=test/runner-git.sh
source "$REPO/test/runner-git.sh"

JOBS=${JOBS:-4}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer' >&2; exit 2; }
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  echo 'usage: JOBS=4 bash test/run.sh [suite.sh ...]'
  echo 'Use ONLY with one selected suite. KEEP=1 preserves all runner logs.'
  exit 0
fi
if [[ -n ${ONLY:-} && $# -ne 1 ]]; then
  echo 'ONLY requires one suite argument; for example: ONLY="11.*" bash test/run.sh test/wt-smoke.sh' >&2
  exit 2
fi
SUITES=("$@")
# Discover every smoke suite, including docs-smoke.sh, for local and CI runs.
if ((${#SUITES[@]} == 0)); then SUITES=("$REPO"/test/*-smoke.sh); fi
for suite in "${SUITES[@]}"; do
  [[ -f $suite ]] || { printf 'suite not found: %s\n' "$suite" >&2; exit 2; }
done

RUN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workgrove-tests.XXXXXX")
RUN_ROOT=$(cd "$RUN_ROOT" && pwd -P)
TASK_SUITES=() TASK_IDS=() TASK_NAMES=() TASK_PRIORITIES=() TASK_PIDS=()
TASK_STARTS=()
SUITE_PATHS=() SUITE_STARTS=() SUITE_ENDS=()
TASK_SUITE_INDEX=() ORDER=()
FAILED=0 INTERRUPTED=0 ACTIVE=0 FINISHED=0

runner_cleanup() {
  local status=$? pid attempt running
  trap - EXIT INT TERM
  if ((ACTIVE > 0)); then
    for pid in "${TASK_PIDS[@]}"; do
      [[ -n $pid ]] || continue
      kill -TERM -- "-$pid" 2>/dev/null || true
    done
    # Let nested runners propagate TERM before stopping workers that ignore it.
    for ((attempt=0; attempt<10; attempt++)); do
      running=0
      for pid in "${TASK_PIDS[@]}"; do
        [[ -n $pid ]] || continue
        if kill -0 -- "-$pid" 2>/dev/null; then running=1; fi
      done
      ((running != 0)) || break
      sleep 0.05
    done
    for pid in "${TASK_PIDS[@]}"; do
      [[ -n $pid ]] || continue
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  if [[ -n ${KEEP:-} || $FAILED -ne 0 || $INTERRUPTED -ne 0 || $status -ne 0 ]]; then
    printf 'runner logs kept in %s\n' "$RUN_ROOT"
  else
    rm -rf "$RUN_ROOT"
  fi
}
trap runner_cleanup EXIT
trap 'INTERRUPTED=1; exit 130' INT
trap 'INTERRUPTED=1; exit 143' TERM

queue_task() {
  local suite=$1 id=$2 name=$3 suite_index=$4 priority=1
  # Start the expensive groups early so shorter tasks can fill the remaining slots.
  case ${suite##*/}:$id in
    wt-smoke.sh:scenario_cmux|wt-smoke.sh:scenario_squash_merge|github-guard-smoke.sh:|install-smoke.sh:) priority=0 ;;
  esac
  TASK_SUITES+=("$suite") TASK_IDS+=("$id") TASK_NAMES+=("$name")
  TASK_PRIORITIES+=("$priority") TASK_SUITE_INDEX+=("$suite_index")
}

for suite in "${SUITES[@]}"; do
  index=${#SUITE_PATHS[@]}
  SUITE_PATHS+=("$suite") SUITE_STARTS+=(0) SUITE_ENDS+=(0)
  if [[ $suite -ef $REPO/test/wt-smoke.sh ]]; then
    if ! "$BASH" "$suite" --list-scenarios >"$RUN_ROOT/discovery.log"; then
      echo 'wt scenario discovery failed' >&2
      exit 1
    fi
    while IFS=$'\t' read -r id name; do
      [[ -n $id && -n $name ]] || { echo 'invalid wt scenario registration' >&2; exit 1; }
      queue_task "$suite" "$id" "$name" "$index"
    done <"$RUN_ROOT/discovery.log"
  else
    queue_task "$suite" '' "${suite##*/}" "$index"
  fi
done
TOTAL=${#TASK_SUITES[@]}
((TOTAL > 0)) || { echo 'no test tasks selected' >&2; exit 1; }
for priority in 0 1; do
  for ((index=0; index<TOTAL; index++)); do
    if [[ ${TASK_PRIORITIES[$index]} == "$priority" ]]; then ORDER+=("$index"); fi
  done
done
# Limit very large decimal values without overflowing shell arithmetic.
if ((${#JOBS} > 6)); then LIMIT=$TOTAL; elif ((JOBS > TOTAL)); then LIMIT=$TOTAL; else LIMIT=$JOBS; fi

GIT_DIRECTORY=$(runner_git_dir "$(uname -s)" "$(command -v git || true)" "$RUN_ROOT")
if [[ -n $GIT_DIRECTORY ]]; then
  export PATH="$GIT_DIRECTORY:$PATH"
  echo 'Git: resolved Apple developer-tools binary'
fi
printf 'Running %d tasks from %d suites with at most %d workers\n' "$TOTAL" "${#SUITE_PATHS[@]}" "$LIMIT"

run_task() {
  trap - EXIT INT TERM
  set +m
  local index=$1 rc=0 started=${EPOCHREALTIME/./} ended
  if [[ -n ${TASK_IDS[$index]} ]]; then
    "$BASH" "${TASK_SUITES[$index]}" --scenario "${TASK_IDS[$index]}" || rc=$?
  else
    "$BASH" "${TASK_SUITES[$index]}" || rc=$?
  fi
  ended=${EPOCHREALTIME/./}
  printf '%s\t%s\t%s\n' "$rc" "$started" "$ended" >"$RUN_ROOT/$index.status"
  return "$rc"
}

stop_worker_group() {
  local pid=$1
  kill -TERM -- "-$pid" 2>/dev/null || true
  if kill -0 -- "-$pid" 2>/dev/null; then
    sleep 0.05
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
}

collect_task() {
  local index=$1 rc=0 started ended suite_index elapsed now recorded_rc status_error=''
  local records=() status_pattern
  wait "${TASK_PIDS[$index]}" || rc=$?
  now=${EPOCHREALTIME/./}
  if [[ -f $RUN_ROOT/$index.status ]]; then
    mapfile -t records <"$RUN_ROOT/$index.status"
    # Bound digit counts before arithmetic. Leading zeros and additional fields are invalid.
    status_pattern=$'^(0|[1-9][0-9]{0,2})\t([1-9][0-9]{0,17})\t([1-9][0-9]{0,17})$'
    if ((${#records[@]} != 1)); then
      status_error='expected exactly one status line'
    elif [[ ! ${records[0]} =~ $status_pattern ]]; then
      status_error='expected three canonical numeric fields separated by tabs'
    else
      recorded_rc=${BASH_REMATCH[1]}
      started=${BASH_REMATCH[2]} ended=${BASH_REMATCH[3]}
      if ((recorded_rc > 255 || recorded_rc != rc)); then
        status_error='exit status is invalid or differs from the worker result'
      fi
    fi
    if [[ -n $status_error ]]; then
      stop_worker_group "${TASK_PIDS[$index]}"
      printf 'invalid worker status: %s\n' "$status_error" >>"$RUN_ROOT/$index.log"
      started=${TASK_STARTS[$index]} ended=$now
      ((rc != 0)) || rc=1
    fi
  else
    # A crashed worker can leave its suite running in the original process group.
    stop_worker_group "${TASK_PIDS[$index]}"
    started=${TASK_STARTS[$index]}
    ended=${EPOCHREALTIME/./}
    printf 'worker exited before reporting its result\n' >>"$RUN_ROOT/$index.log"
    ((rc != 0)) || rc=1
  fi
  TASK_PIDS[index]=''
  suite_index=${TASK_SUITE_INDEX[$index]}
  if ((ended > SUITE_ENDS[suite_index])); then SUITE_ENDS[suite_index]=$ended; fi
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then printf '::group::%s\n' "${TASK_NAMES[$index]}"; fi
  printf '\n--- %s: %s ---\n' "${TASK_SUITES[$index]##*/}" "${TASK_NAMES[$index]}"
  cat "$RUN_ROOT/$index.log"
  elapsed=$((ended - started)); ((elapsed >= 0)) || elapsed=0
  printf 'task time: %s: %s s (exit %s)\n' "${TASK_NAMES[$index]}" "$(lib_seconds "$elapsed")" "$rc"
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    echo '::endgroup::'
    if ((rc != 0)); then printf '::error::%s failed (exit %s)\n' "${TASK_NAMES[$index]}" "$rc"; fi
  fi
  if ((rc != 0)); then FAILED=$((FAILED + 1)); fi
  ACTIVE=$((ACTIVE - 1)); FINISHED=$((FINISHED + 1))
}

# Job control gives each worker a process group for interruption cleanup.
set -m
NEXT=0
while ((FINISHED < TOTAL)); do
  while ((ACTIVE < LIMIT && NEXT < TOTAL)); do
    index=${ORDER[$NEXT]}
    TASK_STARTS[index]=${EPOCHREALTIME/./}
    suite_index=${TASK_SUITE_INDEX[$index]}
    if ((SUITE_STARTS[suite_index] == 0)); then SUITE_STARTS[suite_index]=${TASK_STARTS[$index]}; fi
    run_task "$index" >"$RUN_ROOT/$index.log" 2>&1 &
    TASK_PIDS[index]=$!
    ACTIVE=$((ACTIVE + 1)); NEXT=$((NEXT + 1))
  done
  COLLECTED=0
  for ((index=0; index<TOTAL; index++)); do
    [[ -n ${TASK_PIDS[$index]:-} ]] || continue
    if [[ -f $RUN_ROOT/$index.status ]] || ! kill -0 "${TASK_PIDS[$index]}" 2>/dev/null; then
      collect_task "$index"
      COLLECTED=1
    fi
  done
  if ((COLLECTED == 0 && ACTIVE > 0)); then wait -n || true; fi
done
set +m
printf '\nSuite elapsed spans (first worker start to last worker finish):\n'
for ((index=0; index<${#SUITE_PATHS[@]}; index++)); do
  elapsed=$((SUITE_ENDS[index] - SUITE_STARTS[index])); ((elapsed >= 0)) || elapsed=0
  printf 'suite time: %s: %s s\n' "${SUITE_PATHS[$index]##*/}" "$(lib_seconds "$elapsed")"
done
elapsed=$((${EPOCHREALTIME/./} - STARTED)); ((elapsed >= 0)) || elapsed=0
printf 'total wall time: %s s; %d tasks, %d failed\n' "$(lib_seconds "$elapsed")" "$TOTAL" "$FAILED"
((FAILED == 0))
