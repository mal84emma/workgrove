#!/usr/bin/env bash
# Scratch SSH aliases and a fake ssh; never contact a configured host.
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
cat >"$TEST_ROOT/bin/ssh" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_LOG"
host=''
for arg do
  case "$arg" in alpha|beta|down|broken|nogpu|unified|slow1|slow2|warning|empty|stuck|pci) host=$arg ;; esac
done
if [[ "$PROBE_MODE" == actual ]]; then
  script=$(mktemp "$TEST_ROOT/probe.XXXXXX")
  sed -e "s|/proc/meminfo|$TEST_ROOT/fixtures/meminfo|g" \
      -e "s|/sys/bus/pci/devices|$TEST_ROOT/fixtures/pci|g" >"$script"
  PROBE_HOST="$host" /bin/sh "$script"
  rc=$?
  rm -f "$script"
  exit "$rc"
fi
cat >/dev/null
case "$host" in
  alpha) printf 'cpu\t16\nmem_kib\t33554432\ngpu_status\tok\ngpu\tNVIDIA A100\t40960\ngpu\tNVIDIA A100\t40960\n' ;;
  beta) printf 'cpu\t4\nmem_kib\t8388608\ngpu_status\tunknown\n' ;;
  down) echo 'Permission denied (publickey).' >&2; exit 255 ;;
  broken) printf 'cpu\tnot-a-number\nmem_kib\t\ngpu_status\tok\ngpu\tbroken\tunknown\n' ;;
  nogpu) printf 'cpu\t4\nmem_kib\t14680064\ngpu_status\tnone\n' ;;
  unified) printf 'cpu\t20\nmem_kib\t127631360\ngpu_status\tok\ngpu\tNVIDIA GB10\t[N/A]\n' ;;
  slow1|slow2)
    : >"$TEST_ROOT/$host.start"
    other=slow1; [[ "$host" == slow1 ]] && other=slow2
    for _ in {1..40}; do [[ -e "$TEST_ROOT/$other.start" ]] && break; sleep .05; done
    [[ -e "$TEST_ROOT/$other.start" ]] || exit 88
    printf 'cpu\t2\nmem_kib\t4194304\ngpu_status\tnone\n' ;;
esac
SSH
cat >"$TEST_ROOT/bin/nvidia-smi" <<'NVIDIA'
#!/bin/sh
case "$PROBE_HOST" in
  warning) printf 'WARNING: infoROM is corrupted at gpu 0000:00:04.0\nTesla V100-SXM2-16GB, 16160\n' ;;
  unified) printf 'NVIDIA GB10, [N/A]\n' ;;
  empty) : ;;
  stuck) exit 1 ;;
  *) exit 1 ;;
esac
NVIDIA
cat >"$TEST_ROOT/bin/timeout" <<'TIMEOUT'
#!/bin/sh
printf '%s\n' "$1" >>"$TIMEOUT_LOG"
[ "$1" = 10 ] || exit 2
shift
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

begin_scenario 'records, errors and concurrent order'
json=$(run_wt hosts --json)
assert_eq 'aliases and order' 'true' "$(printf '%s' "$json" | jq -r 'map(.host) == ["alpha","beta","broken","down","nogpu","slow1","slow2","unified"]')"
assert_eq 'two valid GPUs' 'true' "$(printf '%s' "$json" | jq -r '.[0] | .gpu_status == "ok" and (.gpus | length) == 2 and .memory_mib == 32768')"
assert_eq 'invalid GPU field' 'true' "$(printf '%s' "$json" | jq -r '.[2] | .gpu_status == "unknown" and .gpus == [] and .cpu_logical == null')"
assert_eq 'SSH failure reason' 'true' "$(printf '%s' "$json" | jq -r '.[3] | .status == "unavailable" and (.error | contains("Permission denied"))')"
assert_eq 'confirmed absence' 'true' "$(printf '%s' "$json" | jq -r '.[4] | .gpu_status == "none" and .gpus == []')"
assert_eq 'unknown VRAM retained' 'true' "$(printf '%s' "$json" | jq -r '.[7] | .gpu_status == "ok" and .gpus[0].memory_mib == null')"
assert_eq 'only literal aliases contacted' '8' "$(wc -l <"$TEST_ROOT/ssh.log" | tr -d ' ')"
assert_eq 'strict SSH and keepalives' 'true' "$(awk '/StrictHostKeyChecking=yes/ && /ServerAliveInterval=5/ && /ServerAliveCountMax=2/ {found=1} END {print found ? "true" : "false"}' "$TEST_ROOT/ssh.log")"
assert_eq 'parallel probes met' 'true' "$([[ -e "$TEST_ROOT/slow1.start" && -e "$TEST_ROOT/slow2.start" ]] && echo true || echo false)"
table=$(run_wt hosts)
assert_eq 'table shows failure reason' 'true' "$([[ "$table" == *'Permission denied'* && "$table" == *'ERROR'* ]] && echo true || echo false)"
assert_eq 'help succeeds' '0' "$(run_wt hosts --help >/dev/null; echo $?)"
end_scenario

begin_scenario 'execute the real probe script with fake hardware commands'
PROBE_MODE=actual
cat >"$TEST_ROOT/home/.ssh/config" <<'CONFIG'
Host warning empty unified stuck pci
CONFIG
json=$(run_wt hosts --json)
assert_eq 'warning cannot inflate GPU count' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "warning")][0] | .gpu_status == "unknown" and (.gpus | length) == 1 and .gpus[0].name == "Tesla V100-SXM2-16GB"')"
assert_eq 'successful empty query is no GPU' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "empty")][0] | .gpu_status == "none" and .gpus == []')"
assert_eq 'PCI scan confirms no GPU' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "pci")][0] | .gpu_status == "none" and .gpus == []')"
assert_eq 'N/A VRAM from probe' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "unified")][0] | .gpu_status == "ok" and .gpus[0].memory_mib == null')"
assert_eq 'stalled nvidia-smi fails closed' 'true' "$(printf '%s' "$json" | jq -r '[.[] | select(.host == "stuck")][0] | .gpu_status == "none"')"
assert_eq 'nvidia-smi has a time limit' '5' "$(wc -l <"$TEST_ROOT/timeout.log" | tr -d ' ')"
end_scenario

: >"$TEST_ROOT/home/.ssh/config"
assert_eq 'no aliases' '[]' "$(run_wt hosts --json)"
lib_summary 18
