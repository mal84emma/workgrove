#!/usr/bin/env bash
# Exercise version reporting and updates with scratch installations and fake SSH.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-update.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
[[ $TEST_ROOT == "$(cd "${TMPDIR:-/tmp}" && pwd -P)"/wt-update.* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT
export TEST_ROOT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/mac/.local/bin" "$TEST_ROOT/vm/.local/bin" "$TEST_ROOT/source"
cp -R "$REPO/bin" "$REPO/lib" "$TEST_ROOT/source/"
printf '#!/bin/sh\nprintf "installer stub\\n"\n' >"$TEST_ROOT/source/install.sh"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
# All Git remotes in this suite are scratch directories.
git init -q "$TEST_ROOT/source"
git -C "$TEST_ROOT/source" add .
git -C "$TEST_ROOT/source" commit -qm 'Create test installation'
git clone -q "$TEST_ROOT/source" "$TEST_ROOT/clone"
ln -s "$TEST_ROOT/clone/bin/wt" "$TEST_ROOT/vm/.local/bin/wt"
cat >"$TEST_ROOT/bin/ssh.fixture" <<'SSH'
printf '%s\n' "$cmd" >>"$TEST_ROOT/ssh.log"
printf '%s\n' "$*" >>"$TEST_ROOT/ssh-args.log"
if [[ ${SSH_FAIL_AFTER_UPDATE:-0} != 0 && $cmd == *' version' && -e $TEST_ROOT/updated ]]; then
  case $SSH_FAIL_AFTER_UPDATE in
    disconnect) exit 255 ;;
    malformed) printf '{broken\n'; exit 0 ;;
    command) exit 1 ;;
  esac
fi
[[ ${SSH_FAIL:-0} == 0 ]] || exit "$SSH_FAIL"
HOME="$TEST_ROOT/vm" fake_ssh_run "$cmd"
rc=$?
if [[ ${SSH_FAIL_AFTER_UPDATE:-0} != 0 && $rc == 0 && $cmd == *' update'* ]]; then : >"$TEST_ROOT/updated"; fi
exit "$rc"
SSH
make_fake_ssh "$TEST_ROOT/bin/ssh" "$TEST_ROOT/bin/ssh.fixture"
run_wt() {
  HOME="$TEST_ROOT/mac" PATH="$TEST_ROOT/bin:$PATH" \
    bash "$REPO/bin/wt" "$@"
}
records() { sed -n '/^{/p' | jq -sc 'map(select(.event == "wt_update"))'; }

scenario_version() {
  begin_scenario 'local, remote, linked and seeded version reports' || return 0
  local json expected value rc=0
  expected=$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)
  json=$(run_wt -H fixture version)
  assert_eq 'remote version describes VM installation' true "$(jq -r --arg commit "$expected" '.commit == $commit and .protocol == 1' <<<"$json")"
  assert_eq 'VM reports the compatibility capabilities' true \
    "$(jq -r '.capabilities | sort == (["result-records","show-facts","path-field","model-option","agent-probe","doctor-records","teardown-receipts"] | sort)' <<<"$json")"
  json=$(bash "$TEST_ROOT/vm/.local/bin/wt" version)
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/tmux"
  chmod +x "$TEST_ROOT/bin/tmux"
  assert_eq 'creation preflight supplies the installed version for the Mac comparison' "$json" \
    "$(cat "$REPO/lib/workgrove/version.sh" "$REPO/lib/workgrove/vm/host-new-preflight.sh" |
       HOME="$TEST_ROOT/vm" PATH="$TEST_ROOT/bin:$PATH" sh -s -- '' none)"
  assert_eq 'linked script describes its own repository'  "$expected" "$(jq -r .commit <<<"$json")"
  git init -q "$TEST_ROOT/ambient"
  git -C "$TEST_ROOT/ambient" commit --allow-empty -qm 'Create unrelated repository'
  local variable
  for variable in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR; do
    case $variable in GIT_WORK_TREE) value="$TEST_ROOT/ambient" ;; *) value="$TEST_ROOT/ambient/.git" ;; esac
    json=$(env "$variable=$value" bash "$TEST_ROOT/vm/.local/bin/wt" version)
    assert_eq "linked version ignores inherited $variable" "$expected" "$(jq -r .commit <<<"$json")"
  done
  cp -R "$TEST_ROOT/source" "$TEST_ROOT/ambient/seed"
  rm -rf "$TEST_ROOT/ambient/seed/.git"
  json=$(bash "$TEST_ROOT/ambient/seed/bin/wt" version)
  assert_eq 'seed never borrows a parent repository commit' true \
    "$(jq -r '.commit == "unknown" and .protocol == 1' <<<"$json")"
  run_wt version unexpected >/dev/null 2>&1 || rc=$?
  assert_eq 'local version rejects arguments' 1 "$rc"
  rc=0
  run_wt -H fixture version --json >/dev/null 2>&1 || rc=$?
  assert_eq 'remote version validates options locally' 1 "$rc"
  assert_eq 'remote help succeeds' 0 "$(run_wt -H fixture version --help >/dev/null; echo $?)"
  end_scenario
}
scenario_version

scenario_update() {
  begin_scenario 'local and remote update records preserve existing output' || return 0
  local output json expected
  expected=$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)
  output=$(bash "$TEST_ROOT/clone/bin/wt" update)
  json=$(records <<<"$output")
  assert_eq 'local update reports both stages' true "$(jq -r --arg commit "$expected" 'map(.stage) == ["before","after"] and all(.[]; .side == "local" and .commit == $commit and .protocol == 1)' <<<"$json")"
  assert_eq 'update records retain their existing keys' true \
    "$(jq -r 'all(.[]; keys == ["commit","event","protocol","side","stage"])' <<<"$json")"
  assert_eq 'existing up-to-date line remains' true "$([[ $output == *'Already up to date.'* ]] && echo true || echo false)"
  assert_eq 'scratch installer runs' true "$([[ $output == *'installer stub'* ]] && echo true || echo false)"
  local flag
  for flag in --with-zshrc --opinionated-config; do
    output=$(HOME="$TEST_ROOT/mac" bash "$TEST_ROOT/clone/bin/wt" update "$flag")
    assert_eq "classic update still accepts $flag" true "$([[ $output == *'installer stub'* ]] && echo true || echo false)"
  done
  mkdir -p "$TEST_ROOT/vm/.local/chain"
  ln -s "$TEST_ROOT/clone/bin/wt" "$TEST_ROOT/vm/.local/chain/wt"
  ln -s ../chain/wt "$TEST_ROOT/vm/.local/bin/nested-wt"
  output=$(HOME="$TEST_ROOT/vm" PATH="$TEST_ROOT/bin:$PATH" bash "$TEST_ROOT/vm/.local/bin/nested-wt" update)
  assert_eq 'nested command links update their owning checkout' true \
    "$([[ $output == *'Already up to date.'* && $output == *'installer stub'* ]] && echo true || echo false)"
  output=$(run_wt -H fixture update)
  json=$(records <<<"$output")
  assert_eq 'remote update compares both sides at both stages' true "$(jq -r '[.[] | select(.side != "local") | [.stage,.side]] == [["before","Mac"],["before","VM"],["after","Mac"],["after","VM"]]' <<<"$json")"
  assert_eq 'remote records carry VM commit and protocol' true "$(jq -r --arg commit "$expected" 'all(.[] | select(.side == "VM"); .commit == $commit and .protocol == 1)' <<<"$json")"
  local mode rc
  for mode in disconnect malformed command; do
    rm -f "$TEST_ROOT/updated"
    rc=0
    output=$(SSH_FAIL_AFTER_UPDATE=$mode run_wt -H fixture update 2>"$TEST_ROOT/after-error") || rc=$?
    assert_eq "$mode final reporting failure preserves successful update status" 0 "$rc"
    assert_eq "$mode final reporting failure emits unavailable VM values" true \
      "$(records <<<"$output" | jq -r '.[] | select(.stage == "after" and .side == "VM") | .commit == null and .protocol == null')"
    assert_eq "$mode final reporting failure explains the successful update" true \
      "$([[ $(cat "$TEST_ROOT/after-error") == *'succeeded; could not read its version'* ]] && echo true || echo false)"
  done
  end_scenario
}
scenario_update

scenario_failed_vm_update() {
  begin_scenario 'failed updates retain their status without version fallbacks' || return 0
  local rc=0
  rm "$TEST_ROOT/vm/.local/bin/wt"
  cat >"$TEST_ROOT/vm/.local/bin/wt" <<'VM'
#!/bin/sh
case "$1" in
  version) printf '{"commit":"fixture","protocol":1,"capabilities":[]}\n' ;;
  update) exit 23 ;;
esac
VM
  chmod +x "$TEST_ROOT/vm/.local/bin/wt"
  run_wt -H fixture update >"$TEST_ROOT/failed-update" 2>&1 || rc=$?
  assert_eq 'remote update failure status survives reporting' 23 "$rc"
  rc=0
  SSH_FAIL=255 run_wt -H fixture update >"$TEST_ROOT/disconnected" 2>&1 || rc=$?
  assert_eq 'transport failure retains existing update exit status' 1 "$rc"
  assert_eq 'transport failure names SSH recovery' true "$([[ $(cat "$TEST_ROOT/disconnected") == *'host unreachable'* ]] && echo true || echo false)"
  end_scenario
}
scenario_failed_vm_update

scenario_initial_version_refusal() {
  begin_scenario 'invalid initial versions cannot run an update' || return 0
  local mode rc
  cat >"$TEST_ROOT/vm/.local/bin/wt" <<'VM'
#!/bin/sh
case "$1" in
  version)
    case "$INITIAL_VERSION_MODE" in
      unsupported) exit 42 ;;
      missing) printf '{"commit":"fixture","protocol":1}\n' ;;
      malformed) printf '{broken\n' ;;
    esac ;;
  update) : >"$TEST_ROOT/invalid-version-update" ;;
esac
VM
  for mode in unsupported missing malformed; do
    rc=0
    INITIAL_VERSION_MODE=$mode run_wt -H fixture update >"$TEST_ROOT/initial-error" 2>&1 || rc=$?
    local expected=1
    [[ $mode != unsupported ]] || expected=42
    assert_eq "$mode initial version fails" "$expected" "$rc"
    assert_absent "$TEST_ROOT" invalid-version-update
    assert_eq "$mode failure emits no update records" '[]' "$(records <"$TEST_ROOT/initial-error")"
  done
  end_scenario
}
scenario_initial_version_refusal

scenario_refusal() {
  begin_scenario 'incoming commits still require an interactive confirmation' || return 0
  local output rc=0
  printf 'incoming\n' >"$TEST_ROOT/source/change"
  git -C "$TEST_ROOT/source" add change
  git -C "$TEST_ROOT/source" commit -qm 'Add incoming test change'
  output=$(bash "$TEST_ROOT/clone/bin/wt" update </dev/null 2>&1) || rc=$?
  assert_eq 'unattended pull remains refused' 1 "$rc"
  assert_eq 'refusal retains its message' true "$([[ $output == *'refusing to apply these commits unattended'* ]] && echo true || echo false)"
  assert_eq 'refused update has only its before record' '["before"]' "$(records <<<"$output" | jq -c 'map(.stage)')"
  end_scenario
}
scenario_refusal

# A scratch terminal supplies confirmation to the command under test.
terminal_update() {
  python3 - "$@" <<'PYTHON'
import os
import pty
import subprocess
import sys
master, slave = pty.openpty()
try:
    os.write(master, (sys.argv[1] + "\n").encode())
    result = subprocess.run(["bash", *sys.argv[2:]], stdin=slave,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    sys.stdout.buffer.write(result.stdout)
    sys.exit(result.returncode)
finally:
    os.close(slave)
    os.close(master)
PYTHON
}

scenario_pull() {
  begin_scenario 'confirmed scratch pull reports the changed commit' || return 0
  local before after output json
  before=$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)
  after=$(git -C "$TEST_ROOT/source" rev-parse --short HEAD)
  # A scratch terminal supplies confirmation without touching the real installation.
  output=$(terminal_update y "$TEST_ROOT/clone/bin/wt" update)
  json=$(records <<<"$output")
  assert_eq 'pull reports the old commit before and new commit after' true \
    "$(jq -r --arg before "$before" --arg after "$after" 'map(.commit) == [$before,$after] and $before != $after' <<<"$json")"
  assert_eq 'confirmed pull advances only the scratch clone' "$after" "$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)"
  end_scenario
}
scenario_pull

scenario_remote_pull() {
  begin_scenario 'public remote update forwards confirmation and reports the changed VM commit' || return 0
  local before after mac output json rc=0
  rm "$TEST_ROOT/vm/.local/bin/wt"
  ln -s "$TEST_ROOT/clone/bin/wt" "$TEST_ROOT/vm/.local/bin/wt"
  before=$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)
  mac=$(git -C "$REPO" rev-parse --short HEAD)
  printf 'remote incoming\n' >"$TEST_ROOT/source/remote-change"
  git -C "$TEST_ROOT/source" add remote-change
  git -C "$TEST_ROOT/source" commit -qm 'Add remote test change'
  after=$(git -C "$TEST_ROOT/source" rev-parse --short HEAD)

  output=$(run_wt -H fixture update </dev/null 2>&1) || rc=$?
  assert_eq 'remote unattended pull remains refused' 1 "$rc"
  assert_eq 'remote refusal retains its message' true \
    "$([[ $output == *'refusing to apply these commits unattended'* ]] && echo true || echo false)"
  assert_eq 'unattended remote update has no after records' true \
    "$(records <<<"$output" | jq -r 'length == 3 and all(.[]; .stage == "before")')"

  rc=0
  output=$(HOME="$TEST_ROOT/mac" PATH="$TEST_ROOT/bin:$PATH" \
    terminal_update n "$REPO/bin/wt" -H fixture update) || rc=$?
  assert_eq 'remote cancellation preserves its failure status' 1 "$rc"
  assert_eq 'remote cancellation retains its message' true "$([[ $output == *'update: cancelled'* ]] && echo true || echo false)"
  assert_eq 'remote cancellation keeps the VM commit' "$before" "$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)"
  assert_eq 'remote cancellation has no after records' true \
    "$(records <<<"$output" | jq -r 'length == 3 and all(.[]; .stage == "before")')"

  : >"$TEST_ROOT/ssh-args.log"
  output=$(HOME="$TEST_ROOT/mac" PATH="$TEST_ROOT/bin:$PATH" \
    terminal_update y "$REPO/bin/wt" -H fixture update)
  json=$(records <<<"$output")
  assert_eq 'SSH receives terminal forwarding for update' true \
    "$(awk '/-t fixture .* update/ {found=1} END {print found ? "true" : "false"}' "$TEST_ROOT/ssh-args.log")"
  assert_eq 'remote pull advances the VM commit' "$after" "$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)"
  assert_eq 'remote pull reports both stages for both sides' true \
    "$(jq -r '[.[] | select(.side != "local") | [.stage,.side]] == [["before","Mac"],["before","VM"],["after","Mac"],["after","VM"]]' <<<"$json")"
  assert_eq 'remote VM records identify the commit change' true \
    "$(jq -r --arg before "$before" --arg after "$after" '[.[] | select(.side == "VM") | .commit] == [$before,$after] and $before != $after' <<<"$json")"
  assert_eq 'remote Mac records retain the correct commit and protocol' true \
    "$(jq -r --arg mac "$mac" '[.[] | select(.side == "Mac")] | length == 2 and all(.[]; .commit == $mac and .protocol == 1)' <<<"$json")"
  assert_eq 'remote VM records retain the correct protocol' true \
    "$(jq -r 'all(.[] | select(.side == "VM"); .protocol == 1)' <<<"$json")"
  end_scenario
}
scenario_remote_pull
lib_summary
