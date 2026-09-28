#!/usr/bin/env bash
# VM lifecycle relay and Mac status hook, with scratch cmux and no configured host contact.
set -euo pipefail
ORIGINAL_HOME=$HOME
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-agent-status.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck disable=SC2034  # read by the sourced cleanup helper
KEEP_LABEL='agent status fixtures'
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap 'HOME=$ORIGINAL_HOME lib_cleanup' EXIT
mkdir -p "$TEST_ROOT/home/.ssh" "$TEST_ROOT/home/.local/state"
printf 'Host test-vm\n' > "$TEST_ROOT/home/.ssh/config"
cat > "$TEST_ROOT/cmux" <<'CMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
[[ ${CMUX_FAIL:-} == "$1" ]] && exit 142
case $1 in
  list-windows) echo 'window:1 AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA' ;;
  workspace) echo '{"workspaces":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","remote":{"enabled":true,"destination":"test-vm"}},{"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","remote":{"enabled":true,"destination":"other-vm"}}]}' ;;
  set-status|clear-status|notify) echo OK ;;
esac
CMUX
chmod +x "$TEST_ROOT/cmux"
export HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/home/.local/state" CMUX_LOG="$TEST_ROOT/cmux.log"
export CMUX_BUNDLED_CLI_PATH="$TEST_ROOT/cmux" WT_STATUS_LEASE_SECONDS=1
# A test started inside tmux must not inherit a real session's identity.
unset TMUX TMUX_PANE CMUX_SOCKET CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID
export AGENT_NOTIFY_SOURCE=Codex WT_HOST=test-vm CMUX_SOCKET_PATH=127.0.0.1:12345
export CMUX_WORKSPACE_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
export WT_STATUS_HEARTBEAT=1 WT_STATUS_OWNER_PID=$$
check_contains() { if grep -qF -- "$2" "$1"; then pass; else fail "missing '$2' in $1"; fi; }
check_missing() { if grep -qF -- "$2" "$1"; then fail "unexpected '$2' in $1"; else pass; fi; }
status_hook() {
  export CMUX_NOTIFICATION_TITLE='Codex status' CMUX_NOTIFICATION_BODY='Codex: running on test-vm'
  export CMUX_NOTIFICATION_SUBTITLE="$1"
  export CMUX_NOTIFICATION_WORKSPACE_ID="${2:-$CMUX_WORKSPACE_ID}"
  printf '{}\n' | bash "$REPO/bin/cmux-hook"
}
event() { printf '{"hook_event_name":"%s","session_id":"test-session"}\n' "$1" | bash "$REPO/bin/agent-notify"; }
control() { printf 'wt-agent-status|%s|codex|%s|%s|test-session' "$1" "$2" "$3"; }

begin_scenario 'VM event mapping and relay order'
event UserPromptSubmit
check_contains "$CMUX_LOG" '--title Codex status --body Codex: running on test-vm --subtitle wt-agent-status|test-vm|codex|running|'
check_contains "$CMUX_LOG" '|codex|running|'
check_missing "$CMUX_LOG" '--title Codex --body'
if [[ ! -e $HOME/.local/state/claude-start-times/test-session ]]; then pass; else fail 'Codex prompt changed the local banner timer'; fi
: > "$CMUX_LOG"
event Stop
check_contains "$CMUX_LOG" '--title Codex --body finished'
check_contains "$CMUX_LOG" '|codex|idle|'
assert_eq 'completion precedes status' 'notify --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB --title Codex --body finished' "$(head -1 "$CMUX_LOG")"
: > "$CMUX_LOG"
event Interrupt
check_contains "$CMUX_LOG" '|codex|idle|'
check_missing "$CMUX_LOG" '--title Codex --body'
: > "$CMUX_LOG"
event SessionEnd
check_contains "$CMUX_LOG" '|codex|clear|'
AGENT_NOTIFY_SOURCE='Claude Code' event StopFailure
check_contains "$CMUX_LOG" '|claude|idle|'
: > "$CMUX_LOG"
status=running status_only=1 event PermissionRequest
check_contains "$CMUX_LOG" '--title Codex --body needs approval'
check_missing "$CMUX_LOG" '--title Codex status'
end_scenario

begin_scenario 'Mac Running, Idle, clear and event ordering'
unset CMUX_SOCKET_PATH CMUX_WORKSPACE_ID
export CMUX_WORKSPACE_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
: > "$CMUX_LOG"
out=$(status_hook "$(control test-vm running 1000000000000000001)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'control notification was not hidden'; fi
check_contains "$CMUX_LOG" 'set-status vm-codex Running --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB --icon bolt.fill --color #4C8DFF'
: > "$CMUX_LOG"
out=$(status_hook "$(control test-vm idle 1000000000000000002)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'idle control notification was not hidden'; fi
check_contains "$CMUX_LOG" 'set-status vm-codex Idle --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB --icon pause.fill --color #8E8E93'
: > "$CMUX_LOG"
status_hook "$(control test-vm running 1000000000000000001)" >/dev/null
check_missing "$CMUX_LOG" 'set-status'
status_hook "$(control test-vm clear 1000000000000000003)" >/dev/null
check_contains "$CMUX_LOG" 'clear-status vm-codex --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
: > "$CMUX_LOG"
status_hook "$(control test-vm running 1000000000000000002)" >/dev/null
check_missing "$CMUX_LOG" 'set-status'
end_scenario

begin_scenario 'control failures stay quiet'
: > "$CMUX_LOG"
out=$(status_hook "$(control test-vm running 1000000000000000004)" CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC)
if [[ $out == *'"record":false'* ]]; then pass; else fail 'wrong-host control was visible'; fi
check_missing "$CMUX_LOG" 'set-status'
out=$(status_hook "$(control unknown-vm running 1000000000000000004)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'unknown-host control was visible'; fi
check_missing "$CMUX_LOG" 'set-status'
export CMUX_FAIL=workspace
out=$(status_hook "$(control test-vm running 1000000000000000004)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'row-list failure was visible'; fi
check_missing "$CMUX_LOG" 'set-status'
unset CMUX_FAIL
export CMUX_FAIL=set-status
out=$(status_hook "$(control test-vm running 1000000000000000004)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'set-status failure was visible'; fi
unset CMUX_FAIL
status_hook "$(control test-vm running 1000000000000000004)" >/dev/null
check_contains "$CMUX_LOG" 'set-status vm-codex Running'
end_scenario

begin_scenario 'a missing heartbeat clears a stale status'
sleep 3
check_contains "$CMUX_LOG" 'clear-status vm-codex --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
end_scenario
lib_summary 29
