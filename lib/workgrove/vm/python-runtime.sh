# shellcheck shell=sh
# shellcheck disable=SC2034
# Use the same isolated interpreter on the Mac and the VM.
wg_select_python() {
  wg_python='' wg_python_issue=missing-python
  for wg_candidate in "$(command -v python3 || true)" /usr/bin/python3; do
    [ -n "$wg_candidate" ] && [ -x "$wg_candidate" ] || continue
    wg_python_issue=python-3.9-required
    if "$wg_candidate" -I -B -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
      wg_python=$wg_candidate
      return 0
    fi
  done
  return 1
}

wg_capabilities_error() {
  printf '{"schema":1,"capacity_verified":false,"cpu_logical":null,"memory_mib":null,"capacity_issues":["%s"]}\n' "$1"
}

wg_readiness_error() {
  printf '{"schema":1,"status":"incomplete","ready":false,"issues":["%s"],"warnings":[],"tools":{},"agents":{},"git_identity":null,"worktree_exclusion":null,"storage_permission_policy":null,"storage_permission_warnings":[],"terminfo":{},"native_hooks":{},"native_relay":"requires-row-check"}\n' "$1"
}

wg_run_python() {
  wg_select_python || return 1
  if [ "${1:-}" = --exec ]; then
    shift
    exec "$wg_python" -I -B "$@"
  fi
  "$wg_python" -I -B "$@"
}

wg_python_readiness_error() {
  wg_readiness_error "$wg_python_issue"
}

wg_has_portable_profile() {
  [ -z "${WT_REMOTE_ROOT:-}" ] || return 0
  for wg_path in "$HOME/.config/workgrove/profile.json" "$HOME/.config/workgrove/env.sh"; do
    [ ! -e "$wg_path" ] && [ ! -L "$wg_path" ] || return 0
  done
  wg_parent=${1:-}
  if [ -z "$wg_parent" ]; then
    wg_executable=$(/usr/bin/readlink -f "$HOME/.local/bin/wt" 2>/dev/null) || return 1
    wg_parent=${wg_executable%/*}
    wg_parent=${wg_parent%/*}
    wg_parent=${wg_parent%/*}
  fi
  for wg_path in "$wg_parent/.config/workgrove/profile.json" "$wg_parent/.config/workgrove/env.sh" \
                 "$wg_parent/.config/workgrove/git/global"; do
    [ ! -e "$wg_path" ] && [ ! -L "$wg_path" ] || return 0
  done
  return 1
}
