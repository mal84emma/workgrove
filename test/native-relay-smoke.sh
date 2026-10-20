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
# shellcheck source=lib/workgrove/common.sh
source "$REPO/lib/workgrove/common.sh"
trap 'HOME=$ORIGINAL_HOME lib_cleanup' EXIT
mkdir -p "$TEST_ROOT/home/.ssh" "$TEST_ROOT/bin"
export HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/home/.local/state"
export PATH="$TEST_ROOT/bin:$PATH" CMUX_LOG="$TEST_ROOT/cmux.log" CODE_LOG="$TEST_ROOT/code.log"
export CMUX_BUNDLED_CLI_PATH="$TEST_ROOT/bin/cmux" RECORD_FILE="$TEST_ROOT/record.json"
export ROW_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB NOTIFICATION_ID=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
export BACKEND=cmux-tui REMOTE_EXISTS=0
unset CMUX_NOTIFICATION_TITLE CMUX_NOTIFICATION_BODY CMUX_NOTIFICATION_SUBTITLE CMUX_NOTIFICATION_WORKSPACE_ID
unset XDG_DATA_HOME   # the cmux-tui hook wrapper must find its default helper in the scratch home
cat > "$TEST_ROOT/bin/cmux" <<'CMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1 ${2:-}" in
  '--json list-windows') echo '[{"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"}]' ;;
  'workspace list')
    [[ ${CMUX_ROWS_FAIL:-0} == 0 ]] || exit "$CMUX_ROWS_FAIL"
    rows=$(jq -cn --arg w "$ROW_ID" --arg b "$BACKEND" '{workspaces:[{id:$w,title:"task",description:"@test-vm · repo",remote:{enabled:true,destination:"test-vm",backend:$b}}]}')
    if [[ ${CMUX_ROWS_ARRIVING:-0} == 1 ]]; then
      if [[ -e $CMUX_ROWS_COUNTER ]]; then
        rows=$(jq -c '.workspaces += [{id:"arrived-row",title:"new-task",description:"@test-vm · repo",remote:{enabled:true,destination:"test-vm"}}]' <<<"$rows")
      fi
      : >"$CMUX_ROWS_COUNTER"
    fi
    printf '%s\n' "$rows" ;;
  '--json list-notifications') cat "$RECORD_FILE" ;;
  'ssh test-vm') [[ ${CMUX_SSH_FAIL:-0} == 0 ]] || exit "$CMUX_SSH_FAIL"; echo workspace:99 ;;
  'workspace-action --workspace') [[ ${CMUX_TAG_FAIL:-0} == 0 ]] || exit 1 ;;
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

scenario_native_identity() {
  begin_scenario 'tmux rebinds native identity instead of retaining the pane identity' || return 0
  cat > "$TEST_ROOT/bin/tmux" <<'TMUX'
#!/bin/sh
case "$1" in
  display-message) echo native-task ;;
  show-environment)
    echo CMUX_TUI_SOCKET=/tmp/current-native
    echo CMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
esac
TMUX
  chmod +x "$TEST_ROOT/bin/tmux"
  relay_ident=(); relay_tui_socket=''; relay_tui_terminal=''
  TMUX=/tmp/fake CMUX_TUI_SOCKET=/tmp/stale CMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'the native socket comes from the current session' /tmp/current-native "$relay_tui_socket"
  assert_eq 'the native terminal comes from the current session' term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$relay_tui_terminal"
  assert_eq 'the old pane identity does not reach the CLI' 0 "$(printf '%s\n' "${relay_ident[@]}" | grep -cF term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || true)"
  rm "$TEST_ROOT/bin/tmux"
  end_scenario
}
scenario_native_identity

scenario_reattachment() {
  begin_scenario 'reattachment replaces the previous transport and repeated requests survive content suppression' || return 0
  cmux_bin() { printf '%s' "$TEST_ROOT/bin/cmux"; }
  warn() { printf '%s\n' "$*" >&2; }
  export RELAY_STATE="$TEST_ROOT/session-env" RELAY_REQUESTS="$TEST_ROOT/requests.jsonl" RELAY_DELIVERED="$TEST_ROOT/delivered.jsonl"
  mkdir -p "$RELAY_STATE"
  cat > "$TEST_ROOT/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  display-message) echo task ;;
  set-environment) printf '%s' "${5:-}" > "$RELAY_STATE/$4" ;;
  show-environment)
    if [[ $# -eq 4 ]]; then
      [[ -f $RELAY_STATE/$4 ]] && printf '%s=%s\n' "$4" "$(cat "$RELAY_STATE/$4")"
    else
      for file in "$RELAY_STATE"/CMUX_*; do
        [[ -f $file ]] && printf '%s=%s\n' "${file##*/}" "$(cat "$file")"
      done
    fi ;;
  attach)
    # tmux copies update-environment values from the attaching shell after set-environment calls.
    for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do
      printf '%s' "${!v:-}" > "$RELAY_STATE/$v"
    done ;;
esac
exit 0
TMUX
  cat > "$TEST_ROOT/bin/cmux-tui" <<'TUI'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case $1 in --title) title=$2; shift ;; --body) body=$2; shift ;; esac
  shift
done
jq -cn --arg t "$title" --argjson b "$body" '{title:$t,body:$b}' >> "$RELAY_REQUESTS"
# cmux's earlier five-second content gate also returns success for suppressed requests.
if [[ -f $RELAY_STATE/last-content && $(cat "$RELAY_STATE/last-content") == "$title|$body" ]]; then exit 0; fi
printf '%s' "$title|$body" > "$RELAY_STATE/last-content"
tail -n 1 "$RELAY_REQUESTS" >> "$RELAY_DELIVERED"
TUI
  chmod +x "$TEST_ROOT/bin/tmux" "$TEST_ROOT/bin/cmux-tui"
  printf '%s' 127.0.0.1:9999 > "$RELAY_STATE/CMUX_SOCKET_PATH"
  printf '%s' AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA > "$RELAY_STATE/CMUX_WORKSPACE_ID"
  line=$(tmux_cmd task)
  env CMUX_SOCKET_PATH= CMUX_WORKSPACE_ID= CMUX_TUI_SOCKET=/tmp/current-native \
    CMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb CMUX_TUI_SESSION_ID=current "$BASH" -c "$line"
  assert_eq 'native reattachment clears the obsolete TCP socket' '' "$(cat "$RELAY_STATE/CMUX_SOCKET_PATH")"
  assert_eq 'native reattachment clears the obsolete Mac row' '' "$(cat "$RELAY_STATE/CMUX_WORKSPACE_ID")"
  assert_eq 'native reattachment saves its current terminal' term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$(cat "$RELAY_STATE/CMUX_TUI_TERMINAL_ID")"
  : > "$RELAY_REQUESTS"; : > "$RELAY_DELIVERED"; : > "$CMUX_LOG"
  for title in wt-open wt-attach wt-close; do
    for _ in 1 2; do
      TMUX=/tmp/fake CMUX_SOCKET_PATH=127.0.0.1:9999 CMUX_WORKSPACE_ID=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA \
        notify_mac "$title" host test-vm path /vm/repos/repo/.worktrees/task
    done
  done
  assert_eq 'all six identical operations reach native delivery' 6 "$(wc -l < "$RELAY_DELIVERED" | tr -d ' ')"
  assert_eq 'each operation retains its original body fields' true "$(jq -s 'all(.[]; (.body | del(.request_id)) == {host:"test-vm",path:"/vm/repos/repo/.worktrees/task"})' "$RELAY_REQUESTS")"
  assert_eq 'every request gets a distinct ID' 6 "$(jq -s '[.[].body.request_id] | unique | length' "$RELAY_REQUESTS")"
  lacks "$CMUX_LOG" 'notify'
  # Native delivery also wins if an older session still contains both transport identities.
  printf '%s' 127.0.0.1:9999 > "$RELAY_STATE/CMUX_SOCKET_PATH"
  TMUX=/tmp/fake notify_mac wt-open host test-vm path /vm/repos/repo/.worktrees/task
  assert_eq 'a valid native identity overrides stale TCP fields' 7 "$(wc -l < "$RELAY_DELIVERED" | tr -d ' ')"
  rm "$TEST_ROOT/bin/tmux" "$TEST_ROOT/bin/cmux-tui"
  end_scenario
}
scenario_reattachment

scenario_shared_creation() {
  begin_scenario 'native attach uses shared SSH creation and description failure policy' || return 0
  record wt-attach '{"host":"test-vm","repo":"/vm/repos/repo","task":"new-task"}'
  hook >/dev/null
  has "$CMUX_LOG" 'ssh test-vm --name new-task --no-focus --command'
  has "$CMUX_LOG" 'workspace-action --workspace workspace:99 --action set-description --description @test-vm · repo'
  has "$CMUX_LOG" 'dismiss-notification'
  record wt-attach '{"host":"test-vm","repo":"/vm/repos/repo","task":"new-task"}'
  CMUX_TAG_FAIL=1 hook >/dev/null
  has "$CMUX_LOG" 'workspace close workspace:99 --force'
  lacks "$CMUX_LOG" 'dismiss-notification'
  record wt-attach '{"host":"test-vm","repo":"/vm/repos/repo","task":"task"}'
  CMUX_TAG_FAIL=1 hook >/dev/null
  has "$CMUX_LOG" "workspace select $ROW_ID"
  lacks "$CMUX_LOG" 'workspace close'
  has "$CMUX_LOG" 'dismiss-notification'
  has "$XDG_STATE_HOME/cmux-hook.log" "set-description @test-vm · repo failed for $ROW_ID"
  end_scenario
}
scenario_shared_creation

scenario_lookup_race() {
  begin_scenario 'native attach selects a row that arrived after event validation' || return 0
  record wt-attach '{"host":"test-vm","repo":"/vm/repos/repo","task":"new-task"}'
  CMUX_ROWS_ARRIVING=1 CMUX_ROWS_COUNTER="$TEST_ROOT/row-snapshot" hook >/dev/null
  has "$CMUX_LOG" 'workspace select arrived-row'
  lacks "$CMUX_LOG" 'ssh test-vm'
  has "$CMUX_LOG" 'dismiss-notification'
  rm "$TEST_ROOT/row-snapshot"
  end_scenario
}
scenario_lookup_race

scenario_lookup_diagnostics() {
  begin_scenario 'native lookup failures keep diagnostics without notification effects' || return 0
  local rc out message logged
  for rc in 142 7; do
    record wt-attach '{"host":"test-vm","repo":"/vm/repos/repo","task":"new-task"}'
    out=$(CMUX_ROWS_FAIL=$rc hook)
    logged=''
    if [[ -f $XDG_STATE_HOME/cmux-hook.log ]]; then
      logged=$(tail -1 "$XDG_STATE_HOME/cmux-hook.log")
      logged=${logged#* }
    fi
    if [[ $rc == 142 ]]; then message='the cmux row list hit the hook deadline (capped exit 142)'
    else message='the cmux row list failed (exit 7)'; fi
    assert_eq "exit $rc records its diagnostic" "$message" "$logged"
    assert_eq "exit $rc prints no suppression response" '' "$out"
    lacks "$CMUX_LOG" 'ssh test-vm'
    lacks "$CMUX_LOG" 'dismiss-notification'
  done
  end_scenario
}
scenario_lookup_diagnostics

scenario_event_diagnostics() {
  begin_scenario 'event shape failures retain distinct diagnostics and exit zero' || return 0
  local original=$CMUX_AUTOMATION_EVENT_JSON filter reason out
  record wt-open '{"host":"test-vm","path":"/vm/repos/repo"}'
  while IFS=$'\t' read -r filter reason; do
    : > "$XDG_STATE_HOME/cmux-hook.log"
    out=$(CMUX_AUTOMATION_EVENT_JSON=$(jq -c "$filter" <<<"$original") hook)
    assert_eq 'a dropped event prints no response' '' "$out"
    has "$XDG_STATE_HOME/cmux-hook.log" "$reason"
  done <<'CASES'
.name2 = .name | del(.name)	missing or invalid event name
.payload.id = .payload.notification_id | del(.payload.notification_id)	missing or invalid notification id
.workspace = .workspace_id | del(.workspace_id)	missing or invalid workspace id
.payload.notification_id = "bad"	malformed notification id
.workspace_id = "bad"	malformed workspace id
.payload.notification_id = "------------------------------------"	malformed notification id
.workspace_id = "------------------------------------"	malformed workspace id
.payload.notification_id = "AAAAAAAAA-AAA-4AAA-8AAA-AAAAAAAAAAAA"	malformed notification id
.workspace_id = "BBBBBBBBB-BBB-4BBB-8BBB-BBBBBBBBBBBB"	malformed workspace id
CASES
  end_scenario
}
scenario_event_diagnostics

scenario_record_diagnostics() {
  begin_scenario 'record and request failures name the failed check' || return 0
  local filter reason title body out
  while IFS=$'\t' read -r filter reason; do
    record wt-open '{"host":"test-vm","path":"/vm/repos/repo"}'
    jq "$filter" "$RECORD_FILE" > "$TEST_ROOT/changed-record"
    mv "$TEST_ROOT/changed-record" "$RECORD_FILE"
    : > "$XDG_STATE_HOME/cmux-hook.log"
    out=$(hook)
    assert_eq 'record failure leaves effects unchanged' '' "$out"
    has "$XDG_STATE_HOME/cmux-hook.log" "$reason"
  done <<'CASES'
[]	not found for workspace
.[0].title = null	title is not a string
.[0].body = {}	body is not a string
.[0].title = "ordinary notification"	title is not a wt request
CASES
  while IFS=$'\t' read -r title body reason; do
    record "$title" "$body"
    : > "$XDG_STATE_HOME/cmux-hook.log"
    out=$(hook)
    assert_eq 'invalid request leaves effects unchanged' '' "$out"
    has "$XDG_STATE_HOME/cmux-hook.log" "ignored $title: $reason"
    lacks "$CMUX_LOG" 'dismiss-notification'
  done <<'CASES'
wt-open	{"host":"bad host","path":"/vm/repos/repo"}	invalid host
wt-open	{"host":"unknown-vm","path":"/vm/repos/repo"}	unknown SSH host
wt-open	{"host":"test-vm","path":"relative"}	unsafe path
wt-attach	{"host":"bad host","repo":"/vm/repos/repo","task":"task"}	invalid host
wt-attach	{"host":"unknown-vm","repo":"/vm/repos/repo","task":"task"}	unknown SSH host
wt-attach	{"host":"test-vm","repo":"relative","task":"task"}	unsafe repo path
wt-attach	{"host":"test-vm","repo":"/vm/repos/repo","task":"bad name"}	invalid task name
CASES
  printf 'Host other-vm\n' >> "$HOME/.ssh/config"
  for title in wt-open wt-attach; do
    record "$title" '{"host":"other-vm","path":"/vm/repos/repo","repo":"/vm/repos/repo","task":"task"}'
    : > "$XDG_STATE_HOME/cmux-hook.log"
    hook >/dev/null
    has "$XDG_STATE_HOME/cmux-hook.log" "ignored $title: sending row does not match host"
  done
  end_scenario
}
scenario_record_diagnostics

scenario_request_execution_diagnostics() {
  begin_scenario 'unavailable VS Code and failed attach requests keep notifications' || return 0
  local out rc=0
  record wt-open '{"host":"test-vm","path":"/vm/repos/repo"}'
  : > "$XDG_STATE_HOME/cmux-hook.log"
  # An exported function resolves to a name without an executable file, on every test machine.
  out=$(
    # shellcheck disable=SC2329  # command -v inspects this exported function.
    code() { return 1; }
    export -f code
    hook
  ) || rc=$?
  assert_eq 'unavailable VS Code exits zero' 0 "$rc"
  assert_eq 'unavailable VS Code prints no response' '' "$out"
  has "$XDG_STATE_HOME/cmux-hook.log" 'ignored wt-open: VS Code executable unavailable'
  lacks "$CODE_LOG" '--folder-uri'
  lacks "$CMUX_LOG" 'dismiss-notification'

  record wt-attach '{"host":"test-vm","repo":"/vm/repos/child","task":"child"}'
  : > "$XDG_STATE_HOME/cmux-hook.log"
  rc=0
  out=$(CMUX_SSH_FAIL=7 hook) || rc=$?
  assert_eq 'failed attach exits zero' 0 "$rc"
  assert_eq 'failed attach prints no response' '' "$out"
  has "$XDG_STATE_HOME/cmux-hook.log" 'ignored wt-attach: could not attach row for workspace'
  has "$XDG_STATE_HOME/cmux-hook.log" 'cmux ssh failed:'
  lacks "$CMUX_LOG" 'dismiss-notification'
  end_scenario
}
scenario_request_execution_diagnostics

scenario_native_open() {
  begin_scenario 'native open uses the recorded ID and validates the sending row' || return 0
  record wt-open '{"host":"test-vm","path":"/vm/repos/repo/.worktrees/task","request_id":"unique"}'
  hook >/dev/null
  has "$CODE_LOG" '--folder-uri vscode-remote://ssh-remote+test-vm/vm/repos/repo/.worktrees/task/'
  has "$CMUX_LOG" "dismiss-notification --id $NOTIFICATION_ID"
  has "$XDG_STATE_HOME/cmux-hook.log" "handled wt-open for workspace $ROW_ID"
  export BACKEND=legacy
  : > "$XDG_STATE_HOME/cmux-hook.log"
  : > "$CODE_LOG"; : > "$CMUX_LOG"
  hook >/dev/null
  lacks "$CODE_LOG" '--folder-uri'
  lacks "$CMUX_LOG" 'list-notifications'
  has "$XDG_STATE_HOME/cmux-hook.log" 'remote.backend is not cmux-tui'
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
}
scenario_native_open

scenario_native_attach_close() {
  begin_scenario 'native attach and close preserve the existing control checks' || return 0
  record wt-attach '{"host":"test-vm","repo":"/vm/repos/child","task":"child"}'
  hook >/dev/null
  has "$CMUX_LOG" 'ssh test-vm --name child --no-focus'
  has "$CMUX_LOG" 'workspace-action --workspace workspace:99 --action set-description --description @test-vm · child'
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
}
scenario_native_attach_close

scenario_notification_budget() {
  begin_scenario 'notification bursts do not consume the open request budget' || return 0
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
}
scenario_notification_budget

setup_automation() {
# shellcheck source=lib/workgrove/automation.sh
source "$REPO/lib/workgrove/automation.sh"
# shellcheck disable=SC2034  # read by the installation module
OS=Darwin
# shellcheck disable=SC2034  # read by the installation module
R=$REPO
BK="$TEST_ROOT/backup"
# shellcheck disable=SC2034  # read by the installation module
TMPFILES=()
SUMMARY_SKIPS=() SUMMARY_ACTIONS=()
stash() { mkdir -p "$BK/$(dirname "${1#"$HOME"/}")"; mv "$1" "$BK/${1#"$HOME"/}"; }
config="$HOME/.cmuxterm/automations.json"
}

scenario_automation_merge() {
  begin_scenario 'automation installation preserves user rules and backups' || return 0
  setup_automation
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
  # shellcheck disable=SC2034  # read by the installation module
  OS=Linux
  rm "$config"
  hook_cmux_automation >/dev/null
  if [[ ! -e $config ]]; then pass; else fail 'Linux installed Mac automation'; fi
  end_scenario
}
scenario_automation_merge

scenario_numeric_schema_versions() {
  begin_scenario 'equivalent numeric schema versions remain supported' || return 0
  setup_automation
  mkdir -p "${config%/*}"
  local version sum
  for version in 1.0 1e0; do
    printf '{"version":%s,"rules":[{"id":"user-rule"}]}\n' "$version" > "$config"
    sum=$(cksum < "$config")
    hook_cmux_automation > "$TEST_ROOT/numeric.out" 2> "$TEST_ROOT/numeric.err"
    assert_eq "$version retains user rules and installs the relay" 'user-rule wt-native-relay' "$(jq -r '.rules | map(.id) | join(" ")' "$config")"
    assert_eq "$version does not report an unknown version" '' "$(cat "$TEST_ROOT/numeric.err")"
    has "$TEST_ROOT/numeric.out" 'cmux automation reload'
    assert_eq "$version backs up the original file" "$sum" "$(cksum < "$BK/.cmuxterm/automations.json")"
  done
  rm "$config"
  end_scenario
}
scenario_numeric_schema_versions

scenario_automation_updates() {
  begin_scenario 'automation updates replace stale rules and preserve explicit disabling' || return 0
  setup_automation
  mkdir -p "${config%/*}"
  local disabled sum out
  for disabled in true false; do
    jq --argjson enabled "$disabled" '.rules[0].enabled = $enabled | .rules[0].then[0].command = "old-hook" | .rules += [{id:"user-rule"}]' \
      "$REPO/home/.cmuxterm/automations.json" > "$config"
    sum=$(cksum < "$config")
    out=$(hook_cmux_automation)
    has <(printf '%s' "$out") 'cmux automation reload'
    # shellcheck disable=SC2088  # The rule stores the literal home-relative command.
    assert_eq 'the stale command is replaced' '~/.local/bin/cmux-hook --event' "$(jq -r '.rules[0].then[0].command' "$config")"
    assert_eq 'an explicit disable remains disabled' "$disabled" "$(jq -r '.rules[0] | if has("enabled") then .enabled else true end' "$config")"
    assert_eq 'the user rule stays in place' user-rule "$(jq -r '.rules[1].id' "$config")"
    assert_eq 'the stale file is backed up' "$sum" "$(cksum < "$BK/.cmuxterm/automations.json")"
    sum=$(cksum < "$config")
    hook_cmux_automation >/dev/null
    assert_eq 'updated rules are idempotent' "$sum" "$(cksum < "$config")"
  done
  printf '%s\n' '{"version":99,"rules":[]}' > "$config"
  sum=$(cksum < "$config")
  hook_cmux_automation >"$TEST_ROOT/version.out" 2>"$TEST_ROOT/version.err"
  has "$TEST_ROOT/version.err" 'unknown automations.json version 99'
  lacks "$TEST_ROOT/version.out" 'unknown automations.json version'
  assert_eq 'an unknown version stays unchanged' "$sum" "$(cksum < "$config")"
  rm "$config"
  end_scenario
}
scenario_automation_updates

scenario_installed_rule() {
  begin_scenario 'the installed native rule dispatches an open request through its configured command' || return 0
  setup_automation
  OS=Darwin hook_cmux_automation >/dev/null
  mkdir -p "$HOME/.local/bin"
  ln -s "$REPO/bin/cmux-hook" "$HOME/.local/bin/cmux-hook"
  assert_eq 'the installed rule listens for notification creation' notification.created \
    "$(jq -r '.rules[] | select(.id == "wt-native-relay") | .when.event' "$config")"
  assert_eq 'the installed rule is enabled' true \
    "$(jq -r '.rules[] | select(.id == "wt-native-relay") | if has("enabled") then .enabled else true end' "$config")"
  record wt-open '{"host":"test-vm","path":"/vm/repos/repo/.worktrees/task","request_id":"installed-rule"}'
  command=$(jq -r '.rules[] | select(.id == "wt-native-relay") | .then[] | select(.action == "run") | .command' "$config")
  "$BASH" -c "$command" </dev/null >/dev/null
  has "$CODE_LOG" '--folder-uri vscode-remote://ssh-remote+test-vm/vm/repos/repo/.worktrees/task/'
  has "$CMUX_LOG" "dismiss-notification --id $NOTIFICATION_ID"
  end_scenario
}
scenario_installed_rule

scenario_agent_hooks() {
  begin_scenario 'cmux-tui agent hooks report to the terminal that the tmux session names' || return 0
  # The fake tmux has one session. TMUX_ENV holds its environment, one NAME=value or -NAME per line.
  # The two query branches read stdin, so a wrapper that does not redirect it loses the agent's payload.
  # When TMUX_CALLS is set, each call adds a line to it.
  cat > "$TEST_ROOT/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
[[ -z ${TMUX_CALLS:-} ]] || printf '%s\n' "$1" >> "$TMUX_CALLS"
case $1 in
  display-message) cat >/dev/null; echo task-session ;;
  show-environment) cat >/dev/null; cat "$TMUX_ENV" ;;
  *) exit 1 ;;   # no other session exists, so the session name is free
esac
TMUX
  cat > "$TEST_ROOT/tui-helper" <<'HELPER'
#!/usr/bin/env bash
{ printf 'args=%s\n' "$*"; printf 'stdin=%s\n' "$(cat)"; env | grep '^CMUX_TUI_' | sort; } > "$HELPER_LOG"
HELPER
  chmod +x "$TEST_ROOT/bin/tmux" "$TEST_ROOT/tui-helper"
  export TMUX_ENV="$TEST_ROOT/tmux.env" HELPER_LOG="$TEST_ROOT/helper.log"
  tui_hook() { # tui_hook [helper] — run the wrapper once, and stop it after 5 s.
    # exec keeps the wrapper's PID. So a wrapper that runs itself is still alive at the deadline, and its
    # checks fail instead of hanging the suite.
    local pid i
    : > "$TEST_ROOT/tmux.calls"
    printf '%s' '{"hook_event_name":"Stop"}' > "$TEST_ROOT/payload"
    TMUX=/tmp/fake,1,0 TMUX_PANE=%1 WT_CMUX_TUI_HOOK="${1:-$TEST_ROOT/tui-helper}" \
      CMUX_TUI_SOCKET=/run/old.sock CMUX_TUI_TERMINAL_ID=term_old CMUX_TUI_SESSION_ID=session_old \
      TMUX_CALLS="$TEST_ROOT/tmux.calls" "$REPO/lib/workgrove/cmux-tui-hook.sh" claude Stop <"$TEST_ROOT/payload" &
    pid=$!
    for ((i = 0; i < 50; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      fail 'the cmux-tui hook wrapper did not finish within 5 s'
    else
      pass
    fi
    wait "$pid" 2>/dev/null || true
  }
  printf '%s\n' CMUX_TUI_SOCKET=/run/new.sock CMUX_TUI_TERMINAL_ID=term_new CMUX_TUI_SESSION_ID= > "$TMUX_ENV"
  tui_hook
  has "$HELPER_LOG" 'args=claude Stop'
  has "$HELPER_LOG" 'stdin={"hook_event_name":"Stop"}'
  has "$HELPER_LOG" 'CMUX_TUI_SOCKET=/run/new.sock'
  has "$HELPER_LOG" 'CMUX_TUI_TERMINAL_ID=term_new'
  lacks "$HELPER_LOG" 'term_old'
  lacks "$HELPER_LOG" 'CMUX_TUI_SESSION_ID'
  # A name that the session does not hold keeps the pane's value. A removed name is unset.
  printf '%s\n' -CMUX_TUI_TERMINAL_ID > "$TMUX_ENV"
  tui_hook
  has "$HELPER_LOG" 'CMUX_TUI_SOCKET=/run/old.sock'
  has "$HELPER_LOG" 'CMUX_TUI_SESSION_ID=session_old'
  lacks "$HELPER_LOG" 'CMUX_TUI_TERMINAL_ID'
  # A saved helper that is another checkout's wrapper falls back to the default helper. It must not loop.
  mkdir -p "$HOME/.local/share/cmux-tui/bin"
  cp "$TEST_ROOT/tui-helper" "$HOME/.local/share/cmux-tui/bin/cmux-tui-hook"
  rm -f "$HELPER_LOG"
  tui_hook "$REPO/./bin/../lib/workgrove/cmux-tui-hook.sh"
  has "$HELPER_LOG" 'args=claude Stop'
  assert_eq 'the wrapper runs once and makes two tmux calls' 2 "$(wc -l < "$TEST_ROOT/tmux.calls" | tr -d ' ')"

  # wt run gives its agent the wrapper and keeps the helper that cmux-tui set. Run wt through a link, as
  # install.sh does, so that the wrapper path must be resolved to the repository.
  mkdir -p "$HOME/.local/bin" "$TEST_ROOT/repo"
  ln -s "$REPO/bin/wt" "$HOME/.local/bin/wt"
  git -C "$TEST_ROOT/repo" init -q -b main
  git -C "$TEST_ROOT/repo" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m initial
  bash "$HOME/.local/bin/wt" new task -a claude --no-workspace -r "$TEST_ROOT/repo" >/dev/null
  cat > "$TEST_ROOT/bin/claude" <<'AGENT'
#!/bin/sh
printf 'hook=%s\nhelper=%s\n' "${CMUX_TUI_HOOK:-}" "${WT_CMUX_TUI_HOOK:-}" > "$AGENT_ENV"
AGENT
  chmod +x "$TEST_ROOT/bin/claude"
  export AGENT_ENV="$TEST_ROOT/agent.env"
  wrapper="$REPO/bin/../lib/workgrove/cmux-tui-hook.sh"
  (cd "$TEST_ROOT" && CMUX_SSH_ATTEMPT_ID=1 TMUX=/tmp/fake,1,0 TMUX_PANE=%1 CMUX_TUI_HOOK=/opt/cmux-tui-hook \
    "$HOME/.local/bin/wt" run task -r "$TEST_ROOT/repo" >/dev/null)
  assert_eq 'wt run points the hooks at the wrapper' "hook=$wrapper" "$(sed -n 1p "$AGENT_ENV")"
  assert_eq 'wt run keeps the cmux-tui helper' 'helper=/opt/cmux-tui-hook' "$(sed -n 2p "$AGENT_ENV")"
  # A nested wt run must not save a wrapper as the helper, even when it spells the wrapper's path differently.
  (cd "$TEST_ROOT" && CMUX_SSH_ATTEMPT_ID=1 TMUX=/tmp/fake,1,0 TMUX_PANE=%1 CMUX_TUI_HOOK="$REPO/./bin/../lib/workgrove/cmux-tui-hook.sh" \
    WT_CMUX_TUI_HOOK=/opt/cmux-tui-hook "$HOME/.local/bin/wt" run task -r "$TEST_ROOT/repo" >/dev/null)
  assert_eq 'a nested wt run keeps the cmux-tui helper' 'helper=/opt/cmux-tui-hook' "$(sed -n 2p "$AGENT_ENV")"
  # Outside tmux, the pane's identity is the row's identity, so the hooks need no wrapper.
  (cd "$TEST_ROOT" && unset TMUX && CMUX_SSH_ATTEMPT_ID=1 CMUX_TUI_HOOK=/opt/cmux-tui-hook \
    "$HOME/.local/bin/wt" run task -r "$TEST_ROOT/repo" >/dev/null)
  assert_eq 'wt run outside tmux leaves the hooks alone' 'hook=/opt/cmux-tui-hook' "$(sed -n 1p "$AGENT_ENV")"
  end_scenario
}
scenario_agent_hooks
lib_summary
