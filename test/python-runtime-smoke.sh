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
  local starts direct
  # shellcheck disable=SC2016  # Match shell variable names literally.
  direct=$(git -C "$REPO" grep -nE '"\$wg_python"|"\$wg_candidate"' -- bin lib install.sh |
    grep -v 'lib/workgrove/vm/python-runtime.sh:') || true
  starts=$(git -C "$REPO" grep -nE 'python3? ' -- bin lib install.sh |
    grep -vE 'lib/workgrove/vm/python-runtime.sh:|install -y python3 |command -v python3 |wg_(select|run)_python[ ;]') || true
  assert_eq 'no shell starts outside the runtime' '' "$starts"
  assert_eq 'no selected-interpreter starts outside the runtime' '' "$direct"
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
    PYTHONPATH="$TEST_ROOT/modules" PYTHONWARNINGS=error PYTHONPYCACHEPREFIX="$TEST_ROOT/ignored-cache" /bin/sh -c '
      . "$1"
      wg_run_python - "a value" "" <<'"'"'PYTHON'"'"'
import json, sys
assert sys.flags.isolated == 1
assert sys.dont_write_bytecode
assert sys.pycache_prefix is None
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

scenario_hash() {
  begin_scenario 'hash fallback ignores Python import overrides' || return 0
  mkdir -p "$TEST_ROOT/hash-modules"
  printf 'raise RuntimeError("hash override imported")\n' >"$TEST_ROOT/hash-modules/hashlib.py"
  printf abc >"$TEST_ROOT/hash-input"
  local hash
  hash=$(
    WG_VERSION_ROOT=$REPO
    # shellcheck source=lib/workgrove/safety.sh
    source "$REPO/lib/workgrove/safety.sh"
    have() { return 1; }
    export PYTHONPATH="$TEST_ROOT/hash-modules"
    file_hash "$TEST_ROOT/hash-input"
  )
  assert_eq 'fallback calculates SHA-256 in isolated mode' \
    ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$hash"
  end_scenario
}
scenario_hash
# Count version probes separately from operation starts without running setup code.
runtime_count_fixture() {
  mkdir -p "$TEST_ROOT/count/bin" "$TEST_ROOT/count/home/.local/bin" "$TEST_ROOT/count/lib/vm"
  cp "$REPO/lib/workgrove/vm/python-runtime.sh" "$TEST_ROOT/count/lib/vm/python-runtime.sh"
  cp "$REPO/lib/workgrove/portable.py" "$TEST_ROOT/count/lib/portable.py"
  # Replace only the system fallback in this scratch runtime.
  sed "s|/usr/bin/python3|$TEST_ROOT/count/missing-python|g" \
    "$REPO/lib/workgrove/vm/python-runtime.sh" >"$TEST_ROOT/count/lib/vm/python-runtime.sh"
  cat >"$TEST_ROOT/count/bin/python3" <<'PYTHON'
#!/bin/sh
if [ "$*" = '-I -B -c import sys; sys.exit(sys.version_info < (3, 9))' ]; then
  printf 'probe\n' >>"$COUNT_LOG"
else
  printf 'run\n' >>"$COUNT_LOG"
  printf '%s\n' "$@" >>"$COUNT_ARGS"
  [ "${3:-}" != - ] || cat >/dev/null
fi
PYTHON
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/count/home/.local/bin/wt"
  chmod +x "$TEST_ROOT/count/bin/python3" "$TEST_ROOT/count/home/.local/bin/wt"
}

count_operation() (
  export HOME="$TEST_ROOT/count/home" PATH="$TEST_ROOT/count/bin:$PATH"
  export COUNT_LOG="$TEST_ROOT/count/log" COUNT_ARGS="$TEST_ROOT/count/args"
  WG_LIB_DIR="$REPO/lib/workgrove"
  # shellcheck source=lib/workgrove/hosts.sh
  source "$REPO/lib/workgrove/hosts.sh"
  # shellcheck source=lib/workgrove/remote.sh
  source "$REPO/lib/workgrove/remote.sh"
  # shellcheck source=lib/workgrove/options.sh
  source "$REPO/lib/workgrove/options.sh"
  # shellcheck source=lib/workgrove/setup.sh
  source "$REPO/lib/workgrove/setup.sh"
  # shellcheck source=lib/workgrove/common.sh
  source "$REPO/lib/workgrove/common.sh"
  wt_register_tmpfile() { :; }
  vm_wt_failure() { return "$3"; }
  remote_sh() { /bin/sh -c "$2"; }
  remote_sh_raw() {
    # Simulate Ubuntu and package installation only in the scratch bootstrap.
    local script=${2//'. /etc/os-release'/'ID=ubuntu; VERSION_ID=24.04'}
    /bin/sh -c "$script"
  }
  case $1 in
    hosts) host_probe_source | /bin/sh ;;
    preflight)
      # Use the real preflight function without the separate installed-wt checks.
      host_preflight_source | sed '/^#!\/usr\/bin\/env sh/,$d' >"$TEST_ROOT/count/preflight"
      printf '\nwg_portable_preflight\n' >>"$TEST_ROOT/count/preflight"
      /bin/sh "$TEST_ROOT/count/preflight" ;;
    setup) host_setup test-host --root "$TEST_ROOT/count/root" --storage os-disk ;;
    setup-install)
      WG_LIB_DIR="$TEST_ROOT/count/lib"
      printf '#!/bin/sh\nprintf "probe\\n" >>"$COUNT_LOG"\nexit 1\n' >"$TEST_ROOT/count/bin/python3"
      printf '#!/bin/sh\nprintf "0\\n"\n' >"$TEST_ROOT/count/bin/id"
      cat >"$TEST_ROOT/count/bin/apt-get" <<'APT'
#!/bin/sh
printf '%s\n' "$*" >>"$COUNT_ARGS"
[ "$1" != install ] || cp "$COUNT_SAVED" "${COUNT_SAVED%/*}/bin/python3"
APT
      chmod +x "$TEST_ROOT/count/bin/id" "$TEST_ROOT/count/bin/apt-get"
      export COUNT_SAVED="$TEST_ROOT/count/saved-python"
      # Exclude all real Python candidates while retaining package fixture tools.
      PATH="$TEST_ROOT/count/bin:/usr/bin:/bin"
      host_setup test-host --root "$TEST_ROOT/count/root" --storage os-disk ;;
    remote-doctor) host_environment_doctor test-host --json ;;
    doctor) cmd_environment_doctor --json ;;
    codex) check_codex ;;
    install) bash "$REPO/install.sh" --remote-root "$TEST_ROOT/count/root" ;;
    reinstall) WT_REMOTE_ROOT="$TEST_ROOT/count/root" bash "$REPO/install.sh" ;;
    ssh-host) bash "$REPO/bin/wt-ssh-host" --help ;;
    ssh-check)
      mkdir -p "$HOME/.ssh"
      printf '# wt-ssh-host\n' >"$HOME/.ssh/config"
      WG_VERSION_ROOT=$REPO VM_SSH_CHECK_RUN=()
      # shellcheck source=lib/workgrove/common.sh
      source "$REPO/lib/workgrove/common.sh"
      ssh_host_check test-host ;;
  esac
)

scenario_counts() {
  begin_scenario 'operation version probes and Python starts have separate counts' || return 0
  local operation probes runs
  runtime_count_fixture
  cp "$TEST_ROOT/count/bin/python3" "$TEST_ROOT/count/saved-python"
  while read -r operation probes runs; do
    : >"$TEST_ROOT/count/log"
    : >"$TEST_ROOT/count/args"
    count_operation "$operation" >"$TEST_ROOT/count/output" 2>"$TEST_ROOT/count/error"
    assert_eq "$operation version probes" "$probes" "$(grep -c '^probe$' "$TEST_ROOT/count/log" || true)"
    assert_eq "$operation Python starts" "$runs" "$(grep -c '^run$' "$TEST_ROOT/count/log" || true)"
    cp "$TEST_ROOT/count/saved-python" "$TEST_ROOT/count/bin/python3"
  done <<'COUNTS'
hosts 3 2
preflight 2 1
setup 2 1
setup-install 3 1
remote-doctor 2 1
doctor 2 1
codex 1 1
install 2 1
reinstall 2 1
ssh-host 2 1
ssh-check 2 1
COUNTS
  end_scenario
}
scenario_counts
lib_summary
