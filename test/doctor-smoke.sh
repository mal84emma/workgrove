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
DOCTOR_REAL_HOME=$HOME
trap 'HOME=$DOCTOR_REAL_HOME lib_cleanup' EXIT
mkdir -p "$TEST_ROOT/home/.claude" "$TEST_ROOT/home/.codex" "$TEST_ROOT/home/.local/bin" \
  "$TEST_ROOT/bin" "$TEST_ROOT/fixtures" "$TEST_ROOT/repos"
export HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH" CMUX_FIXTURES="$TEST_ROOT/fixtures"
export CMUX_BUNDLED_CLI_PATH="$REPO/test/fake-cmux.sh"
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
printf 'cmux 0.65.1 (110)\n' >"$CMUX_FIXTURES/version.txt"
printf '[{"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","title":"private-window"}]\n' >"$CMUX_FIXTURES/windows.json"
cat >"$CMUX_FIXTURES/rows.json" <<'JSON'
{"workspaces":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","title":"private-title","description":"@secretvm · secret-repo","current_directory":"/Users/secretuser/repos/private","remote":{"enabled":true,"destination":"secretvm","state":"connected","backend":"cmux-tui","persistent_daemon_slot":null}}]}
JSON
printf '{"caller":{"workspace_id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"},"coding_agents":[{"resources":{"process_count":1}}]}\n' >"$CMUX_FIXTURES/top.json"
printf '[{"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","workspace_id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","title":"private-title","body":"/home/secretuser secretvm","secretuser":"secretvm"}]\n' >"$CMUX_FIXTURES/notifications.json"
cp "$REPO/home/.cmuxterm/automations.json" "$TEST_ROOT/rules.json"
jq '.rules[0]' "$TEST_ROOT/rules.json" >"$CMUX_FIXTURES/automation.json"
printf '{"name":"notification.created","workspace_id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","payload":{"notification_id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","body":"private-title secretvm"}}\n' >"$CMUX_FIXTURES/event.json"
printf '%s\n' '{"methods":["workspace.list","workspace.create","workspace.action","workspace.close","workspace.select","workspace.remote.reconnect","notification.list","notification.dismiss","system.top","surface.read_text"]}' >"$CMUX_FIXTURES/capabilities.json"

invoke() {
  STATUS=0
  bash "$REPO/bin/wt" "$@" >"$TEST_ROOT/output" 2>&1 || STATUS=$?
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
  local command
  cp "$HOME/.claude/settings.json" "$TEST_ROOT/settings.json"
  # shellcheck disable=SC2016  # The probe reads these shell expressions without executing them.
  for command in 'env SOURCE=Claude ~/.local/bin/cmux-hook' \
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
  for command in 'true && /missing/hook' 'printf data | /missing/hook' \
      $'true\n/missing/hook' 'bash -c "true && /missing/hook"'; do
    jq --arg command "$command" '.hooks.Stop[0].hooks[0].command=$command' \
      "$TEST_ROOT/settings.json" >"$HOME/.claude/settings.json"
    invoke doctor
    assert_eq "a missing later hook fails: $command" 1 "$STATUS"
    assert_grep 'a missing later helper is reported' "$TEST_ROOT/output" 'FAIL hook command'
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
  for file in rows windows top notifications automation capabilities event rows_by_window; do
    assert_regular "$dir" "$file.json"
    if jq -e . "$dir/$file.json" >/dev/null; then pass; else fail "$file is invalid JSON"; fi
  done
  if rg 'secretvm|secretuser|private-title|private-window|/Users/|/home/|secret-repo' "$dir"; then
    fail 'recorded fixtures contain private text'
  else pass; fi
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
  cat >"$TEST_ROOT/bin/cmux-tui" <<'TUI'
#!/usr/bin/env bash
printf 'claude: installed\ncodex: %s\n' "${TUI_CODEX_STATUS:-installed}"
TUI
  cat >"$TEST_ROOT/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf 'tmux %s\n' "${TMUX_VERSION:-3.2a}"
TMUX
  chmod +x "$TEST_ROOT/bin/cmux-tui" "$TEST_ROOT/bin/tmux"
  export CMUX_SSH_ATTEMPT_ID=doctor-test WT_HOST=test-vm WT_REPOS_DIR="$TEST_ROOT/repos"
  invoke doctor
  assert_eq 'VM checks pass' 0 "$STATUS"
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
else printf 'wt: unknown command doctor\n' >&2; exit 1; fi
WT
  invoke -H test-vm doctor
  assert_eq 'an older VM without doctor fails' 1 "$STATUS"
  assert_grep 'the missing VM command is named' "$TEST_ROOT/output" 'FAIL VM doctor unavailable'
  assert_grep 'the missing VM command names its repair' "$TEST_ROOT/output" 'Fix: wt -H test-vm update'
  end_scenario
}

scenario_mac
scenario_shapes_and_hooks
scenario_record
scenario_vm
lib_summary
