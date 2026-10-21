# shellcheck shell=sh
# shellcheck disable=SC2034
# Use the same supported interpreter for setup, readiness, and capacity checks.
wg_select_python() {
  wg_python='' wg_python_issue=missing-python
  for wg_candidate in "$(command -v python3 || true)" /usr/bin/python3; do
    [ -n "$wg_candidate" ] && [ -x "$wg_candidate" ] || continue
    wg_python_issue=python-3.9-required
    if "$wg_candidate" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
      wg_python=$wg_candidate
      return 0
    fi
  done
  return 1
}

wg_python_readiness_error() {
  printf '{"schema":1,"status":"incomplete","ready":false,"issues":["%s"],"native_relay":"requires-row-check"}\n' "$wg_python_issue"
}

wg_has_portable_profile() {
  [ -z "${WT_REMOTE_ROOT:-}" ] || return 0
  for wg_path in "$HOME/.config/workgrove/profile.json" "$HOME/.config/workgrove/env.sh"; do
    [ ! -e "$wg_path" ] && [ ! -L "$wg_path" ] || return 0
  done
  wg_executable=$(/usr/bin/readlink -f "$HOME/.local/bin/wt" 2>/dev/null) || return 1
  wg_parent=${wg_executable%/*}
  wg_parent=${wg_parent%/*}
  wg_parent=${wg_parent%/*}
  [ -f "$wg_parent/.config/workgrove/profile.json" ]
}
