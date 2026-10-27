#!/usr/bin/env bash
# This suite uses scratch SSH aliases and a fake ssh, and never contacts a configured host.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-hosts.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
case "$TEST_ROOT" in */wt-hosts.*) ;; *) echo "unsafe test root: $TEST_ROOT" >&2; exit 1 ;; esac
case "$TEST_ROOT/" in "$HOME/"*) echo "test root is inside HOME" >&2; exit 1 ;; esac
# shellcheck source=test/lib.sh
# shellcheck disable=SC1091
source "$REPO/test/lib.sh"
# shellcheck disable=SC2034
KEEP_LABEL='host test files'
trap lib_cleanup EXIT
python3 -B "$REPO/test/hosts_records_test.py"
mkdir -p "$TEST_ROOT/home/.ssh" "$TEST_ROOT/bin" "$TEST_ROOT/fixtures/pci/device0"
cat >"$TEST_ROOT/home/.ssh/config" <<'CONFIG'
Host alpha beta
Host down broken nogpu unified slow1 slow2
Host alpha
Host wildcard-*
Host !excluded
CONFIG
cat >"$TEST_ROOT/bin/uname" <<'UNAME'
#!/bin/sh
printf 'Darwin\n'
UNAME
cat >"$TEST_ROOT/bin/ssh.fixture" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_LOG"
if [[ "$host" == hang ]]; then cat >/dev/null; exec /bin/sleep 60; fi
if [[ "$PROBE_MODE" == doctor-source ]]; then
  cat >"$TEST_ROOT/$host.source"
  exit 0
fi
if [[ "$PROBE_MODE" == compatibility ]]; then
  [[ "$host" != unavailable ]] || { cat >/dev/null; exit 255; }
  HOME="$TEST_ROOT/$host" fake_ssh_run "$cmd"
  exit $?
fi
if [[ "$PROBE_MODE" == actual ]]; then
  script=$(mktemp "$TEST_ROOT/probe.XXXXXX")
  sed -e "s|/proc/meminfo|$TEST_ROOT/fixtures/meminfo|g" \
      -e "s|/sys/bus/pci/devices|$TEST_ROOT/fixtures/pci|g" >"$script"
  PROBE_HOST="$host" fake_ssh_run "$cmd" <"$script"
  rc=$?
  rm -f "$script"
  exit "$rc"
fi
cat >/dev/null
case "$host" in
  alpha) printf 'wt_version\t{"commit":"abc1234","protocol":1}\ncpu\t16\nmem_kib\t33554432\ngpu_status\tok\ngpu\t0\tNVIDIA A100\t40960\ngpu\t1\tNVIDIA A100\t40960\n' ;;
  beta) printf 'cpu\t4\nmem_kib\t8388608\ngpu_status\tunknown\n' ;;
  down) echo 'Permission denied (publickey).' >&2; exit 255 ;;
  broken) printf 'wt_version\t{"commit":"abc","protocol":"1"}\ncpu\tnot-a-number\nmem_kib\t\ngpu_status\tok\ngpu\tbad-index\tbroken\tunknown\n' ;;
  nogpu) printf 'cpu\t4\nmem_kib\t14680064\ngpu_status\tnone\n' ;;
  unified) printf 'cpu\t20\nmem_kib\t127631360\ngpu_status\tok\ngpu\t0\tNVIDIA GB10\t[N/A]\n' ;;
  limited|uncertain|invalid-enhanced)
    printf 'probe_schema\t2\ncpu\t128\nmem_kib\t1073741824\ngpu_status\tok\ngpu\t0\tSynthetic GPU\t40960\ngpu\t1\tSynthetic GPU\t40960\n'
    case "$host" in
      limited) printf 'capabilities\t{"schema":1,"capacity_verified":true,"cpu_logical":0,"memory_mib":8192,"gpu_allocation_verified":true,"gpu_indices":["1"]}\nreadiness\t{"schema":1,"ready":true,"status":"ready","issues":[],"warnings":["agent-command-unavailable"]}\n' ;;
      uncertain) printf 'capabilities\t{"schema":1,"capacity_verified":false,"cpu_logical":null,"memory_mib":null,"capacity_issues":["cpu-ancestors-hidden"],"gpu_allocation_verified":false}\nreadiness\t{"schema":1,"ready":false,"status":"incomplete","issues":["missing-prerequisites"]}\n' ;;
      invalid-enhanced) printf 'capabilities\t{"schema":1,"capacity_verified":true,"cpu_logical":"bad","memory_mib":1024}\nreadiness\tinvalid-json\n' ;;
    esac ;;
  slow1|slow2)
    : >"$TEST_ROOT/$host.start"
    other=slow1; [[ "$host" == slow1 ]] && other=slow2
    for _ in {1..40}; do [[ -e "$TEST_ROOT/$other.start" ]] && break; sleep .05; done
    [[ -e "$TEST_ROOT/$other.start" ]] || exit 88
    printf 'cpu\t2\nmem_kib\t4194304\ngpu_status\tnone\n' ;;
esac
exit $?
SSH
make_fake_ssh "$TEST_ROOT/bin/ssh" "$TEST_ROOT/bin/ssh.fixture"
cat >"$TEST_ROOT/bin/nvidia-smi" <<'NVIDIA'
#!/bin/sh
case "$PROBE_HOST" in
  warning) printf 'WARNING: infoROM is corrupted at gpu 0000:00:04.0\n0, Tesla V100-SXM2-16GB, 16160\n' ;;
  numericwarning) printf 'WARNING: bogus diagnostic, 123\n0, Tesla V100-SXM2-16GB, 16160\n' ;;
  duplicate) printf '0, Tesla V100-SXM2-16GB, 16160\n0, Tesla V100-SXM2-16GB, 16160\n' ;;
  unified) printf '0, NVIDIA GB10, [N/A]\n' ;;
  empty) : ;;
  stuck) exit 1 ;;
  *) exit 1 ;;
esac
NVIDIA
cat >"$TEST_ROOT/bin/timeout" <<'TIMEOUT'
#!/bin/sh
printf '%s\n' "$*" >>"$TIMEOUT_LOG"
[ "$1" = -k ] && [ "$2" = 2 ] && [ "$3" = 10 ] || exit 2
shift 3
[ "$PROBE_HOST" = stuck ] && exit 124
"$@"
TIMEOUT
chmod +x "$TEST_ROOT/bin/"*
printf 'MemTotal: 32100000 kB\n' >"$TEST_ROOT/fixtures/meminfo"
printf '0x8086\n' >"$TEST_ROOT/fixtures/pci/device0/vendor"
printf '0x030000\n' >"$TEST_ROOT/fixtures/pci/device0/class"

run_wt() {
  env -u CMUX_SSH_ATTEMPT_ID -u CMUX_SOCKET_PATH -u WT_HOST \
    HOME="$TEST_ROOT/home" TEST_ROOT="$TEST_ROOT" SSH_LOG="$TEST_ROOT/ssh.log" \
    TIMEOUT_LOG="$TEST_ROOT/timeout.log" PROBE_MODE="${PROBE_MODE:-records}" \
    PATH="$TEST_ROOT/bin:$PATH" "${WT_BASH:-bash}" "$REPO/bin/wt" "$@"
}

run_stubbed_probe() (
  # Shell functions model a client that survives KILL without starting a stuck process.
  local stub_mode=$1 stub_rc=${3:-0}
  WG_LIB_DIR="$REPO/lib/workgrove"
  TMPDIR="$TEST_ROOT"
  if [[ -n $2 ]]; then WG_HOST_PROBE_TIMEOUT=$2; else unset WG_HOST_PROBE_TIMEOUT; fi
  # shellcheck source=lib/workgrove/common.sh
  source "$REPO/lib/workgrove/common.sh"
  # shellcheck source=lib/workgrove/hosts.sh
  source "$REPO/lib/workgrove/hosts.sh"
  : >"$TEST_ROOT/probe-calls"
  ssh() { return "$stub_rc"; }
  sleep() { printf 'sleep %s\n' "$*" >>"$TEST_ROOT/probe-calls"; }
  kill() {
    printf 'kill %s\n' "$*" >>"$TEST_ROOT/probe-calls"
    [[ $stub_mode == running ]]
  }
  # shellcheck disable=SC2329
  wait() {
    printf 'wait %s\n' "$*" >>"$TEST_ROOT/probe-calls"
    builtin wait "$@"
  }
  probe_host alpha
)

scenario_records() {
  begin_scenario 'records, errors and concurrent order' || return 0
  json=$(run_wt hosts --json)
  assert_eq 'aliases and order' 'true' "$(printf '%s' "$json" | jq -r 'map(.host) == ["alpha","beta","broken","down","nogpu","slow1","slow2","unified"]')"
  assert_eq 'VM commit and protocol' true "$(jq -r '.[0] | .wt_commit == "abc1234" and .wt_protocol == 1' <<<"$json")"
  assert_eq 'old VM version stays unknown' true "$(jq -r '.[1] | has("wt_commit") and .wt_commit == null and .wt_protocol == null' <<<"$json")"
  assert_eq 'unreachable VM version stays unknown' true "$(jq -r '.[3] | has("wt_protocol") and .wt_commit == null and .wt_protocol == null' <<<"$json")"
  assert_eq 'malformed version fields become null together' true "$(jq -r '.[2] | .wt_commit == null and .wt_protocol == null' <<<"$json")"
  assert_eq 'two valid GPUs'   'true' "$(printf '%s' "$json" | jq -r '.[0] | .gpu_status == "ok" and (.gpus | length) == 2 and .memory_mib == 32768')"
  assert_eq 'invalid GPU field' 'true' "$(printf '%s' "$json" | jq -r '.[2] | .gpu_status == "unknown" and .gpus == [] and .cpu_logical == null')"
  assert_eq 'SSH failure reason' 'true' "$(printf '%s' "$json" | jq -r '.[3] | .status == "unavailable" and (.error | contains("Permission denied"))')"
  assert_eq 'confirmed absence' 'true' "$(printf '%s' "$json" | jq -r '.[4] | .gpu_status == "none" and .gpus == []')"
  assert_eq 'unknown VRAM retained' 'true' "$(printf '%s' "$json" | jq -r '.[7] | .gpu_status == "ok" and .gpus[0].memory_mib == null')"
  assert_eq 'only literal aliases contacted' '8' "$(wc -l <"$TEST_ROOT/ssh.log" | tr -d ' ')"
  assert_eq 'shared SSH options and keepalives' 'true' "$(awk '/BatchMode=yes/ && /ConnectionAttempts=1/ && /ServerAliveInterval=5/ && /ServerAliveCountMax=2/ {found=1} END {print found ? "true" : "false"}' "$TEST_ROOT/ssh.log")"
  assert_eq 'parallel probes met' 'true' "$([[ -e "$TEST_ROOT/slow1.start" && -e "$TEST_ROOT/slow2.start" ]] && echo true || echo false)"
  table=$(run_wt hosts)
  assert_eq 'table shows failure reason' 'true' "$([[ "$table" == *'Permission denied'* && "$table" == *'ERROR'* ]] && echo true || echo false)"
  assert_eq 'help succeeds' '0' "$(run_wt hosts --help >/dev/null; echo $?)"
  end_scenario
}
scenario_records

scenario_hardware_probe() {
  begin_scenario 'execute the real probe script with fake hardware commands' || return 0
  mkdir -p "$TEST_ROOT/home/.local/bin"
  printf '#!/bin/sh\nprintf '\''{"commit":"seeded","protocol":1}\\n'\''\n' >"$TEST_ROOT/home/.local/bin/wt"
  chmod +x "$TEST_ROOT/home/.local/bin/wt"
  PROBE_MODE=actual
  cat >"$TEST_ROOT/home/.ssh/config" <<'CONFIG'
Host warning numericwarning duplicate empty unified stuck pci
CONFIG
  json=$(run_wt hosts --json)
  assert_eq 'real probe reads installed wt version' true "$(jq -r 'all(.[]; .wt_commit == "seeded" and .wt_protocol == 1)' <<<"$json")"
  assert_eq 'warning cannot inflate GPU count' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "warning")][0] | .gpu_status == "unknown" and (.gpus | length) == 1 and .gpus[0].name == "Tesla V100-SXM2-16GB"')"
  assert_eq 'numeric warning cannot inflate GPU count' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "numericwarning")][0] | .gpu_status == "unknown" and (.gpus | length) == 1')"
  assert_eq 'duplicate GPU index cannot inflate count' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "duplicate")][0] | .gpu_status == "unknown" and (.gpus | length) == 2')"
  assert_eq 'successful empty query is no GPU' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "empty")][0] | .gpu_status == "none" and .gpus == []')"
  assert_eq 'PCI scan confirms no GPU' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "pci")][0] | .gpu_status == "none" and .gpus == []')"
  assert_eq 'N/A VRAM from probe' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "unified")][0] | .gpu_status == "ok" and .gpus[0].memory_mib == null')"
  assert_eq 'stalled nvidia-smi fails closed' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "stuck")][0] | .gpu_status == "none"')"
  assert_eq 'nvidia-smi has a kill deadline' '7' "$(wc -l <"$TEST_ROOT/timeout.log" | tr -d ' ')"
  end_scenario
}
scenario_hardware_probe

scenario_enhanced_reports() {
  begin_scenario 'effective reports never fall back to physical hardware' || return 0
  PROBE_MODE=records
  printf 'Host limited uncertain invalid-enhanced\n' >"$TEST_ROOT/home/.ssh/config"
  local json
  json=$(run_wt hosts --json)
  assert_eq 'verified fractional CPU capacity remains zero' true \
    "$(jq -r 'map(select(.host == "limited"))[0] | .capacity_verified == true and .cpu_logical == 0 and .memory_mib == 8192' <<<"$json")"
  assert_eq 'visible UUID filtering restricts GPU count' true \
    "$(jq -r 'map(select(.host == "limited"))[0] | (.gpus | length) == 1 and .gpu_allocation_verified == true' <<<"$json")"
  assert_eq 'doctor warnings do not change inventory fields or readiness' true \
    "$(jq -r 'map(select(.host == "limited"))[0] | .workgrove_ready == true and .readiness_issues == [] and (has("warnings") | not)' <<<"$json")"
  assert_eq 'SSH reachability remains separate from readiness' true \
    "$(jq -r 'map(select(.host == "uncertain"))[0] | .status == "available" and .workgrove_ready == false and .cpu_logical == null and .memory_mib == null' <<<"$json")"
  assert_eq 'malformed enhanced reports cannot become legacy physical capacity' true \
    "$(jq -r 'map(select(.host == "invalid-enhanced"))[0] | .capacity_verified == false and .cpu_logical == null and .memory_mib == null and .workgrove_ready == false' <<<"$json")"
  end_scenario
}
scenario_enhanced_reports

# shellcheck disable=SC2031  # run_stubbed_probe changes REPO only inside its subshell.
scenario_vm_compatibility() {
  begin_scenario 'installed VM capabilities identify legacy and unavailable hosts' || return 0
  local json command output
  mkdir -p "$TEST_ROOT/current/.local/bin" "$TEST_ROOT/legacy/.local/bin"
  ln -s "$REPO/bin/wt" "$TEST_ROOT/current/.local/bin/wt"
  printf '#!/bin/sh\nprintf '\''{"commit":"legacy","protocol":1}\n'\''\n' >"$TEST_ROOT/legacy/.local/bin/wt"
  chmod +x "$TEST_ROOT/legacy/.local/bin/wt"
  printf 'Host current legacy unavailable\n' >"$TEST_ROOT/home/.ssh/config"
  PROBE_MODE=compatibility
  json=$(run_wt hosts --json)
  assert_eq 'the current VM retains show facts through the uploaded version probe' true \
    "$(jq -r '.[0].wt_capabilities | index("show-facts") != null' <<<"$json")"
  assert_eq 'older VM commit and protocol remain available' true \
    "$(jq -r '.[1] | .wt_commit == "legacy" and .wt_protocol == 1 and .wt_capabilities == []' <<<"$json")"
  command=$(python3 - "$REPO/docs/vm-protocol.md" <<'PYTHON'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text().split("### Measure group B", 1)[1]
print(text.split("```bash\n", 1)[1].split("```", 1)[0].split(" | ", 1)[1])
PYTHON
  )
  output=$(bash -c "$command" <<<"$json")
  assert_eq 'the documented command lists every host with unknown capabilities' $'legacy\nunavailable' "$output"
  printf 'Group B fake VM check:\n%s\n' "$output"
  end_scenario
}
scenario_vm_compatibility

scenario_probe_deadline() {
  begin_scenario 'client deadline bounds an unresponsive SSH session' || return 0
  cat >"$TEST_ROOT/home/.ssh/config" <<'CONFIG'
Host hang
CONFIG
  local start=$SECONDS
  json=$(WG_HOST_PROBE_TIMEOUT=1 run_wt hosts --json)
  assert_eq 'deadline returns within five seconds' 1 "$((SECONDS - start < 5))"
  assert_eq 'hung SSH probe returns unavailable' 'true' "$(printf '%s' "$json" | jq -r '.[0] | .host == "hang" and .status == "unavailable" and (.error | contains("timed out after 1 seconds"))')"
  end_scenario
}
scenario_probe_deadline

scenario_probe_cleanup() {
  begin_scenario 'client deadline skips wait after KILL and preserves completed status' || return 0
  local rc=0
  run_stubbed_probe running 1 >"$TEST_ROOT/probe-out" 2>"$TEST_ROOT/probe-err" || rc=$?
  assert_eq 'unkillable client times out' 124 "$rc"
  assert_eq 'deadline polls ten times per second' 10 \
    "$(awk '$1 == "sleep" {n++} END {print n+0}' "$TEST_ROOT/probe-calls")"
  assert_grep 'deadline sends KILL' "$TEST_ROOT/probe-calls" 'kill -KILL '
  assert_eq 'deadline never waits for an unkillable client' 0 \
    "$(awk '$1 == "wait" {n++} END {print n+0}' "$TEST_ROOT/probe-calls")"
  assert_grep 'deadline reports its duration' "$TEST_ROOT/probe-err" 'timed out after 1 seconds'
  assert_eq 'deadline removes temporary output files' 0 \
    "$(find "$TEST_ROOT" -name 'wt-host-std*' | wc -l | tr -d ' ')"

  rc=0
  run_stubbed_probe running '' >"$TEST_ROOT/probe-out" 2>"$TEST_ROOT/probe-err" || rc=$?
  assert_eq 'default deadline times out' 124 "$rc"
  assert_eq 'default deadline remains twenty seconds' 200 \
    "$(awk '$1 == "sleep" {n++} END {print n+0}' "$TEST_ROOT/probe-calls")"
  assert_grep 'default deadline reports twenty seconds' "$TEST_ROOT/probe-err" 'timed out after 20 seconds'

  local status
  for status in 0 42 255; do
    rc=0
    run_stubbed_probe finished 1 "$status" >"$TEST_ROOT/probe-out" 2>"$TEST_ROOT/probe-err" || rc=$?
    assert_eq "completed SSH retains exit $status" "$status" "$rc"
    assert_eq "completed SSH with exit $status is reaped" 1 \
      "$(awk '$1 == "wait" {n++} END {print n+0}' "$TEST_ROOT/probe-calls")"
  done
  end_scenario
}
scenario_probe_cleanup

scenario_empty_config() {
  begin_scenario 'no SSH aliases' || return 0
  : >"$TEST_ROOT/home/.ssh/config"
  assert_eq 'no aliases' '[]' "$(run_wt hosts --json)"
  end_scenario
}
scenario_empty_config

scenario_invalid_timeout() {
  begin_scenario 'invalid host probe timeout' || return 0
  printf 'Host alpha\n' >"$TEST_ROOT/home/.ssh/config"
  local timeout json
  : >"$TEST_ROOT/ssh.log"
  for timeout in 0 -1 1.5 invalid 01 020 922337203685477581 9223372036854775807 \
      18446744073709551617 99999999999999999999999999999999999999999999999999; do
    json=$(WG_HOST_PROBE_TIMEOUT=$timeout run_wt hosts --json)
    assert_eq "$timeout timeout fails without probing" true \
      "$(jq -r '.[0] | .status == "unavailable" and (.error | contains("must be a positive integer in seconds"))' <<<"$json")"
  done
  assert_eq 'invalid timeouts never start SSH' 0 "$(wc -l <"$TEST_ROOT/ssh.log" | tr -d ' ')"
  end_scenario
}
scenario_invalid_timeout

scenario_timeout_boundary() {
  begin_scenario 'maximum host probe timeout is accepted without waiting' || return 0
  local timeout rc
  for timeout in 1 922337203685477579 922337203685477580; do
    rc=0
    run_stubbed_probe finished "$timeout" >"$TEST_ROOT/probe-out" 2>"$TEST_ROOT/probe-err" || rc=$?
    assert_eq "$timeout timeout accepts a completed SSH probe" 0 "$rc"
    assert_eq "$timeout timeout does not sleep" 0 \
      "$(awk '$1 == "sleep" {n++} END {print n+0}' "$TEST_ROOT/probe-calls")"
    assert_eq "$timeout timeout reaps the completed probe" 1 \
      "$(awk '$1 == "wait" {n++} END {print n+0}' "$TEST_ROOT/probe-calls")"
  done
  end_scenario
}
scenario_timeout_boundary

scenario_doctor_alias() {
  begin_scenario 'only the targeted doctor receives an SSH alias' || return 0
  local mode
  for mode in --json --environment; do
    : >"$TEST_ROOT/ssh.log"
    PROBE_MODE=doctor-source run_wt -H alpha doctor "$mode" >"$TEST_ROOT/doctor-output"
    assert_grep "doctor $mode passes the alias" "$TEST_ROOT/ssh.log" 'doctor --host alpha'
  done
  PROBE_MODE=doctor-source run_wt hosts --json >"$TEST_ROOT/inventory-output"
  assert_grep 'inventory keeps the probe command' "$TEST_ROOT/alpha.source" 'doctor --probe'
  if grep -F 'doctor --host' "$TEST_ROOT/alpha.source" >/dev/null; then
    fail 'inventory must not pass an alias'
  else
    pass
  fi
  end_scenario
}
scenario_doctor_alias
lib_summary
