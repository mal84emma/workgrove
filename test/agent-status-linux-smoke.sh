#!/usr/bin/env bash
# Exercise the real Linux /proc owner gate and Claude transcript watcher with scratch state.
set -euo pipefail
[[ $(uname -s) == Linux ]] || { echo 'Linux only'; exit 0; }
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
ORIGINAL_HOME=$HOME
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-status-linux.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
[[ $TEST_ROOT == "$(cd "${TMPDIR:-/tmp}" && pwd -P)"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
ROOT=$TEST_ROOT
# shellcheck source=test/lib.sh
# shellcheck disable=SC1091  # sourced helper
source "$REPO/test/lib.sh"
# shellcheck disable=SC2034  # read by the sourced cleanup helper
KEEP_LABEL='Linux status fixtures'
trap 'HOME=$ORIGINAL_HOME lib_cleanup' EXIT
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
has() { if grep -qF -- "$1" "$CMUX_LOG"; then pass; else fail "missing $1"; fi; }
no_status() { if ! grep -qF -- '--title Codex status' "$CMUX_LOG"; then pass; else fail 'unexpected status relay'; fi; }
agent_event() { # agent_event codex|claude JSON
  local agent=$1; export PAYLOAD=$2
  if [[ $agent == claude ]]; then export AGENT_NOTIFY_SOURCE='Claude Code'; else export AGENT_NOTIFY_SOURCE=Codex; fi
  # shellcheck disable=SC2016  # the copied bash receives these exported variables
  "$ROOT/$agent" -c 'printf "%s\n" "$PAYLOAD" | bash "$REPO/bin/agent-notify"; sleep 0.05'
}

begin_scenario 'owner lifecycle and nested isolation'
agent_event codex '{"hook_event_name":"UserPromptSubmit","session_id":"test-session"}'
has '|codex|running|'
if [[ -r $WT_STATUS_FILE ]]; then pass; else fail 'prompt did not create heartbeat state'; fi
: > "$CMUX_LOG"
agent_event codex '{"hook_event_name":"Stop","session_id":"test-session"}'
has '|codex|idle|'
: > "$CMUX_LOG"
agent_event codex '{"hook_event_name":"SessionEnd","session_id":"test-session"}'
has '|codex|clear|'
if [[ ! -e $WT_STATUS_FILE ]]; then pass; else fail 'session end retained heartbeat state'; fi

: > "$CMUX_LOG"
# shellcheck disable=SC2016  # both nested bash processes read the exported fixture variables
PAYLOAD='{"hook_event_name":"UserPromptSubmit","session_id":"nested"}' AGENT_NOTIFY_SOURCE=Codex \
  "$FAKE_CODEX" -c '"$FAKE_CODEX" -c '\''printf "%s\n" "$PAYLOAD" | bash "$REPO/bin/agent-notify"; sleep 0.05'\''; sleep 0.05'
no_status
if [[ ! -e $WT_STATUS_FILE ]]; then pass; else fail 'nested agent changed heartbeat state'; fi
: > "$CMUX_LOG"
TMUX_PANE=other agent_event codex '{"hook_event_name":"UserPromptSubmit","session_id":"wrong-pane"}'
no_status
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 bash "$REPO/bin/agent-notify" </dev/null
if [[ ! -e $CMUX_LOG || ! -s $CMUX_LOG ]]; then pass; else fail 'missing state emitted a notification'; fi
end_scenario

begin_scenario 'Claude transcript interruptions and state replay'
TRANSCRIPT="$HOME/.claude/projects/test.jsonl"
: > "$TRANSCRIPT"
payload=$(jq -nc --arg p "$TRANSCRIPT" '{hook_event_name:"UserPromptSubmit",session_id:"claude-session",transcript_path:$p}')
agent_event claude "$payload"
if grep -q '"transcript_path"' "$WT_STATUS_FILE"; then pass; else fail 'Claude transcript offset was not recorded'; fi
printf '%s\n' '{"type":"user","message":{"content":"[Request interrupted by user]"}}' >> "$TRANSCRIPT"
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
has '|claude|idle|'
assert_eq 'Esc marker persists Idle' idle "$(jq -r .state "$WT_STATUS_FILE")"
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
saved_seq=$(jq -r .seq "$WT_STATUS_FILE")
has "|claude|idle|$saved_seq|"
agent_event claude '{"hook_event_name":"SessionEnd","session_id":"claude-session","reason":"clear"}'
has '|claude|idle|'
end_scenario

begin_scenario 'first-turn and tool-use Esc markers are exact'
rm -f "$TRANSCRIPT"
payload=$(jq -nc --arg p "$TRANSCRIPT" '{hook_event_name:"UserPromptSubmit",session_id:"first-turn",transcript_path:$p}')
agent_event claude "$payload"
assert_eq 'missing first transcript uses offset zero' 0 "$(jq -r .offset "$WT_STATUS_FILE")"
if grep -q '"transcript_path"' "$WT_STATUS_FILE"; then pass; else fail 'missing first transcript path was discarded'; fi
printf '%s\n' '{"type":"user","message":{"content":"[Request interrupted by user for tool use]"}}' > "$TRANSCRIPT"
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
has '|claude|idle|'

: > "$TRANSCRIPT"
agent_event claude "$payload"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"[Request interrupted by user for tool use]"}]}}' >> "$TRANSCRIPT"
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
assert_eq 'tool output is not an Esc marker' running "$(jq -r .state "$WT_STATUS_FILE")"
has '|claude|running|'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"prefix [Request interrupted by user]"}]}}' >> "$TRANSCRIPT"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
assert_eq 'embedded marker text is ignored' running "$(jq -r .state "$WT_STATUS_FILE")"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}' >> "$TRANSCRIPT"
: > "$CMUX_LOG"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
has '|claude|idle|'

: > "$TRANSCRIPT"
agent_event claude "$payload"
printf '%s\n' '{"type":"user","message":{"content":"Prompt already recorded"}}' >> "$TRANSCRIPT"
WT_STATUS_HEARTBEAT=1 AGENT_NOTIFY_SOURCE='Claude Code' bash "$REPO/bin/agent-notify" </dev/null
assert_eq 'thinking without a marker stays Running' running "$(jq -r .state "$WT_STATUS_FILE")"
end_scenario

# A stalled relay must not hold the agent hook for cmux's ten-second CLI wait.
begin_scenario 'relay timeout and wt run cleanup'
: > "$CMUX_LOG"
start=$SECONDS
CMUX_SLEEP_NOTIFY=1 agent_event codex '{"hook_event_name":"UserPromptSubmit","session_id":"timeout"}'
if (( SECONDS - start < 4 )); then pass; else fail 'relay exceeded its one-second cap'; fi

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
if [[ -e $CHILD_STATE_CHECK ]]; then pass; else fail 'nested wt removed its parent status file'; fi
has '|codex|clear|'
if [[ -z $(find "$XDG_STATE_HOME/wt-agent-status" -maxdepth 1 -type f -name 'wt-*' ! -name '*.lock' -print -quit) ]]; then
  pass
else
  fail 'wt run left its heartbeat file after exit'
fi
end_scenario
lib_summary 26
