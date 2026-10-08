#!/usr/bin/env bash
# Test native notification handling and automation installation in a scratch home.
set -euo pipefail
ORIGINAL_HOME=$HOME
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-native-relay.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# shellcheck source=test/lib.sh
# shellcheck disable=SC1091
source "$REPO/test/lib.sh"
trap 'HOME=$ORIGINAL_HOME lib_cleanup' EXIT
mkdir -p "$TEST_ROOT/home/.ssh" "$TEST_ROOT/bin"
export HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/home/.local/state"
export PATH="$TEST_ROOT/bin:$PATH" CMUX_LOG="$TEST_ROOT/cmux.log" CODE_LOG="$TEST_ROOT/code.log"
export CMUX_BUNDLED_CLI_PATH="$TEST_ROOT/bin/cmux" RECORD_FILE="$TEST_ROOT/record.json"
export ROW_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB NOTIFICATION_ID=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
export BACKEND=cmux-tui REMOTE_EXISTS=0
unset CMUX_NOTIFICATION_TITLE CMUX_NOTIFICATION_BODY CMUX_NOTIFICATION_SUBTITLE CMUX_NOTIFICATION_WORKSPACE_ID
cat > "$TEST_ROOT/bin/cmux" <<'CMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1 ${2:-}" in
  'list-windows ') echo '* 0: CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC' ;;
  'workspace list') jq -cn --arg w "$ROW_ID" --arg b "$BACKEND" '{workspaces:[{id:$w,title:"repo:task",remote:{enabled:true,destination:"test-vm",backend:$b}}]}' ;;
  '--json list-notifications') cat "$RECORD_FILE" ;;
  'ssh test-vm') echo workspace:99 ;;
esac
exit 0
CMUX
cat > "$TEST_ROOT/bin/code" <<'CODE'
#!/bin/sh
printf '%s\n' "$*" >> "$CODE_LOG"
exit "${CODE_FAIL:-0}"
CODE
cat > "$TEST_ROOT/bin/ssh" <<'SSH'
#!/bin/sh
case "$*" in
  *' path task -r /vm/repos/repo')
    [ "$REMOTE_EXISTS" = 1 ] && { echo /vm/repos/repo/.worktrees/task; exit 0; }
    echo "wt: no worktree named 'task' in /vm/repos/repo (see: wt list)" >&2
    exit 1 ;;
esac
exit 0
SSH
chmod +x "$TEST_ROOT/bin/"*
export CMUX_AUTOMATION_EVENT_JSON
CMUX_AUTOMATION_EVENT_JSON=$(jq -cn --arg w "$ROW_ID" --arg i "$NOTIFICATION_ID" '{name:"notification.created",workspace_id:$w,payload:{notification_id:$i,title:null,body:null,redacted_fields:["title","body"]}}')
record() {
  jq -cn --arg w "${3:-$ROW_ID}" --arg i "${4:-$NOTIFICATION_ID}" --arg t "$1" --arg b "$2" '[{id:$i,workspace_id:$w,title:$t,body:$b}]' > "$RECORD_FILE"
  : > "$CMUX_LOG"; : > "$CODE_LOG"
}
hook() { bash "$REPO/bin/cmux-hook" --event </dev/null; }
has() { if grep -qF -- "$2" "$1"; then pass; else fail "missing '$2' in $1"; fi; }
lacks() { if grep -qF -- "$2" "$1"; then fail "unexpected '$2' in $1"; else pass; fi; }
printf 'Host test-vm\n' > "$HOME/.ssh/config"

begin_scenario 'tmux rebinds native identity instead of retaining the pane identity'
# Load the identity reader without starting wt or contacting a host.
eval "$(sed -n '/^RELAY_VARS=/p' "$REPO/bin/wt")"
eval "$(sed -n '/^relay_env()/,/^}/p' "$REPO/bin/wt")"
have() { command -v "$1" >/dev/null; }
cat > "$TEST_ROOT/bin/tmux" <<'TMUX'
#!/bin/sh
case "$1" in
  display-message) echo native-task ;;
  show-environment)
    case "$4" in
      CMUX_TUI_SOCKET) echo CMUX_TUI_SOCKET=/tmp/current-native ;;
      CMUX_TUI_TERMINAL_ID) echo CMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    esac ;;
esac
TMUX
chmod +x "$TEST_ROOT/bin/tmux"
TMUX=/tmp/fake CMUX_TUI_SOCKET=/tmp/stale CMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa relay_env
assert_eq 'the native socket comes from the current session' /tmp/current-native "$RELAY_TUI_SOCKET"
assert_eq 'the native terminal comes from the current session' term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$RELAY_TUI_TERMINAL"
assert_eq 'the old pane identity does not reach the CLI' 0 "$(printf '%s\n' "${RELAY_IDENT[@]}" | grep -cF term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || true)"
rm "$TEST_ROOT/bin/tmux"
end_scenario

begin_scenario 'native open uses the recorded ID and validates the sending row'
record wt-open '{"host":"test-vm","path":"/vm/repos/repo/.worktrees/task"}'
hook >/dev/null
has "$CODE_LOG" '--folder-uri vscode-remote://ssh-remote+test-vm/vm/repos/repo/.worktrees/task/'
has "$CMUX_LOG" "dismiss-notification --id $NOTIFICATION_ID"
has "$XDG_STATE_HOME/cmux-hook.log" "handled wt-open for workspace $ROW_ID"
export BACKEND=legacy
: > "$CODE_LOG"; : > "$CMUX_LOG"
hook >/dev/null
lacks "$CODE_LOG" '--folder-uri'
lacks "$CMUX_LOG" 'list-notifications'
export BACKEND=cmux-tui
record wt-open '{"host":"other-vm","path":"/vm/repos/repo"}'
hook >/dev/null
lacks "$CODE_LOG" '--folder-uri'
lacks "$CMUX_LOG" 'dismiss-notification'
record wt-open '{"host":"test-vm","path":"/vm/../repos/repo"}'
hook >/dev/null
lacks "$CODE_LOG" '--folder-uri'
record wt-open '{"host":"test-vm","path":"/vm/repos/repo"}' CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC
hook >/dev/null
lacks "$CODE_LOG" '--folder-uri'
record wt-open '{"host":"test-vm","path":"/vm/repos/repo"}' "$ROW_ID" CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC
hook >/dev/null
lacks "$CODE_LOG" '--folder-uri'
record 'ordinary notification' '{"host":"test-vm","path":"/vm/repos/repo"}'
hook >/dev/null
lacks "$CODE_LOG" '--folder-uri'
record wt-open '{"host":"test-vm","path":"/vm/repos/repo"}'
CODE_FAIL=7 hook >/dev/null
lacks "$CMUX_LOG" 'dismiss-notification'
has "$XDG_STATE_HOME/cmux-hook.log" 'failed; no window opened'
CMUX_AUTOMATION_EVENT_JSON='{"name":"notification.read"}' hook >/dev/null
lacks "$CMUX_LOG" 'dismiss-notification'
end_scenario

begin_scenario 'native attach and close preserve the existing control checks'
record wt-attach '{"host":"test-vm","repo":"/vm/repos/child","task":"child"}'
hook >/dev/null
has "$CMUX_LOG" 'ssh test-vm --name child:child --no-focus'
lacks "$CMUX_LOG" 'workspace select'
has "$CMUX_LOG" "dismiss-notification --id $NOTIFICATION_ID"
record wt-close '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}'
REMOTE_EXISTS=1 hook >/dev/null
lacks "$CMUX_LOG" 'workspace close'
lacks "$CMUX_LOG" 'dismiss-notification'
has "$XDG_STATE_HOME/cmux-hook.log" 'could not confirm its worktree is gone'
: > "$CMUX_LOG"
hook >/dev/null
has "$CMUX_LOG" "workspace close $ROW_ID --force"
lacks "$CMUX_LOG" "dismiss-notification --id $NOTIFICATION_ID"
end_scenario

begin_scenario 'notification bursts do not consume the open request budget'
# Model cmux 0.65's admission window for an ordinary notification followed by two open requests.
# The omitted rate limit admits only the first event, so both open requests disappear.
admitted_burst() {
  jq -r '
    .rules[] | select(.id == "wt-native-relay") |
    (.rate_limit // {interval_seconds: 1, maximum: 1}) as $limit |
    reduce [0, 0.121, 0.242][] as $now
      ({dates: [], admitted: 0};
       .dates |= map(select(. >= ($now - $limit.interval_seconds))) |
       if (.dates | length) < $limit.maximum then
         .dates += [$now] | .admitted += 1
       else . end) | .admitted'
}
assert_eq 'the cmux default reproduces dropped requests' 1 "$(jq 'del(.rules[].rate_limit)' "$REPO/home/.cmuxterm/automations.json" | admitted_burst)"
assert_eq 'an unrelated notification and two open requests are admitted' 3 "$(admitted_burst < "$REPO/home/.cmuxterm/automations.json")"
end_scenario

begin_scenario 'automation installation preserves user rules and backups'
# Load only the merge function. Do not run install.sh or its main function.
eval "$(sed -n '/^hook_cmux_automation()/,/^}/p' "$REPO/install.sh")"
# shellcheck disable=SC2034  # read by the extracted installation function
OS=Darwin
# shellcheck disable=SC2034  # read by the extracted installation function
R=$REPO
BK="$TEST_ROOT/backup"
# shellcheck disable=SC2034  # read by the extracted installation function
TMPFILES=()
stash() { mkdir -p "$BK/$(dirname "${1#"$HOME"/}")"; mv "$1" "$BK/${1#"$HOME"/}"; }
hook_cmux_automation >/dev/null
config="$HOME/.cmuxterm/automations.json"
assert_eq 'new configuration contains the native rule' wt-native-relay "$(jq -r '.rules[0].id' "$config")"
sum=$(cksum < "$config")
hook_cmux_automation >/dev/null
assert_eq 'a second merge changes nothing' "$sum" "$(cksum < "$config")"
printf '%s\n' '{"version":1,"rules":[{"id":"user-rule","when":{"event":"surface.created"},"then":[{"action":"run","command":"true"}]}]}' > "$config"
sum=$(cksum < "$config")
hook_cmux_automation >/dev/null
assert_eq 'existing rules retain their order' 'user-rule wt-native-relay' "$(jq -r '.rules | map(.id) | join(" ")' "$config")"
assert_eq 'the original configuration is backed up before replacement' "$sum" "$(cksum < "$BK/.cmuxterm/automations.json")"
printf '%s\n' '// invalid JSON' > "$config"
sum=$(cksum < "$config")
hook_cmux_automation >/dev/null
assert_eq 'an unreadable configuration stays unchanged' "$sum" "$(cksum < "$config")"
mv "$config" "$TEST_ROOT/managed.json"
ln -s "$TEST_ROOT/managed.json" "$config"
hook_cmux_automation >/dev/null
assert_eq 'managed configuration keeps its symlink' "$TEST_ROOT/managed.json" "$(readlink "$config")"
# shellcheck disable=SC2034  # read by the extracted installation function
OS=Linux
rm "$config"
hook_cmux_automation >/dev/null
if [[ ! -e $config ]]; then pass; else fail 'Linux installed Mac automation'; fi
end_scenario
lib_summary 34
