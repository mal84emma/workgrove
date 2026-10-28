#!/usr/bin/env bash
# Check real Linux tmux target parsing on a private, disposable server.
set -euo pipefail
if [[ $(uname -s) != Linux ]] || ! command -v tmux >/dev/null; then
  echo 'SKIP: real tmux target checks require Linux and tmux'
  exit 0
fi
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
source "$REPO/test/lib.sh"
source "$REPO/lib/workgrove/common.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-tmux-target.XXXXXX")
TEST_TMUX_SOCKET="$ROOT/socket"
TEST_TMUX_BIN=$(command -v tmux)
tmux() { "$TEST_TMUX_BIN" -S "$TEST_TMUX_SOCKET" "$@"; }
cleanup() {
  if [[ -S $TEST_TMUX_SOCKET ]]; then
    tmux kill-session -t =wt-target-provider >/dev/null 2>&1 || true
    tmux kill-session -t =wt-target-context >/dev/null 2>&1 || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT
cat >"$ROOT/provider.py" <<'PY'
import os,sys,time
from pathlib import Path
Path('/proc/self/comm').write_text('codex')
Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(120)
PY
begin_scenario 'real tmux resolves exact task sessions before window names'
command=$(shell_join python3 "$ROOT/provider.py" "$ROOT/provider.pid")
tmux -f /dev/null new-session -d -s wt-target-provider -n main "$command"
tmux new-session -d -s wt-target-context -n 'wt-target-provider' 'sleep 120'
for ((attempt=0; attempt<100; attempt++)); do
  [[ ! -f $ROOT/provider.pid ]] || break
  sleep 0.05
done
[[ -f $ROOT/provider.pid ]] || { fail 'the private fake provider did not start'; end_scenario; lib_summary; }
context=$(tmux list-panes -s -t '=wt-target-context:' -F '#{pane_id}')
context_session=$(tmux display-message -p -t '=wt-target-context:' '#{session_id}')
context_server=$(tmux display-message -p -t '=wt-target-context:' '#{pid}')
export TMUX="$TEST_TMUX_SOCKET,$context_server,${context_session#\$}"
export TMUX_PANE=$context
rc=0; tmux_agent wt-target-provider || rc=$?
assert_eq 'a same-named current window cannot hide the target provider' 0 "$rc"
identity=$(task_tmux_identity wt-target-provider)
expected=$(tmux display-message -p -t '=wt-target-provider:' '#{session_id}')
assert_eq 'outside-client identity selects the intended task session' "$expected" "$(jq -r .id <<<"$identity")"
assert_eq 'the identity records this private server socket' "$TEST_TMUX_SOCKET" "$(jq -r .socket <<<"$identity")"
end_scenario
lib_summary
