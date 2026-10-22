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
    # Callbacks can assign a global rc without changing the status of later callbacks.
    first() { printf "first:%s\n" "$1" >>"$2"; rc=0; return 9; }
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

scenario_repeated_source() {
  begin_scenario 'repeated sourcing preserves callbacks and pending cleanup paths' || return 0
  local rc=0
  LOG="$TEST_ROOT/repeated-callback" bash -c '
    source "$1/lib/workgrove/common.sh"
    record() { printf "callback:%s\n" "$1" >"$LOG"; }
    on_exit record
    touch "$2/pending"
    WT_TMPFILES+=("$2/pending")
    source "$1/lib/workgrove/common.sh"
    source "$1/lib/workgrove/task.sh"
    printf "%s\n" "${WG_EXIT_HANDLERS[@]}" >"$2/registry"
  ' bash "$REPO" "$TEST_ROOT" || rc=$?
  assert_eq 'repeated sourcing exits successfully' 0 "$rc"
  assert_eq 'cleanup and the callback remain registered once' $'wt_cleanup\nrecord' "$(cat "$TEST_ROOT/registry")"
  assert_eq 'the registered callback still runs' callback:0 "$(cat "$TEST_ROOT/repeated-callback" 2>/dev/null || true)"
  if [[ ! -e $TEST_ROOT/pending ]]; then pass; else fail 'repeated sourcing lost the cleanup path'; fi
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

scenario_cleanup_signal() {
  begin_scenario 'TERM during EXIT cleanup removes files and runs later callbacks' || return 0
  local rc=0
  bash -c '
    source "$1/lib/workgrove/common.sh"
    touch "$2/pending-cleanup"
    WT_TMPFILES+=("$2/pending-cleanup")
    record() { printf "done\n" >"$2"; }
    callback() { record "$1" "$LOG"; }
    on_exit callback
    rm() { kill -TERM "$BASHPID"; command rm "$@"; }
    exit 7
  ' bash "$REPO" "$TEST_ROOT" || rc=$?
  assert_eq 'TERM keeps its signal status during cleanup' 143 "$rc"
  assert_absent "$TEST_ROOT" pending-cleanup
  assert_eq 'later callbacks still run' 'done' "$(cat "$LOG")"
  end_scenario
}

scenario_subshell_cleanup() {
  begin_scenario 'subshell cleanup owns its files and preserves parent callbacks' || return 0
  local rc=0
  bash -c '
    source "$1/lib/workgrove/common.sh"
    touch "$2/parent-pending"
    wt_register_tmpfile "$2/parent-pending"
    record() { printf "parent\n" >>"$LOG"; }
    on_exit record
    output=$(
      touch "$2/subshell-pending"
      wt_register_tmpfile "$2/subshell-pending"
      kill -TERM "$BASHPID"
    )
    printf "%s\n" "$?" >"$2/subshell-status"
    [[ -e $2/parent-pending && ! -e $2/subshell-pending && ! -e $LOG ]] || exit 8
    (
      touch "$2/background-pending"
      wt_register_tmpfile "$2/background-pending"
      kill -TERM "$BASHPID"
    ) &
    wait "$!"
    printf "%s\n" "$?" >"$2/background-status"
    [[ -e $2/parent-pending && ! -e $2/background-pending && ! -e $LOG ]] || exit 9
  ' bash "$REPO" "$TEST_ROOT" || rc=$?
  assert_eq 'the parent keeps its pending file until exit' 0 "$rc"
  assert_eq 'the command substitution preserves TERM status' 143 "$(cat "$TEST_ROOT/subshell-status")"
  assert_eq 'the background subshell preserves TERM status' 143 "$(cat "$TEST_ROOT/background-status")"
  assert_absent "$TEST_ROOT" parent-pending
  assert_absent "$TEST_ROOT" subshell-pending
  assert_absent "$TEST_ROOT" background-pending
  assert_eq 'only the parent runs its callback' parent "$(cat "$LOG")"
  end_scenario
}

scenario_foreground_signal() {
  begin_scenario 'TERM cleans up without waiting for an active foreground command' || return 0
  local pid rc=0 attempt running=1
  bash -c '
    source "$1/lib/workgrove/common.sh"
    touch "$2/foreground-pending"
    wt_register_tmpfile "$2/foreground-pending"
    bash -c '\''
      touch "$1/foreground-ready"
      until [[ -e $1/foreground-release ]]; do sleep 0.01; done
      touch "$1/foreground-done"
    '\'' bash "$2"
  ' bash "$REPO" "$TEST_ROOT" >"$TEST_ROOT/foreground-output" 2>&1 &
  pid=$!
  for ((attempt=0; attempt<200; attempt++)); do
    [[ ! -e $TEST_ROOT/foreground-ready ]] || break
    sleep 0.01
  done
  if [[ -e $TEST_ROOT/foreground-ready ]]; then pass; else fail 'the foreground command did not start'; fi
  kill -TERM "$pid"
  for ((attempt=0; attempt<100; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then running=0; break; fi
    sleep 0.01
  done
  assert_eq 'the shell exits before the foreground command finishes' 0 "$running"
  touch "$TEST_ROOT/foreground-release"
  wait "$pid" || rc=$?
  for ((attempt=0; attempt<200; attempt++)); do
    [[ ! -e $TEST_ROOT/foreground-done ]] || break
    sleep 0.01
  done
  if [[ -e $TEST_ROOT/foreground-done ]]; then pass; else fail 'the foreground command did not finish'; fi
  assert_eq 'the interrupted shell keeps TERM status' 143 "$rc"
  assert_absent "$TEST_ROOT" foreground-pending
  end_scenario
}

scenario_setup_signal() {
  begin_scenario 'remote setup removes its diagnostic file after TERM' || return 0
  local rc=0
  mkdir -p "$TEST_ROOT/setup-bin" "$TEST_ROOT/setup-home" "$TEST_ROOT/setup-tmp"
  cat >"$TEST_ROOT/setup-bin/ssh" <<'SSH'
#!/usr/bin/env bash
find "$TMPDIR" -name 'wt-setup-error.*' -print >"$SIGNAL_MARKER"
kill -TERM "$PPID"
exit 1
SSH
  chmod +x "$TEST_ROOT/setup-bin/ssh"
  env HOME="$TEST_ROOT/setup-home" PATH="$TEST_ROOT/setup-bin:$PATH" TMPDIR="$TEST_ROOT/setup-tmp" \
    SIGNAL_MARKER="$TEST_ROOT/setup-interrupted" bash "$REPO/bin/wt" -H test-host setup \
    --root /persistent --storage os-disk >"$TEST_ROOT/setup-output" 2>&1 || rc=$?
  assert_eq 'TERM stops remote setup' 143 "$rc"
  if [[ -s $TEST_ROOT/setup-interrupted ]]; then pass; else fail 'setup did not create its diagnostic file'; fi
  assert_eq 'setup leaves no diagnostic file' '' "$(find "$TEST_ROOT/setup-tmp" -name 'wt-setup-error.*' -print)"
  end_scenario
}

scenario_host_signal() {
  begin_scenario 'host probes remove temporary files in their own subshells after TERM' || return 0
  local rc=0
  mkdir -p "$TEST_ROOT/host-bin" "$TEST_ROOT/host-home/.ssh" "$TEST_ROOT/host-tmp"
  printf 'Host test-host\n' >"$TEST_ROOT/host-home/.ssh/config"
  printf '#!/bin/sh\nprintf "Darwin\\n"\n' >"$TEST_ROOT/host-bin/uname"
  cat >"$TEST_ROOT/host-bin/ssh" <<'SSH'
#!/usr/bin/env bash
find "$TMPDIR" -name 'wt-host-*' -print >"$SIGNAL_MARKER"
kill -TERM "$PPID"
exit 1
SSH
  chmod +x "$TEST_ROOT/host-bin/"*
  env -u CMUX_SSH_ATTEMPT_ID HOME="$TEST_ROOT/host-home" PATH="$TEST_ROOT/host-bin:$PATH" \
    TMPDIR="$TEST_ROOT/host-tmp" SIGNAL_MARKER="$TEST_ROOT/host-interrupted" \
    bash "$REPO/bin/wt" hosts --json >"$TEST_ROOT/host-output" 2>"$TEST_ROOT/host-error" || rc=$?
  assert_eq 'hosts still records an interrupted probe' 0 "$rc"
  assert_eq 'the probe reports its signal status' 'SSH probe failed (exit 143)' "$(jq -r '.[0].error' "$TEST_ROOT/host-output")"
  assert_eq 'all host temporary files exist before interruption' 4 "$(wc -l <"$TEST_ROOT/host-interrupted" | tr -d ' ')"
  assert_eq 'the probe leaves no temporary file' '' "$(find "$TEST_ROOT/host-tmp" -name 'wt-host-*' -print)"
  rc=0
  # shellcheck disable=SC2016  # The child shell expands these arguments.
  env TMPDIR="$TEST_ROOT/host-tmp" bash -c '
    source "$1/lib/workgrove/common.sh"
    source "$1/lib/workgrove/hosts.sh"
    ssh_host_check() { kill -TERM "$BASHPID"; }
    (host_record test-host) &
    wait "$!"
  ' bash "$REPO" >"$TEST_ROOT/record-output" 2>&1 || rc=$?
  assert_eq 'TERM stops the host record worker' 143 "$rc"
  assert_eq 'the worker leaves no temporary file' '' "$(find "$TEST_ROOT/host-tmp" -name 'wt-host-*' -print)"
  end_scenario
}

LOG="$TEST_ROOT/handlers"; export LOG
scenario_exit_handlers
scenario_repeated_source
scenario_task_signal
LOG="$TEST_ROOT/cleanup-callback"
scenario_cleanup_signal
LOG="$TEST_ROOT/parent-callback"
scenario_subshell_cleanup
scenario_foreground_signal
scenario_setup_signal
scenario_host_signal
lib_summary
