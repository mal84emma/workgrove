#!/usr/bin/env bash
# Check Python isolation and the shared runtime entry point.
# shellcheck disable=SC2030,SC2031  # Each fixture process owns its environment changes.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/python-runtime.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT

scenario_starts() {
  begin_scenario 'production Python starts use the shared runtime' || return 0
  local starts direct
  # shellcheck disable=SC2016  # Match shell variable names literally.
  direct=$(git -C "$REPO" grep -nE '"\$wg_python"|"\$wg_candidate"|"\$wg_selected_python"' -- bin lib install.sh |
    grep -v 'lib/workgrove/vm/python-runtime.sh:') || true
  starts=$(git -C "$REPO" grep -nE 'python3? ' -- bin lib install.sh |
    grep -vE 'lib/workgrove/vm/python-runtime.sh:|install -y python3 |command -v python3 |wg_(select|run|run_selected)_python[ ;]') || true
  assert_eq 'no shell starts outside the runtime' '' "$starts"
  assert_eq 'no selected-interpreter starts outside the runtime' '' "$direct"
  end_scenario
}
scenario_starts

# shellcheck disable=SC2016  # The POSIX child expands its arguments.
scenario_isolation() {
  begin_scenario 'POSIX runtime isolates imports and preserves arguments and status' || return 0
  mkdir -p "$TEST_ROOT/login" "$TEST_ROOT/modules"
  printf 'raise RuntimeError("login module imported")\n' >"$TEST_ROOT/login/json.py"
  printf 'raise RuntimeError("PYTHONPATH module imported")\n' >"$TEST_ROOT/modules/json.py"
  local shell method rc
  for shell in /bin/sh "$(command -v dash || true)"; do
    [[ -n $shell ]] || continue
    for method in wg_run_python wg_run_selected_python; do
      rc=0
      (
    cd "$TEST_ROOT/login"
    PYTHONPATH="$TEST_ROOT/modules" PYTHONWARNINGS=error PYTHONPYCACHEPREFIX="$TEST_ROOT/ignored-cache" "$shell" -c '
      . "$1"
      [ "$2" != wg_run_selected_python ] || wg_select_python || exit
      "$2" - "a value" "" <<'"'"'PYTHON'"'"'
import json, sys
assert sys.flags.isolated == 1
assert sys.dont_write_bytecode
assert sys.pycache_prefix is None
assert sys.argv[1:] == ["a value", ""]
assert "error" not in sys.warnoptions
print(json.dumps("isolated"))
sys.exit(42)
PYTHON
    ' runtime "$REPO/lib/workgrove/vm/python-runtime.sh" "$method"
      ) >"$TEST_ROOT/output" 2>"$TEST_ROOT/error" || rc=$?
      assert_eq 'Python status survives the helper' 42 "$rc"
      assert_eq 'Python stdout survives the helper' '"isolated"' "$(cat "$TEST_ROOT/output")"
      assert_eq 'isolated imports produce no error' '' "$(cat "$TEST_ROOT/error")"
    done
  done
  end_scenario
}
scenario_isolation

# shellcheck disable=SC2016  # The POSIX child expands its arguments.
scenario_exec() {
  begin_scenario 'runtime exec replaces the POSIX shell' || return 0
  local shell method rc
  for shell in /bin/sh "$(command -v dash || true)"; do
    [[ -n $shell ]] || continue
    for method in wg_run_python wg_run_selected_python; do
      rc=0
  "$shell" -c '
    . "$1"
    [ "$2" != wg_run_selected_python ] || wg_select_python || exit
    "$2" --exec -c "import os,sys; sys.exit(0 if os.getpid() == int(sys.argv[1]) else 2)" "$$"
    exit 3
  ' runtime "$REPO/lib/workgrove/vm/python-runtime.sh" "$method" || rc=$?
      assert_eq 'exec retains the shell process ID' 0 "$rc"
    done
  done
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
  case "$*" in *" reinstall-flags") printf "%s\n" --with-tmux-conf --refresh-config ;; esac
fi
PYTHON
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/count/home/.local/bin/wt"
  chmod +x "$TEST_ROOT/count/bin/python3" "$TEST_ROOT/count/home/.local/bin/wt"
}

# shellcheck disable=SC2016  # Fixture scripts expand variables in their own process.
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
    PATH="${COUNT_REMOTE_PATH:-$PATH}" /bin/sh -c "$script"
  }
  case $1 in
    hosts) host_probe_source | /bin/sh ;;
    preflight)
      # Use the real preflight function without the separate installed-wt checks.
      host_preflight_source | sed '/^#!\/usr\/bin\/env sh/,$d' >"$TEST_ROOT/count/preflight"
      printf '\nwg_portable_preflight\n' >>"$TEST_ROOT/count/preflight"
      /bin/sh "$TEST_ROOT/count/preflight" ;;
    setup) host_setup test-host --root "$TEST_ROOT/count/root" --storage os-disk ;;
    setup-install|setup-missing)
      WG_LIB_DIR="$TEST_ROOT/count/lib"
      printf '#!/bin/sh\nprintf "probe\\n" >>"$COUNT_LOG"\nexit 1\n' >"$TEST_ROOT/count/bin/python3"
      printf '#!/bin/sh\nprintf "0\\n"\n' >"$TEST_ROOT/count/bin/id"
      cat >"$TEST_ROOT/count/bin/apt-get" <<'APT'
#!/bin/sh
printf '%s\n' "$*" >>"$COUNT_ARGS"
[ "$1" != install ] || cp "$COUNT_SAVED" "${COUNT_SAVED%/*}/bin/python3"
APT
      chmod +x "$TEST_ROOT/count/bin/id" "$TEST_ROOT/count/bin/apt-get"
      if [[ $1 == setup-missing ]]; then
        rm -f "$TEST_ROOT/count/bin/python3"
        export COUNT_REMOTE_PATH="$TEST_ROOT/count/bin"
        local tool
        for tool in env cp cat; do ln -sf "$(command -v "$tool")" "$TEST_ROOT/count/bin/$tool"; done
      fi
      export COUNT_SAVED="$TEST_ROOT/count/saved-python"
      # Exclude all real Python candidates while retaining package fixture tools.
      PATH="$TEST_ROOT/count/bin:/usr/bin:/bin"
      host_setup test-host --root "$TEST_ROOT/count/root" --storage os-disk ;;
    remote-doctor) host_environment_doctor test-host --json ;;
    doctor) cmd_environment_doctor --json ;;
    wt-doctor) bash "$REPO/bin/wt" doctor --environment --json ;;
    codex) check_codex ;;
    install) bash "$REPO/install.sh" --remote-root "$TEST_ROOT/count/root" ;;
    reinstall) WT_REMOTE_ROOT="$TEST_ROOT/count/root" bash "$REPO/install.sh" ;;
    ssh-host) bash "$REPO/bin/wt-ssh-host" --help ;;
    update)
      # Load the real handler; stop before any Git operation or installer start.
      # shellcheck disable=SC1090
      source <(sed -n '/^cmd_update()/,/^}/p' "$REPO/bin/wt")
      export WT_REMOTE_ROOT="$TEST_ROOT/count/root"
      # shellcheck disable=SC2329  # The sourced update handler calls this fixture.
      die() { exit 77; }
      local rc=0
      (cmd_update --with-tmux-conf --refresh-config) || rc=$?
      [[ $rc == 77 ]] ;;
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
    assert_eq "$operation isolated runs" "$runs" "$(grep -c '^-I$' "$TEST_ROOT/count/args" || true)"
    assert_eq "$operation runs disable bytecode" "$runs" "$(grep -c '^-B$' "$TEST_ROOT/count/args" || true)"
    cp "$TEST_ROOT/count/saved-python" "$TEST_ROOT/count/bin/python3"
  done <<'COUNTS'
hosts 1 2
preflight 1 1
setup 1 1
setup-install 2 1
setup-missing 1 1
remote-doctor 1 1
doctor 1 1
wt-doctor 1 1
codex 1 1
install 1 1
reinstall 1 1
ssh-host 1 1
ssh-check 1 1
update 1 3
COUNTS
  end_scenario
}
scenario_counts
# shellcheck disable=SC2016  # Fixture scripts expand variables in their own process.
scenario_reuse() {
  begin_scenario 'POSIX reuse validates environment changes and rejects inherited state' || return 0
  local shell mode rc
  runtime_count_fixture
  mkdir -p "$TEST_ROOT/count/tools"
  local tool
  for tool in cat cp rm chmod env mkdir; do ln -sf "$(command -v "$tool")" "$TEST_ROOT/count/tools/$tool"; done
  mkdir -p "$TEST_ROOT/count/other" "$TEST_ROOT/count/relative/bin" "$TEST_ROOT/count/next/bin"
  cp "$TEST_ROOT/count/bin/python3" "$TEST_ROOT/count/relative/bin/python3"
  cp "$TEST_ROOT/count/bin/python3" "$TEST_ROOT/count/next/bin/python3"
  cp "$TEST_ROOT/count/bin/python3" "$TEST_ROOT/count/missing-python"
  printf '#!/bin/sh\nprintf "foreign\\n" >>"$COUNT_LOG"\nexit 88\n' >"$TEST_ROOT/count/other-python"
  chmod +x "$TEST_ROOT/count/other-python"
  for shell in /bin/sh "$(command -v dash || true)"; do
    [[ -n $shell ]] || continue
    for mode in reuse path bare cwd-unavailable fresh-cwd-unavailable directory removed nonexecutable fresh inherited diagnostics; do
      : >"$TEST_ROOT/count/log"
      rc=0
      COUNT_LOG="$TEST_ROOT/count/log" COUNT_ARGS="$TEST_ROOT/count/args" \
      PATH="$TEST_ROOT/count/bin:$TEST_ROOT/count/tools" \
      wg_python="$TEST_ROOT/count/other-python" \
      wg_selected_python="$TEST_ROOT/count/other-python" \
      wg_selected_path="$TEST_ROOT/count/bin:$TEST_ROOT/count/tools" wg_selected_pwd="$(pwd -P && printf '.')" \
      "$shell" -c '
        . "$1"
        root=$2 mode=$3
        PATH="$root/bin:$root/tools"
        if [ "$mode" = inherited ]; then
          wg_run_selected_python -c run || exit
          env >"$root/environment"
          exit
        fi
        wg_select_python || exit
        case $mode in
          reuse) wg_run_selected_python -c first; wg_run_selected_python -c second ;;
          path) PATH="$root/next/bin:$PATH"; wg_run_selected_python -c run
            [ "$wg_python" = "$root/next/bin/python3" ] ;;
          cwd-unavailable|fresh-cwd-unavailable)
            pwd() { printf "unavailable directory\n" >&2; return 1; }
            if [ "$mode" = fresh-cwd-unavailable ]; then
              wg_run_python -c run
            else wg_run_selected_python -c run; fi 2>"$root/pwd-error" ;;
          bare)
            mkdir -p "$root/earlier"
            rm -f "$root/earlier/python3"
            cd "$root/relative/bin" || exit
            PATH="$root/earlier::$root/tools"
            wg_select_python || exit
            cp "$root/other-python" "$root/earlier/python3"
            wg_run_selected_python -c run ;;
          directory)
            cd "$root/relative" || exit
            PATH="bin:$PATH"
            wg_select_python || exit
            cd "$root/next" || exit
            wg_run_selected_python -c run
            case $wg_python in bin/python3|./bin/python3|"$root/next/bin/python3") ;; *) exit 8 ;; esac ;;
          removed|nonexecutable)
            if [ "$mode" = removed ]; then rm "$root/bin/python3"; else chmod -x "$root/bin/python3"; fi
            wg_run_selected_python -c run
            [ "$wg_python" = "$root/missing-python" ] ;;
          fresh) wg_run_python -c first; wg_run_python -c second ;;
          diagnostics)
            rm "$root/bin/python3" "$root/missing-python"
            PATH="$root/empty"
            wg_run_selected_python -c run && exit 9
            printf "%s\n" "$wg_python_issue" >"$root/issue"
            ;;
        esac
      ' runtime "$TEST_ROOT/count/lib/vm/python-runtime.sh" "$TEST_ROOT/count" "$mode" || rc=$?
      assert_eq "$shell $mode succeeds" 0 "$rc"
      local probes=2 runs=1
      case $mode in
        reuse) probes=1 runs=2 ;;
        directory) probes=3 ;;
        fresh) probes=3 runs=2 ;;
        cwd-unavailable|fresh-cwd-unavailable)
          assert_eq 'an unavailable directory adds no diagnostic' '' "$(cat "$TEST_ROOT/count/pwd-error")" ;;
        inherited) probes=1
          assert_eq 'runtime state is not exported' '' "$(grep '^wg_\(python\|selected_\)' "$TEST_ROOT/count/environment" || true)" ;;
        diagnostics) probes=1 runs=0
          assert_eq 'removed interpreter reports missing-python' missing-python "$(cat "$TEST_ROOT/count/issue")" ;;
      esac
      assert_eq "$shell $mode probes" "$probes" "$(grep -c '^probe$' "$TEST_ROOT/count/log" || true)"
      assert_eq "$shell $mode runs" "$runs" "$(grep -c '^run$' "$TEST_ROOT/count/log" || true)"
      cp "$TEST_ROOT/count/next/bin/python3" "$TEST_ROOT/count/bin/python3"
      chmod +x "$TEST_ROOT/count/bin/python3"
      cp "$TEST_ROOT/count/next/bin/python3" "$TEST_ROOT/count/missing-python"
    done
  done
  end_scenario
}
scenario_reuse
scenario_boundaries() {
  begin_scenario 'new processes and host scripts validate inherited selections' || return 0
  local operation
  runtime_count_fixture
  cp "$TEST_ROOT/count/bin/python3" "$TEST_ROOT/count/saved-python"
  for operation in hosts preflight setup remote-doctor doctor wt-doctor install reinstall ssh-host ssh-check; do
    : >"$TEST_ROOT/count/log"
    # These values model an unrelated caller or host with a previously selected interpreter.
    export wg_python="$TEST_ROOT/count/foreign" wg_selected_python="$TEST_ROOT/count/foreign"
    export wg_selected_path="$TEST_ROOT/count/bin:$PATH" wg_selected_pwd="$(pwd -P && printf '.')"
    count_operation "$operation" >"$TEST_ROOT/count/output" 2>"$TEST_ROOT/count/error"
    count_operation "$operation" >"$TEST_ROOT/count/output" 2>"$TEST_ROOT/count/error"
    unset wg_python wg_selected_python wg_selected_path wg_selected_pwd
    assert_eq "$operation selects once per independent operation or host" 2 "$(grep -c '^probe$' "$TEST_ROOT/count/log" || true)"
  done
  end_scenario
}
scenario_boundaries
# shellcheck disable=SC2016  # The POSIX child expands its arguments.
scenario_newline_directory() {
  begin_scenario 'relative Python paths preserve directory names ending in newlines' || return 0
  local shell method suffix directory rc real_python
  real_python=$(command -v python3)
  mkdir -p "$TEST_ROOT/newline/bin"
  printf '#!/bin/sh\nprintf "unvalidated-sibling\\n"\nexit 88\n' >"$TEST_ROOT/newline/bin/python3"
  chmod +x "$TEST_ROOT/newline/bin/python3"
  for shell in /bin/sh "$(command -v dash || true)"; do
    [[ -n $shell ]] || continue
    for suffix in $'\n' $'\n\n'; do
      directory="$TEST_ROOT/newline$suffix"
      mkdir -p "$directory/bin"
      ln -sf "$real_python" "$directory/bin/python3"
      for method in wg_run_python wg_run_selected_python; do
        rc=0
        (
          cd "$directory"
          PATH=bin:/usr/bin:/bin "$shell" -c '
            . "$1"
            [ "$2" != wg_run_selected_python ] || wg_select_python || exit
            "$2" -c "print(42)"
          ' runtime "$REPO/lib/workgrove/vm/python-runtime.sh" "$method"
        ) >"$TEST_ROOT/newline-output" 2>"$TEST_ROOT/newline-error" || rc=$?
        assert_eq "$shell $method validates the executable it starts" 0 "$rc"
        assert_eq 'the validated Python produces its output' 42 "$(cat "$TEST_ROOT/newline-output")"
        assert_eq 'the directory name adds no diagnostic' '' "$(cat "$TEST_ROOT/newline-error")"
      done
    done
  done
  end_scenario
}
scenario_newline_directory
lib_summary
