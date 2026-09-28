#!/usr/bin/env bash
# Exercise the real Linux /proc owner gate and Claude transcript watcher with scratch state.
set -euo pipefail
[[ $(uname -s) == Linux ]] || { echo 'Linux only'; exit 0; }
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-status-linux.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home/.local/state/wt-agent-status" "$ROOT/home/.claude/projects"
cp /bin/bash "$ROOT/codex"
cp /bin/bash "$ROOT/claude"
cat > "$ROOT/cmux" <<'CMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
[[ ${CMUX_SLEEP_NOTIFY:-} == 1 ]] && sleep 10
exit 0
CMUX
chmod +x "$ROOT/cmux"
export HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/home/.local/state" CMUX_LOG="$ROOT/cmux.log"
export CMUX_BUNDLED_CLI_PATH="$ROOT/cmux" CMUX_SOCKET_PATH=127.0.0.1:12345
export CMUX_WORKSPACE_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB WT_HOST=test-vm
export WT_STATUS_OWNER_PID=$$ WT_STATUS_OWNER_PANE=pane1 TMUX_PANE=pane1
export WT_STATUS_FILE="$XDG_STATE_HOME/wt-agent-status/task" REPO
unset TMUX WT_STATUS_HEARTBEAT
FAKE_CODEX="$ROOT/codex" FAKE_CLAUDE="$ROOT/claude"
export FAKE_CODEX FAKE_CLAUDE
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$1" "$CMUX_LOG" || fail "missing $1"; }
no_status() { ! grep -qF -- '--title Codex status' "$CMUX_LOG" || fail 'unexpected status relay'; }
agent_event() { # agent_event codex|claude JSON
  local agent=$1; export PAYLOAD=$2
  if [[ $agent == claude ]]; then export AGENT_NOTIFY_SOURCE='Claude Code'; else export AGENT_NOTIFY_SOURCE=Codex; fi
  # shellcheck disable=SC2016  # the copied bash receives these exported variables
  "$ROOT/$agent" -c 'printf "%s\n" "$PAYLOAD" | bash "$REPO/bin/agent-notify"; sleep 0.05'
}

agent_event codex '{"hook_event_name":"UserPromptSubmit","session_id":"test-session"}'
has '|codex|running|'
[[ -r $WT_STATUS_FILE ]] || fail 'prompt did not create heartbeat state'
: > "$CMUX_LOG"
agent_event codex '{"hook_event_name":"Stop","session_id":"test-session"}'
has '|codex|idle|'
: > "$CMUX_LOG"
agent_event codex '{"hook_event_name":"SessionEnd","session_id":"test-session"}'
has '|codex|clear|'
[[ ! -e $WT_STATUS_FILE ]] || fail 'session end retained heartbeat state'

: > "$CMUX_LOG"
# shellcheck disable=SC2016  # both nested bash processes read the exported fixture variables
PAYLOAD='{"hook_event_name":"UserPromptSubmit","session_id":"nested"}' AGENT_NOTIFY_SOURCE=Codex \
  "$FAKE_CODEX" -c '"$FAKE_CODEX" -c '\''printf "%s\n" "$PAYLOAD" | bash "$REPO/bin/agent-notify"; sleep 0.05'\''; sleep 0.05'
no_status
[[ ! -e $WT_STATUS_FILE ]] || fail 'nested agent changed heartbeat state'
: > "$CMUX_LOG"
TMUX_PANE=other agent_event codex '{"hook_event_name":"UserPromptSubmit","session_id":"wrong-pane"}'
no_status
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 bash "$REPO/bin/agent-notify" </dev/null
[[ ! -e $CMUX_LOG || ! -s $CMUX_LOG ]] || fail 'missing state emitted a notification'

TRANSCRIPT="$HOME/.claude/projects/test.jsonl"
: > "$TRANSCRIPT"
payload=$(jq -nc --arg p "$TRANSCRIPT" '{hook_event_name:"UserPromptSubmit",session_id:"claude-session",transcript_path:$p}')
agent_event claude "$payload"
grep -q '"transcript_path"' "$WT_STATUS_FILE" || fail 'Claude transcript offset was not recorded'
printf '%s\n' '{"type":"user","message":{"content":"[Request interrupted by user]"}}' >> "$TRANSCRIPT"
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
has '|claude|idle|'
[[ $(jq -r .state "$WT_STATUS_FILE") == idle ]] || fail 'Esc marker did not persist Idle'
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
has '|claude|renew|'
agent_event claude '{"hook_event_name":"SessionEnd","session_id":"claude-session","reason":"clear"}'
has '|claude|idle|'

# A stalled relay must not hold the agent hook for cmux's ten-second CLI wait.
: > "$CMUX_LOG"
start=$SECONDS
CMUX_SLEEP_NOTIFY=1 agent_event codex '{"hook_event_name":"UserPromptSubmit","session_id":"timeout"}'
(( SECONDS - start < 4 )) || fail 'relay exceeded its one-second cap'

# Run the actual wt lifecycle: its cleanup sends Clear after deleting the heartbeat file.
mkdir -p "$HOME/.local/bin" "$ROOT/repo"
cat > "$HOME/.local/bin/codex" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' '{"hook_event_name":"Heartbeat","session_id":"child-check","state":"running"}' > "$WT_STATUS_FILE"
bash "$WT_SCRIPT" list -r "$TEST_REPO" >/dev/null || exit 1
[[ -r $WT_STATUS_FILE ]] && : > "$CHILD_STATE_CHECK"
sleep 0.1
AGENT
chmod +x "$HOME/.local/bin/codex"
ln -s "$REPO/bin/agent-notify" "$HOME/.local/bin/agent-notify"
git -C "$ROOT/repo" init -q -b main
git -C "$ROOT/repo" config user.name Test
git -C "$ROOT/repo" config user.email test@example.invalid
git -C "$ROOT/repo" commit -q --allow-empty -m initial
unset WT_STATUS_FILE WT_STATUS_OWNER_PID WT_STATUS_OWNER_PANE
bash "$REPO/bin/wt" new task -a codex --no-workspace -r "$ROOT/repo" >/dev/null
: > "$CMUX_LOG"
export TEST_REPO="$ROOT/repo" CHILD_STATE_CHECK="$ROOT/child-kept-state" WT_SCRIPT="$REPO/bin/wt"
WT_STATUS_BRIDGE=1 TMUX=/tmp/fake,1,0 PATH="$HOME/.local/bin:$PATH" \
  bash "$REPO/bin/wt" run task -r "$ROOT/repo" >/dev/null
[[ -e $CHILD_STATE_CHECK ]] || fail 'nested wt removed its parent status file'
has '|codex|clear|'
[[ -z $(find "$XDG_STATE_HOME/wt-agent-status" -maxdepth 1 -type f -name 'wt-*' ! -name '*.lock' -print -quit) ]] ||
  fail 'wt run left its heartbeat file after exit'
echo 'ok Linux owner, heartbeat, Esc, clear and relay timeout'
