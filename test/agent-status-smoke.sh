#!/usr/bin/env bash
# Check the VM hook payload and the Mac-side row/host gate without contacting cmux or a VM.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-agent-status.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home/.ssh" "$ROOT/home/.local/state"
printf 'Host test-vm\n' > "$ROOT/home/.ssh/config"
cat > "$ROOT/cmux" <<'CMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case $1 in
  list-windows) echo 'window:1 AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA' ;;
  workspace) echo '{"workspaces":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","remote":{"enabled":true,"destination":"test-vm"}},{"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","remote":{"enabled":true,"destination":"other-vm"}}]}' ;;
  set-status|clear-status|notify) echo OK ;;
esac
CMUX
chmod +x "$ROOT/cmux"
export HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/home/.local/state" CMUX_LOG="$ROOT/cmux.log"
export CMUX_BUNDLED_CLI_PATH="$ROOT/cmux"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_has() { grep -qF -- "$2" "$1" || fail "missing $2 in $1"; }
assert_absent() { ! grep -qF -- "$2" "$1" || fail "unexpected $2 in $1"; }

export AGENT_NOTIFY_SOURCE=Codex WT_HOST=test-vm CMUX_SOCKET_PATH=127.0.0.1:12345
export CMUX_WORKSPACE_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
printf '%s\n' '{"hook_event_name":"UserPromptSubmit","session_id":"test-session"}' | bash "$REPO/bin/agent-notify"
assert_has "$CMUX_LOG" 'notify --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB --title wt-agent-status --body {"host":"test-vm","agent":"codex","state":"running"}'
assert_absent "$CMUX_LOG" '--title Codex'
: > "$CMUX_LOG"
printf '%s\n' '{"hook_event_name":"Stop","session_id":"test-session"}' | bash "$REPO/bin/agent-notify"
assert_has "$CMUX_LOG" '"state":"idle"'
assert_has "$CMUX_LOG" '--title Codex --body finished'
: > "$CMUX_LOG"
printf '%s\n' '{"hook_event_name":"SessionEnd","session_id":"test-session"}' | bash "$REPO/bin/agent-notify"
assert_has "$CMUX_LOG" '"state":"clear"'
assert_absent "$CMUX_LOG" '--title Codex'
: > "$CMUX_LOG"
AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" <<<'{"hook_event_name":"UserPromptSubmit","session_id":"claude-session"}'
assert_has "$CMUX_LOG" '"agent":"claude","state":"running"'

unset CMUX_SOCKET_PATH CMUX_WORKSPACE_ID
export CMUX_NOTIFICATION_TITLE=wt-agent-status
export CMUX_NOTIFICATION_BODY='{"host":"test-vm","agent":"codex","state":"running"}'
export CMUX_NOTIFICATION_WORKSPACE_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
: > "$CMUX_LOG"
out=$(printf '{}\n' | bash "$REPO/bin/cmux-hook")
[[ $out == *'"record":false'* ]] || fail 'control notification was not hidden'
assert_has "$CMUX_LOG" 'set-status vm-codex Running --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
export CMUX_NOTIFICATION_BODY='{"host":"test-vm","agent":"codex","state":"clear"}'
: > "$CMUX_LOG"
out=$(printf '{}\n' | bash "$REPO/bin/cmux-hook")
[[ $out == *'"record":false'* ]] || fail 'clear control notification was not hidden'
assert_has "$CMUX_LOG" 'clear-status vm-codex --workspace BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'

# A VM can update only the workspace cmux says the notification came from.
export CMUX_NOTIFICATION_BODY='{"host":"test-vm","agent":"codex","state":"running"}'
export CMUX_NOTIFICATION_WORKSPACE_ID=CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC
: > "$CMUX_LOG"
out=$(printf '{}\n' | bash "$REPO/bin/cmux-hook")
[[ -z $out ]] || fail 'cross-host control notification was hidden'
assert_absent "$CMUX_LOG" 'set-status'

echo 'agent status smoke: passed'
