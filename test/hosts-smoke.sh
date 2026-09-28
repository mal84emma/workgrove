#!/usr/bin/env bash
# Probe only scratch SSH aliases through a fake ssh; never contact a real host.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-hosts.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
case "$TEST_ROOT" in */wt-hosts.*) ;; *) echo "unsafe test root: $TEST_ROOT" >&2; exit 1 ;; esac
case "$TEST_ROOT/" in "$HOME/"*) echo "test root is inside HOME" >&2; exit 1 ;; esac
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/home/.ssh" "$TEST_ROOT/bin"
cat >"$TEST_ROOT/home/.ssh/config" <<'CONFIG'
Host alpha beta
Host down broken unified
Host alpha
Host wildcard-*
Host !invalid
CONFIG
cat >"$TEST_ROOT/bin/uname" <<'UNAME'
#!/bin/sh
printf 'Darwin\n'
UNAME
cat >"$TEST_ROOT/bin/ssh" <<'SSH'
#!/bin/sh
printf '%s\n' "$*" >>"$SSH_LOG"
cat >/dev/null
for arg do
  case "$arg" in alpha|beta|down|broken|unified) host=$arg ;; esac
done
case "$host" in
  alpha) printf 'cpu\t16\nmem_kib\t33554432\ngpu_status\tok\ngpu\tNVIDIA A100\t40960\ngpu\tNVIDIA A100\t40960\n' ;;
  beta) printf 'cpu\t4\nmem_kib\t8388608\ngpu_status\tunknown\n' ;;
  down) exit 255 ;;
  broken) printf 'cpu\tnot-a-number\nmem_kib\t\ngpu_status\tok\ngpu\tbroken\tunknown\n' ;;
  unified) printf 'cpu\t20\nmem_kib\t127631360\ngpu_status\tok\ngpu\tNVIDIA GB10\t[N/A]\n' ;;
esac
SSH
chmod +x "$TEST_ROOT/bin/uname" "$TEST_ROOT/bin/ssh"

run_wt() {
  env -u CMUX_SSH_ATTEMPT_ID -u CMUX_SOCKET_PATH -u WT_HOST \
    HOME="$TEST_ROOT/home" SSH_LOG="$TEST_ROOT/ssh.log" PATH="$TEST_ROOT/bin:$PATH" \
    "${WT_BASH:-bash}" "$REPO/bin/wt" "$@"
}

json=$(run_wt hosts --json)
printf '%s' "$json" | jq -e '
  length == 6 and
  (map(.host) == ["!invalid","alpha","beta","broken","down","unified"]) and
  (.[1] | .status == "available" and .cpu_logical == 16 and .memory_mib == 32768 and
          .gpu_status == "ok" and (.gpus | length) == 2 and .gpus[0].memory_mib == 40960) and
  (.[2] | .status == "available" and .cpu_logical == 4 and .gpu_status == "unknown") and
  (.[3] | .status == "available" and .cpu_logical == null and .memory_mib == null and
          .gpu_status == "ok" and .gpus[0].memory_mib == null) and
  (.[4] | .status == "unavailable" and .cpu_logical == null) and
  (.[5] | .status == "available" and .gpu_status == "ok" and
          .gpus[0].name == "NVIDIA GB10" and .gpus[0].memory_mib == null) and
  (.[0] | .status == "unavailable" and .error == "invalid SSH alias")
' >/dev/null
[[ $(wc -l <"$TEST_ROOT/ssh.log" | tr -d ' ') == 5 ]]
grep -q -- 'StrictHostKeyChecking=yes' "$TEST_ROOT/ssh.log"
table=$(run_wt hosts)
[[ "$table" == *"HOST"* && "$table" == *"NVIDIA A100"* && "$table" == *"NVIDIA GB10 (memory unknown)"* && "$table" == *"unavailable"* ]]
: >"$TEST_ROOT/home/.ssh/config"
[[ $(run_wt hosts --json) == '[]' ]]
echo 'hosts smoke test: ok'
