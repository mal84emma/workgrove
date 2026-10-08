#!/usr/bin/env bash
# Test the VM lifecycle relay and the Mac status hook with a scratch cmux.
# The suite contacts no configured host.
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
# shellcheck disable=SC1091
source "$REPO/test/lib.sh"
trap 'HOME=$ORIGINAL_HOME lib_cleanup' EXIT
mkdir -p "$TEST_ROOT/home/.ssh" "$TEST_ROOT/home/.local/state"
printf 'Host test-vm\n' > "$TEST_ROOT/home/.ssh/config"
cat > "$TEST_ROOT/cmux" <<'CMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
[[ -n ${CLOSE_ORDER_LOG:-} && $1 == workspace && ${2:-} == close ]] && printf '%s\n' close >> "$CLOSE_ORDER_LOG"
[[ ${CMUX_FAIL:-} == "$1" ]] && exit 142
[[ ${CMUX_FAIL_CLOSE:-} == 1 && $1 == workspace && ${2:-} == close ]] && exit 142
case $1 in
  list-windows) echo '* 0: AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA' ;;
  workspace) echo '{"workspaces":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","title":"repo:task","remote":{"enabled":true,"destination":"test-vm"}},{"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","remote":{"enabled":true,"destination":"other-vm"}},{"id":"DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD","remote":{"enabled":true,"destination":"test-vm"}}]}' ;;
  set-status|clear-status|notify) echo OK ;;
esac
CMUX
chmod +x "$TEST_ROOT/cmux"
export HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/home/.local/state" CMUX_LOG="$TEST_ROOT/cmux.log"
export CMUX_BUNDLED_CLI_PATH="$TEST_ROOT/cmux" WT_STATUS_LEASE_SECONDS=30
# A test started inside tmux must not inherit a real session's identity.
unset TMUX TMUX_PANE CMUX_SOCKET CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID
export AGENT_NOTIFY_SOURCE=Codex WT_HOST=test-vm CMUX_SOCKET_PATH=127.0.0.1:12345
export CMUX_WORKSPACE_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
export WT_STATUS_HEARTBEAT=1 WT_STATUS_OWNER_PID=$$
export WT_STATUS_FILE="$XDG_STATE_HOME/wt-agent-status/test"
mkdir -p "${WT_STATUS_FILE%/*}"
check_contains() { if grep -qF -- "$2" "$1"; then pass; else fail "missing '$2' in $1"; fi; }
check_missing() { if grep -qF -- "$2" "$1"; then fail "unexpected '$2' in $1"; else pass; fi; }
status_hook() {
  export CMUX_NOTIFICATION_TITLE='Codex status' CMUX_NOTIFICATION_BODY='Codex: running on test-vm'
  export CMUX_NOTIFICATION_SUBTITLE="$1"
  export CMUX_NOTIFICATION_WORKSPACE_ID="${2:-$CMUX_WORKSPACE_ID}"
  printf '{}\n' | bash "$REPO/bin/cmux-hook"
}
event() { printf '{"hook_event_name":"%s","session_id":"test-session"}\n' "$1" > "$WT_STATUS_FILE"; bash "$REPO/bin/agent-notify" </dev/null; }
control() { printf 'wt-agent-status|%s|codex|%s|%s|%s' "$1" "$2" "$3" "${4-test-session}"; }

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
printf '%s\n' '{"hook_event_name":"SessionEnd","session_id":"test-session","reason":"clear"}' > "$WT_STATUS_FILE"
AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
check_contains "$CMUX_LOG" '|claude|idle|'
: > "$CMUX_LOG"
status=running status_only=1 event PermissionRequest
check_contains "$CMUX_LOG" '--title Codex --body needs approval'
check_missing "$CMUX_LOG" '--title Codex status'
end_scenario

begin_scenario 'a VM can close only its own task row after self-removal'
cat > "$TEST_ROOT/ssh" <<'SSH'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
case "$*" in *' path task -r /vm/repos/repo')
  [ "${SSH_PROBE_FAIL:-}" = 1 ] && exit 255
  [ -e "$REMOTE_TASK_EXISTS" ] && { echo '/vm/repos/repo/.worktrees/task'; exit 0; }
  echo "wt: no worktree named 'task' in /vm/repos/repo (see: wt list)" >&2
  exit 1 ;;
esac
case "$*" in *' kill-session '*) [ "${SSH_KILL_FAIL:-}" = 1 ] && exit 1 ;; esac
case "$*" in *' kill-session '*) printf '%s\n' kill >> "$CLOSE_ORDER_LOG" ;; esac
exit 0
SSH
chmod +x "$TEST_ROOT/ssh"
cat > "$TEST_ROOT/osascript" <<'OSA'
#!/bin/sh
printf '%s\n' "$*" >> "$OSASCRIPT_LOG"
OSA
chmod +x "$TEST_ROOT/osascript"
export PATH="$TEST_ROOT:$PATH" SSH_LOG="$TEST_ROOT/ssh.log" REMOTE_TASK_EXISTS="$TEST_ROOT/remote-task-exists" CLOSE_ORDER_LOG="$TEST_ROOT/close-order.log" OSASCRIPT_LOG="$TEST_ROOT/osascript.log"
close_hook() {
  CMUX_NOTIFICATION_TITLE=wt-close CMUX_NOTIFICATION_SUBTITLE='' \
    CMUX_NOTIFICATION_BODY="$1" CMUX_NOTIFICATION_WORKSPACE_ID="${2:-$CMUX_WORKSPACE_ID}" \
    bash "$REPO/bin/cmux-hook" </dev/null
}
: > "$CMUX_LOG"
out=$(close_hook '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}')
if [[ $out == *'"record":false'* ]]; then pass; else fail 'row-close control notification was visible'; fi
check_contains "$CMUX_LOG" 'workspace close BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB --force'
check_contains "$SSH_LOG" 'path task -r /vm/repos/repo'
check_contains "$SSH_LOG" "test-vm exec tmux kill-session -t '=wt-repo-task'"
assert_eq 'Mac closes row before stopping tmux' $'close\nkill' "$(cat "$CLOSE_ORDER_LOG")"
: > "$CMUX_LOG"; : > "$SSH_LOG"
: > "$REMOTE_TASK_EXISTS"
out=$(close_hook '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}')
if [[ $out != *'"record":false'* ]]; then pass; else fail 'live worktree rejection was hidden'; fi
check_missing "$CMUX_LOG" 'workspace close'
check_missing "$SSH_LOG" 'kill-session'
rm "$REMOTE_TASK_EXISTS"
: > "$CMUX_LOG"; : > "$SSH_LOG"
out=$(close_hook '{"host":"test-vm","repo":"/vm/repos/repo","task":"other"}')
if [[ $out != *'"record":false'* ]]; then pass; else fail 'wrong-task rejection was hidden'; fi
check_missing "$CMUX_LOG" 'workspace close'
check_missing "$SSH_LOG" 'kill-session'
out=$(close_hook '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}' CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC)
if [[ $out != *'"record":false'* ]]; then pass; else fail 'foreign-row rejection was hidden'; fi
check_missing "$CMUX_LOG" 'workspace close'
check_missing "$SSH_LOG" 'kill-session'
: > "$CMUX_LOG"; : > "$SSH_LOG"
export SSH_PROBE_FAIL=1
out=$(close_hook '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}')
if [[ $out != *'"record":false'* ]]; then pass; else fail 'failed VM probe was hidden'; fi
check_missing "$CMUX_LOG" 'workspace close'
unset SSH_PROBE_FAIL
: > "$CMUX_LOG"; : > "$SSH_LOG"
export CMUX_FAIL_CLOSE=1
out=$(close_hook '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}')
if [[ $out != *'"record":false'* ]]; then pass; else fail 'failed row close was hidden'; fi
check_missing "$SSH_LOG" 'kill-session'
unset CMUX_FAIL_CLOSE
: > "$CMUX_LOG"; : > "$SSH_LOG"
export SSH_KILL_FAIL=1
out=$(close_hook '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}')
if [[ $out != *'"record":false'* ]]; then pass; else fail 'failed tmux kill was hidden'; fi
check_contains "$CMUX_LOG" 'workspace close BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB --force'
check_contains "$OSASCRIPT_LOG" "Run: ssh test-vm tmux kill-session -t '=wt-repo-task'"
unset SSH_KILL_FAIL
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
status_hook "$(control test-vm clear 1000000000000000004 old-session)" >/dev/null
check_missing "$CMUX_LOG" 'clear-status'
assert_eq 'old session cannot clear active row' idle "$(awk '{print $4}' "$XDG_STATE_HOME/cmux-agent-status/$CMUX_WORKSPACE_ID-codex")"
status_hook "$(control test-vm clear 1000000000000000003)" >/dev/null
check_contains "$CMUX_LOG" 'clear-status vm-codex --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
: > "$CMUX_LOG"
status_hook "$(control test-vm running 1000000000000000002)" >/dev/null
check_missing "$CMUX_LOG" 'set-status'
status_hook "$(control test-vm running 1000000000000000004 new-session)" >/dev/null
: > "$CMUX_LOG"
status_hook "$(control test-vm clear 1000000000000000005 '')" >/dev/null
check_contains "$CMUX_LOG" 'clear-status vm-codex'
end_scenario

begin_scenario 'heartbeats recover lost updates without reviving stale state'
: > "$CMUX_LOG"
status_hook "$(control test-vm running 1000000000000000010)" >/dev/null
status_hook "$(control test-vm idle 1000000000000000011)" >/dev/null
status_hook "$(control test-vm renew 1000000000000000012)" >/dev/null
assert_eq 'legacy renewal keeps Idle' idle "$(awk '{print $4}' "$XDG_STATE_HOME/cmux-agent-status/$CMUX_WORKSPACE_ID-codex")"
status_hook "$(control test-vm running 1000000000000000010)" >/dev/null
status_hook "$(control test-vm idle 1000000000000000011)" >/dev/null
check_contains "$CMUX_LOG" 'set-status vm-codex Idle'
assert_eq 'stale Running stays Idle' idle "$(awk '{print $4}' "$XDG_STATE_HOME/cmux-agent-status/$CMUX_WORKSPACE_ID-codex")"
: > "$CMUX_LOG"
status_hook "$(control test-vm running 1000000000000000012)" >/dev/null
# The Idle event is lost. Its heartbeat has the same transition sequence as that event.
status_hook "$(control test-vm idle 1000000000000000013)" >/dev/null
assert_eq 'missed Idle is recovered' idle "$(awk '{print $4}' "$XDG_STATE_HOME/cmux-agent-status/$CMUX_WORKSPACE_ID-codex")"
end_scenario

begin_scenario 'control failures stay quiet'
: > "$CMUX_LOG"
out=$(status_hook "$(control test-vm running 1000000000000000014)" CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC)
if [[ $out == *'"record":false'* ]]; then pass; else fail 'wrong-host control was visible'; fi
check_missing "$CMUX_LOG" 'set-status'
out=$(status_hook "$(control unknown-vm running 1000000000000000014)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'unknown-host control was visible'; fi
check_missing "$CMUX_LOG" 'set-status'
export CMUX_FAIL=workspace
out=$(status_hook "$(control test-vm running 1000000000000000014)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'row-list failure was visible'; fi
check_missing "$CMUX_LOG" 'set-status'
unset CMUX_FAIL
export CMUX_FAIL=set-status
out=$(status_hook "$(control test-vm running 1000000000000000014)")
if [[ $out == *'"record":false'* ]]; then pass; else fail 'set-status failure was visible'; fi
unset CMUX_FAIL
status_hook "$(control test-vm running 1000000000000000014)" >/dev/null
check_contains "$CMUX_LOG" 'set-status vm-codex Running'
end_scenario

begin_scenario 'locked status work keeps the parent hook deadline'
: > "$CMUX_LOG"
WT_STATUS_DEADLINE=1 bash "$REPO/bin/cmux-hook" --apply "$CMUX_WORKSPACE_ID" codex idle 1000000000000000015 test-session || true
check_missing "$CMUX_LOG" 'set-status'
end_scenario

begin_scenario 'a missing heartbeat clears a stale status'
f="$XDG_STATE_HOME/cmux-agent-status/$CMUX_WORKSPACE_ID-codex"
read -r seq lease session state _ < "$f"
printf '%s %s %s %s 0\n' "$seq" "$lease" "$session" "$state" > "$f"
export CMUX_FAIL=clear-status
CMUX_NOTIFICATION_TITLE='unrelated' CMUX_NOTIFICATION_SUBTITLE='' bash "$REPO/bin/cmux-hook" </dev/null >/dev/null
assert_eq 'failed expiry remains retryable' running "$(awk '{print $4}' "$f")"
unset CMUX_FAIL
CMUX_NOTIFICATION_TITLE='unrelated' CMUX_NOTIFICATION_SUBTITLE='' bash "$REPO/bin/cmux-hook" </dev/null >/dev/null
check_contains "$CMUX_LOG" 'clear-status vm-codex --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
assert_eq 'expiry retains the transition sequence' "$seq" "$(awk '{print $1}' "$f")"
assert_eq 'expiry retains the owning session' "$session" "$(awk '{print $3}' "$f")"
assert_eq 'retry marks the state expired' expired-running "$(awk '{print $4}' "$f")"
: > "$CMUX_LOG"
status_hook "$(control test-vm running "$seq")" >/dev/null
check_contains "$CMUX_LOG" 'set-status vm-codex Running'
assert_eq 'heartbeat restores expired state' running "$(awk '{print $4}' "$f")"
status_hook "$(control test-vm clear 1000000000000000016)" >/dev/null
: > "$CMUX_LOG"
status_hook "$(control test-vm running "$seq")" >/dev/null
check_missing "$CMUX_LOG" 'set-status vm-codex'
end_scenario

begin_scenario 'one restored row does not expire another'
f2="$XDG_STATE_HOME/cmux-agent-status/DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD-codex"
printf '%s %s %s %s 0\n' 1000000000000000017 1 test-session idle > "$f2"
status_hook "$(control test-vm idle 1000000000000000018)" >/dev/null
assert_eq 'first row stays Idle after sweep' idle "$(awk '{print $4}' "$f")"
assert_eq 'second row is marked expired' expired-idle "$(awk '{print $4}' "$f2")"
assert_eq 'second row keeps its sequence' 1000000000000000017 "$(awk '{print $1}' "$f2")"
status_hook "$(control test-vm idle 1000000000000000017)" DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD >/dev/null
assert_eq 'second row heartbeat restores its status' idle "$(awk '{print $4}' "$f2")"
assert_eq 'first row stays Idle after second recovery' idle "$(awk '{print $4}' "$f")"
end_scenario

begin_scenario 'an orphan timer does not recreate removed test state'
rm -rf "$XDG_STATE_HOME/cmux-agent-status"
WT_STATUS_LEASE_SECONDS=0 bash "$REPO/bin/cmux-hook" --expire "$CMUX_WORKSPACE_ID" codex "$lease"
if [[ ! -d $XDG_STATE_HOME/cmux-agent-status ]]; then pass; else fail 'orphan timer recreated status directory'; fi
end_scenario
lib_summary 72
