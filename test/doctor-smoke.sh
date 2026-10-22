#!/usr/bin/env bash
# Check the contract probe with recorded responses and scratch hook files.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-doctor.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=test/fakes/rows.sh
source "$REPO/test/fakes/rows.sh"
DOCTOR_REAL_HOME=$HOME
trap 'HOME=$DOCTOR_REAL_HOME lib_cleanup' EXIT
mkdir -p "$TEST_ROOT/home/.claude" "$TEST_ROOT/home/.codex" "$TEST_ROOT/home/.local/bin" \
  "$TEST_ROOT/bin" "$TEST_ROOT/fixtures" "$TEST_ROOT/repos"
export HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH" CMUX_FIXTURES="$TEST_ROOT/fixtures"
export CMUX_BUNDLED_CLI_PATH="$REPO/test/fakes/cmux"
unset CMUX_SSH_ATTEMPT_ID CMUX_RUN WT_CMUX_TUI_HOOK CMUX_TUI_HOOK XDG_DATA_HOME
printf '#!/bin/sh\necho Darwin\n' >"$TEST_ROOT/bin/uname"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/cmux-hook"
printf '#!/bin/sh\nexit 99\n' >"$HOME/.local/bin/a hook"
chmod +x "$TEST_ROOT/bin/uname" "$HOME/.local/bin/"*
ln -s "$REPO/bin/wt" "$HOME/.local/bin/wt"
for config in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
  cat >"$config" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"SOURCE='a value' \"$HOME/.local/bin/a hook\""}]}]}}
JSON
done
cp "$FAKE_CMUX_FIXTURES/version.txt" "$FAKE_CMUX_FIXTURES/capabilities.json" "$CMUX_FIXTURES/"
jq '[.[0] | .id="AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" | .title="private-window"
  | .selected_workspace_id="BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"]' \
  "$FAKE_CMUX_FIXTURES/windows.json" >"$CMUX_FIXTURES/windows.json"
fake_rows "$(fake_row BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB private-title '@secretvm · secret-repo' secretvm \
  | jq -c '.current_directory="/Users/secretuser/repos/private"')" >"$CMUX_FIXTURES/rows.json"
fake_top BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB 1 >"$CMUX_FIXTURES/top.json"
jq '[.[0] | .id="CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
  | .workspace_id="BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB" | .title="private-title"
  | .body="/home/secretuser secretvm" | .secretuser="secretvm"]' \
  "$FAKE_CMUX_FIXTURES/notifications.json" >"$CMUX_FIXTURES/notifications.json"
cp "$REPO/home/.cmuxterm/automations.json" "$TEST_ROOT/rules.json"
jq '.rules[0]' "$TEST_ROOT/rules.json" >"$CMUX_FIXTURES/automation.json"
jq '.workspace_id="BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
  | .payload.notification_id="CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
  | .payload.body="private-title secretvm"' "$FAKE_CMUX_FIXTURES/event.json" >"$CMUX_FIXTURES/event.json"

invoke() {
  if [[ -n ${FAKE_CMUX_STATE:-} ]]; then
    jq -cn --arg status "${TUI_CODEX_STATUS:-installed}" \
      '{action:"status",errors:[],providers:[{provider:"claude",state:"installed"},{provider:"codex",state:$status}]}' \
      >"$FAKE_CMUX_STATE/agent-hook-status.json"
    if [[ ${TUI_BAD_JSON:-0} == 1 ]]; then printf 'action status\nproviders []\n' >"$FAKE_CMUX_STATE/agent-hook-status.json"; fi
  fi
  STATUS=0
  bash "$REPO/bin/wt" "$@" >"$TEST_ROOT/output" 2>&1 || STATUS=$?
}

scenario_readiness_dispatch() {
  begin_scenario 'portable readiness options remain separate from contract checks' || return 0
  invoke doctor --environment --json
  if jq -e '.schema == 1 and (.issues | type == "array") and has("native_relay")' "$TEST_ROOT/output" >/dev/null; then
    pass
  else
    fail 'explicit environment mode did not return readiness JSON'
  fi
  invoke doctor --json --root "$TEST_ROOT/missing-root"
  if jq -e '.ready == false and (.issues | index("portable-profile-missing") != null)' "$TEST_ROOT/output" >/dev/null; then
    pass
  else
    fail 'root and JSON options did not select readiness'
  fi
  invoke doctor --environment --record "$TEST_ROOT/mixed-record"
  assert_eq 'mixed diagnostic modes fail' 1 "$STATUS"
  assert_grep 'mixed modes explain the conflict' "$TEST_ROOT/output" 'doctor: --record cannot be combined'
  assert_absent "$TEST_ROOT" mixed-record
  end_scenario
}

scenario_mac() {
  begin_scenario 'Mac contract checks pass and detect unsupported releases and missing methods' || return 0
  invoke doctor
  assert_eq 'supported cmux passes' 0 "$STATUS"
  assert_grep 'the commit and protocol are reported' "$TEST_ROOT/output" 'PASS wt version {"commit":'
  for version in 0.64.0 0.65.2; do
    FAKE_CMUX_VERSION=$version invoke doctor
    assert_eq "$version warns" 1 "$STATUS"
    assert_grep 'warning names the verified release' "$TEST_ROOT/output" 'verified 0.65.1'
    assert_grep 'warning explains the support policy' "$TEST_ROOT/output" 'older and newer versions need verification'
    assert_grep 'repair downloads the verified release' "$TEST_ROOT/output" 'releases/download/v0.65.1/cmux-macos.dmg'
    assert_grep 'repair installs the app from that release' "$TEST_ROOT/output" "ditto \"\$d/mount/cmux.app\" /Applications/cmux.app"
    assert_grep 'repair warns before replacing the app' "$TEST_ROOT/output" 'Quit cmux before running this command.'
    local repair_command
    repair_command=$(sed -n 's/^  Fix: //p' "$TEST_ROOT/output" | head -1)
    if bash -n <<<"$repair_command"; then pass; else fail 'the installer command is not valid shell syntax'; fi
  done
  FAKE_CMUX_MISSING_METHOD=workspace.remote.reconnect invoke doctor
  assert_eq 'a missing method fails' 1 "$STATUS"
  assert_grep 'missing method is named' "$TEST_ROOT/output" 'FAIL cmux method workspace.remote.reconnect'
  assert_grep 'later checks still run' "$TEST_ROOT/output" 'PASS wt version'
  end_scenario
}

scenario_shapes_and_hooks() {
  begin_scenario 'malformed responses and missing hook paths fail without executing hooks' || return 0
  local file
  for file in rows top notifications automation; do
    cp "$CMUX_FIXTURES/$file.json" "$TEST_ROOT/saved.json"
    printf '{}\n' >"$CMUX_FIXTURES/$file.json"
    invoke doctor
    assert_eq "$file shape fails" 1 "$STATUS"
    assert_grep "$file failure includes a repair" "$TEST_ROOT/output" 'Fix:'
    mv "$TEST_ROOT/saved.json" "$CMUX_FIXTURES/$file.json"
  done
  mv "$HOME/.local/bin/a hook" "$HOME/.local/bin/saved-hook"
  invoke doctor
  assert_eq 'missing hook fails' 1 "$STATUS"
  assert_grep 'missing hook is named' "$TEST_ROOT/output" 'FAIL hook command'
  mv "$HOME/.local/bin/saved-hook" "$HOME/.local/bin/a hook"
  # A substitution in a hook must never run during a probe.
  jq --arg command "\$(touch '$TEST_ROOT/executed')" '.hooks.Stop[0].hooks[0].command=$command' \
    "$HOME/.claude/settings.json" >"$TEST_ROOT/hook.json"
  cp "$HOME/.claude/settings.json" "$TEST_ROOT/settings.json"
  mv "$TEST_ROOT/hook.json" "$HOME/.claude/settings.json"
  invoke doctor
  assert_eq 'an unresolved substitution fails' 1 "$STATUS"
  assert_absent "$TEST_ROOT" executed
  mv "$TEST_ROOT/settings.json" "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$TEST_ROOT/settings.json"
  jq '.hooks.Stop[0].hooks[0].command = "bad\u0000command"' \
    "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
  invoke doctor
  assert_eq 'NUL bytes fail configuration validation' 1 "$STATUS"
  assert_grep 'a NUL byte names the invalid configuration' "$TEST_ROOT/output" 'FAIL hook configuration'
  mv "$TEST_ROOT/settings.json" "$HOME/.claude/settings.json"
  local command
  cp "$HOME/.claude/settings.json" "$TEST_ROOT/settings.json"
  # shellcheck disable=SC2016  # The probe reads these shell expressions without executing them.
  for command in 'env SOURCE=Claude ~/.local/bin/cmux-hook' \
      '/usr/bin/env SOURCE=Claude ~/.local/bin/cmux-hook' \
      'bash -c "~/.local/bin/cmux-hook"' \
      'sh "$HOME/.local/bin/a hook"' \
      'env -u OLD ~/.local/bin/cmux-hook' \
      'bash --norc -e -c "~/.local/bin/cmux-hook"' \
      'true && ~/.local/bin/cmux-hook' \
      'printf data | ~/.local/bin/cmux-hook' \
      $'true\n~/.local/bin/cmux-hook'; do
    jq --arg command "$command" '.hooks.Stop[0].hooks[0].command=$command' \
      "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
    invoke doctor
    assert_eq "a valid hook resolves: $command" 0 "$STATUS"
  done
  for command in 'env exec /usr/bin/true' 'env command /missing/hook' '/usr/bin/env /missing/hook' '/missing/env true' 'true && /missing/hook' 'printf data | /missing/hook' \
      $'true\n/missing/hook' 'bash -c "true && /missing/hook"'; do
    jq --arg command "$command" '.hooks.Stop[0].hooks[0].command=$command' \
      "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
    invoke doctor
    assert_eq "a missing later hook fails: $command" 1 "$STATUS"
    assert_grep 'a missing later helper is reported' "$TEST_ROOT/output" 'FAIL hook command'
  done
  printf 'PATH=/nonexistent\n' >"$TEST_ROOT/hook-startup"
  local shell_status=0
  LC_ALL=C bash --noprofile --rcfile "$TEST_ROOT/hook-startup" -ic jq >"$TEST_ROOT/startup-output" 2>&1 || shell_status=$?
  assert_eq 'a shell startup file can invalidate inherited lookup' 127 "$shell_status"
  for command in "bash --rcfile $(printf '%q' "$TEST_ROOT/hook-startup") -ic jq" \
      "bash --init-file $(printf '%q' "$TEST_ROOT/hook-startup") -c true" \
      'bash -lc true' 'sh -ic true' 'bash --login -c true' 'bash -rz -c true'; do
    jq --arg command "$command" '.hooks.Stop[0].hooks[0].command=$command' \
      "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
    invoke doctor
    assert_eq "initialization-changing options cannot pass: $command" 1 "$STATUS"
    assert_grep 'shell initialization receives an explicit warning' "$TEST_ROOT/output" 'WARN hook command needs a static helper'
  done
  mkdir -p "${HOME}_UNSET"
  cp "$HOME/.local/bin/cmux-hook" "${HOME}_UNSET/hook"
  # shellcheck disable=SC2016  # The parser must not confuse HOME_UNSET with HOME.
  for command in 'PATH=/missing bash -c true' 'env PATH=/missing bash -c true' \
      '/usr/bin/env -u PATH bash -c true' 'env -i bash -c true' \
      'HOME=/missing sh -c true' "'SOURCE=Claude' true" "SOUR'CE'=Claude true" '"$HOME_UNSET/hook"' 'cd /missing; true'; do
    jq --arg command "$command" '.hooks.Stop[0].hooks[0].command=$command' \
      "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
    invoke doctor
    assert_eq "environment-dependent lookup cannot pass: $command" 1 "$STATUS"
    assert_grep 'lookup changes receive an explicit warning' "$TEST_ROOT/output" 'WARN hook command needs a static helper'
  done
  # shellcheck disable=SC2016  # Dynamic shell code must receive a warning without running.
  jq --arg command 'd=$(touch "$HOME/executed"); true' '.hooks.Stop[0].hooks[0].command=$command' \
    "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
  invoke doctor
  assert_eq 'dynamic shell code cannot pass static validation' 1 "$STATUS"
  assert_grep 'dynamic shell code has an explicit warning' "$TEST_ROOT/output" 'WARN hook command needs a static helper'
  assert_absent "$HOME" executed
  jq --arg command 'bash -c "/missing/hook"' '.hooks.Stop[0].hooks[0].command=$command' \
    "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
  invoke doctor
  assert_eq 'a missing hook inside a shell fails' 1 "$STATUS"
  mv "$TEST_ROOT/settings.json" "$HOME/.claude/settings.json"
  end_scenario
}

scenario_reference_redaction() {
  begin_scenario 'redaction preserves synthetic reference relationships' || return 0
  local sanitized
  sanitized=$(jq -cn '{rows:{workspaces:[{ref:"workspace:91"},{ref:"workspace:37"}],window_ref:"window:19"},
    rows_by_window:[{workspaces:[{ref:"workspace:91"}],window_ref:"window:19"}],body:"workspace:91"}' \
    | jq -cf "$REPO/lib/workgrove/doctor-sanitize.jq")
  assert_eq 'workspace refs remain valid and distinct' true "$(jq '[.rows.workspaces[].ref] | (unique | length) == 2 and all(.[]; test("^workspace:[1-9][0-9]*$"))' <<<"$sanitized")"
  assert_eq 'repeated workspace refs keep their relationship' true "$(jq '.rows.workspaces[0].ref == .rows_by_window[0].workspaces[0].ref' <<<"$sanitized")"
  assert_eq 'window refs remain valid and consistent' true "$(jq '.rows.window_ref == "window:1" and .rows.window_ref == .rows_by_window[0].window_ref' <<<"$sanitized")"
  assert_eq 'free text matching a ref still gets redacted' '<redacted>' "$(jq -r .body <<<"$sanitized")"
  end_scenario
}

scenario_recorded_contract() {
  begin_scenario 'the real cmux capture preserves the supported contract' || return 0
  CMUX_FIXTURES=$FAKE_CMUX_FIXTURES invoke doctor
  assert_eq 'the recorded real responses pass doctor' 0 "$STATUS"
  assert_eq 'recorded rows retain public schema fields' true "$(jq '
    all(.workspaces[]; has("ref") and has("has_custom_title") and (.remote | has("terminal_transport")))
    and any(.workspaces[]; .remote.enabled and .remote.backend == "cmux-tui")' "$FAKE_CMUX_FIXTURES/rows.json")"
  end_scenario
}

scenario_record() {
  begin_scenario 'recorded fixtures redact identities and replay through the fake cmux' || return 0
  cp "$CMUX_FIXTURES/windows.json" "$TEST_ROOT/saved-windows.json"
  jq '. + [{id:"EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE",title:"private-window-two"}]' \
    "$TEST_ROOT/saved-windows.json" >"$CMUX_FIXTURES/windows.json"
  jq -n --slurpfile rows "$CMUX_FIXTURES/rows.json" '{
    "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA":$rows[0],
    "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE":{workspaces:[{id:"DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",title:"private-title-two"}]}
  }' >"$CMUX_FIXTURES/rows_by_window.json"
  invoke doctor --record "$TEST_ROOT/recorded"
  assert_eq 'record succeeds' 0 "$STATUS"
  local dir="$TEST_ROOT/recorded/cmux-0.65.1" file
  printf '%s\n' '{"title":"run","body":"local","subtitle":"notification.created","description":"cmux-tui","current_directory":"run","remote":{"destination":"connected","state":"connected","backend":"cmux-tui"}}' \
    | jq -cf "$REPO/lib/workgrove/doctor-sanitize.jq" >"$TEST_ROOT/enum-collisions.json"
  assert_eq 'free text cannot bypass redaction by matching an enum' \
    '{"title":"<title>","body":"<redacted>","subtitle":"<redacted>","description":"@<test-vm> · <repo>","current_directory":"<path>","remote":{"destination":"<test-vm>","state":"connected","backend":"cmux-tui"}}' \
    "$(cat "$TEST_ROOT/enum-collisions.json")"
  for file in rows windows top notifications automation capabilities event rows_by_window; do
    assert_regular "$dir" "$file.json"
    if jq -e . "$dir/$file.json" >/dev/null; then pass; else fail "$file is invalid JSON"; fi
  done
  local search_status=0
  grep -RE 'secretvm|secretuser|private-title|private-window|/Users/|/home/|secret-repo' "$dir" >"$TEST_ROOT/private-text" 2>&1 || search_status=$?
  case $search_status in
    0) fail 'recorded fixtures contain private text' ;;
    1) pass ;;
    *) fail "privacy search failed with status $search_status" ;;
  esac
  assert_grep 'records are marked as redacted' "$dir/REDACTED.txt" Redacted
  assert_eq 'event identity still matches its notification' \
    "$(jq -r '.[0].id' "$dir/notifications.json")" "$(jq -r '.payload.notification_id' "$dir/event.json")"
  CMUX_FIXTURES=$dir invoke doctor
  assert_eq 'redacted fixtures pass the contract probe' 0 "$STATUS"
  local replay_count
  replay_count=$(CMUX_FIXTURES=$dir bash -c 'source "$1/lib/workgrove/common.sh"; rows_json checked | jq ".workspaces | length"' bash "$REPO")
  assert_eq 'two recorded windows replay exactly two rows' 2 "$replay_count"
  cp "$CMUX_FIXTURES/event.json" "$TEST_ROOT/saved-event.json"
  printf '{}\n' >"$CMUX_FIXTURES/event.json"
  invoke doctor --record "$TEST_ROOT/no-event"
  assert_eq 'missing event fails recording' 1 "$STATUS"
  assert_absent "$TEST_ROOT/no-event" cmux-0.65.1
  mv "$TEST_ROOT/saved-event.json" "$CMUX_FIXTURES/event.json"
  mv "$TEST_ROOT/saved-windows.json" "$CMUX_FIXTURES/windows.json"
  rm "$CMUX_FIXTURES/rows_by_window.json"
  end_scenario
}

scenario_vm() {
  begin_scenario 'VM checks detect absent hooks, old tmux, invalid folders, and protocol drift' || return 0
  mkdir -p "$HOME/.local/share/cmux-tui/bin"
  cp "$HOME/.local/bin/cmux-hook" "$HOME/.local/share/cmux-tui/bin/cmux-tui-hook"
  fake_cmux_init "$TEST_ROOT/cmux-state"
  ln -s "$REPO/test/fakes/cmux" "$TEST_ROOT/bin/cmux-tui"
  cat >"$TEST_ROOT/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf 'tmux %s\n' "${TMUX_VERSION:-3.2a}"
TMUX
  chmod +x "$TEST_ROOT/bin/cmux-tui" "$TEST_ROOT/bin/tmux"
  export CMUX_SSH_ATTEMPT_ID=doctor-test WT_HOST=test-vm WT_REPOS_DIR="$TEST_ROOT/repos"
  invoke doctor
  assert_eq 'VM checks pass' 0 "$STATUS"
  TUI_BAD_JSON=1 invoke doctor
  assert_eq 'non-JSON cmux-tui status fails the contract check' 1 "$STATUS"
  assert_grep 'malformed status names the hook check' "$TEST_ROOT/output" 'FAIL cmux-tui claude hook'
  TUI_CODEX_STATUS=absent TMUX_VERSION=3.1 invoke doctor
  assert_eq 'absent hook and old tmux fail' 1 "$STATUS"
  assert_grep 'absent hook repair' "$TEST_ROOT/output" 'Fix: cmux-tui agent hook install claude codex'
  assert_grep 'old tmux repair' "$TEST_ROOT/output" 'Fix: sudo apt-get update'
  WT_HOST='' WT_REPOS_DIR="$TEST_ROOT/missing" invoke doctor
  assert_eq 'missing environment fails' 1 "$STATUS"
  assert_grep 'host failure' "$TEST_ROOT/output" 'FAIL WT_HOST'
  assert_grep 'folder failure' "$TEST_ROOT/output" 'FAIL WT_REPOS_DIR'
  CMUX_TUI_HOOK="$TEST_ROOT/missing-helper" invoke doctor
  assert_eq 'missing helper fails' 1 "$STATUS"
  WT_CMUX_TUI_HOOK="$HOME/.local/bin/cmux-hook" CMUX_TUI_HOOK="$TEST_ROOT/missing-helper" invoke doctor
  assert_eq 'a saved helper cannot hide a missing selected helper' 1 "$STATUS"
  WT_CMUX_TUI_HOOK="$TEST_ROOT/missing-helper" CMUX_TUI_HOOK="$HOME/.local/bin/cmux-hook" invoke doctor
  assert_eq 'a valid selected helper replaces a stale saved helper' 0 "$STATUS"
  WT_CMUX_TUI_HOOK="$HOME/.local/bin/cmux-hook" CMUX_TUI_HOOK="$REPO/lib/workgrove/cmux-tui-hook.sh" invoke doctor
  assert_eq 'the wrapper preserves a valid saved helper' 0 "$STATUS"
  WT_CMUX_TUI_HOOK="$TEST_ROOT/missing-helper" CMUX_TUI_HOOK="$REPO/lib/workgrove/cmux-tui-hook.sh" invoke doctor
  assert_eq 'the wrapper checks the saved helper' 1 "$STATUS"
  invoke doctor --record "$TEST_ROOT/vm-record"
  assert_eq 'a VM rejects recording' 1 "$STATUS"
  assert_absent "$TEST_ROOT" vm-record
  # Run the remote path through the same login-shell fake as the other suites.
  make_fake_ssh "$TEST_ROOT/bin/ssh"
  unset CMUX_SSH_ATTEMPT_ID
  # The fake VM sets its own OS through uname, as a real VM does.
  printf '#!/bin/sh\necho Linux\n' >"$TEST_ROOT/bin/uname"
  invoke -H test-vm doctor
  assert_eq 'remote doctor passes' 0 "$STATUS"
  TUI_CODEX_STATUS=absent invoke -H test-vm doctor
  assert_eq 'remote absent hook fails' 1 "$STATUS"
  # Change only the Mac protocol; the VM keeps the installed protocol.
  mkdir -p "$TEST_ROOT/mac/bin" "$TEST_ROOT/mac/lib"
  cp "$REPO/bin/wt" "$TEST_ROOT/mac/bin/"
  cp -R "$REPO/lib/workgrove" "$TEST_ROOT/mac/lib/"
  sed 's/^WT_PROTOCOL=1$/WT_PROTOCOL=2/' "$REPO/lib/workgrove/common.sh" >"$TEST_ROOT/mac/lib/workgrove/common.sh"
  STATUS=0
  bash "$TEST_ROOT/mac/bin/wt" -H test-vm doctor >"$TEST_ROOT/output" 2>&1 || STATUS=$?
  assert_eq 'a VM behind the Mac fails' 1 "$STATUS"
  assert_grep 'protocol mismatch is named' "$TEST_ROOT/output" 'VM protocol 1; Mac protocol 2'
  assert_grep 'protocol mismatch repair' "$TEST_ROOT/output" 'Fix: wt -H test-vm update'
  rm "$HOME/.local/bin/wt"
  cat >"$HOME/.local/bin/wt" <<'WT'
#!/usr/bin/env bash
if [[ $1 == version ]]; then printf '{"commit":"fixture","protocol":3}\n'
else exec bash "$DOCTOR_TEST_REPO/bin/wt" "$@"; fi
WT
  chmod +x "$HOME/.local/bin/wt"
  DOCTOR_TEST_REPO=$REPO invoke -H test-vm doctor
  assert_eq 'a VM ahead of the Mac fails' 1 "$STATUS"
  assert_grep 'a newer VM names the Mac repair' "$TEST_ROOT/output" 'Fix: wt update'
  cat >"$HOME/.local/bin/wt" <<'WT'
#!/usr/bin/env bash
if [[ $1 == version ]]; then printf '{"commit":"fixture","protocol":1}\n'
else printf 'workgrove: ready\n'; fi
WT
  invoke -H test-vm doctor
  assert_eq 'an older portable doctor cannot certify cmux contracts' 1 "$STATUS"
  assert_grep 'a portable-only VM needs its contract checker updated' "$TEST_ROOT/output" 'FAIL VM doctor unavailable'
  cat >"$HOME/.local/bin/wt" <<'WT'
#!/usr/bin/env bash
if [[ $1 == version ]]; then printf '{"commit":"fixture","protocol":1}\n'
else printf 'wt: unknown command doctor\n' >&2; exit 1; fi
WT
  invoke -H test-vm doctor
  assert_eq 'an older VM without doctor fails' 1 "$STATUS"
  assert_grep 'the missing VM command is named' "$TEST_ROOT/output" 'FAIL VM doctor unavailable'
  assert_grep 'the missing VM command names its repair' "$TEST_ROOT/output" 'Fix: wt -H test-vm update'
  rm "$HOME/.local/bin/wt"
  invoke -H test-vm doctor
  assert_eq 'a missing remote wt fails doctor' 1 "$STATUS"
  assert_grep 'the missing executable names doctor with the root' "$TEST_ROOT/output" 'wt -H test-vm doctor --root <root> --json'
  assert_grep 'the Mac hint starts with root discovery' "$TEST_ROOT/output" 'Run: wt -H test-vm doctor --json; then wt -H test-vm doctor --root <root> --json'
  assert_grep 'the missing executable names restore-only' "$TEST_ROOT/output" 'wt -H test-vm setup --root <root> --restore-only'
  assert_eq 'the recovery hint appears once' 1 "$(grep -c 'A host whose home folder was replaced looks new.' "$TEST_ROOT/output")"
  if grep -Fq 'wt -H test-vm update' "$TEST_ROOT/output"; then
    fail 'a missing remote wt recommends update'
  else pass; fi
  ln -s "$REPO/bin/wt" "$HOME/.local/bin/wt"
  cat >"$TEST_ROOT/version-disconnect" <<'SSH'
case $cmd in *' version') exit 255 ;; esac
SSH
  make_fake_ssh "$TEST_ROOT/bin/ssh" "$TEST_ROOT/version-disconnect"
  invoke -H test-vm doctor
  assert_eq 'a disconnect during the version query fails' 1 "$STATUS"
  assert_grep 'the version connection failure is named' "$TEST_ROOT/output" 'FAIL VM version connection from the Mac'
  assert_grep 'the version connection names the connection repair' "$TEST_ROOT/output" 'Fix: ssh test-vm'
  printf '#!/bin/sh\nexit 255\n' >"$TEST_ROOT/bin/ssh"
  invoke -H test-vm doctor
  assert_eq 'an SSH connection failure fails doctor' 1 "$STATUS"
  assert_grep 'the transport failure is named' "$TEST_ROOT/output" 'FAIL VM doctor connection from the Mac'
  assert_grep 'the transport failure names the connection repair' "$TEST_ROOT/output" 'Fix: ssh test-vm'
  if grep -Eq 'VM protocol|Fix: wt -H .* update' "$TEST_ROOT/output"; then
    fail 'a connection failure suggests an update or a protocol comparison'
  else pass; fi
  end_scenario
}

scenario_readiness_dispatch
scenario_mac
scenario_shapes_and_hooks
scenario_record
scenario_recorded_contract
scenario_reference_redaction
scenario_vm
lib_summary
