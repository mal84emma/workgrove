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
[[ ${SSH_FAIL:-0} == 0 ]] || exit "$SSH_FAIL"
HOME="$TEST_ROOT/vm" fake_ssh_run "$cmd"
exit $?
SSH
make_fake_ssh "$TEST_ROOT/bin/ssh" "$TEST_ROOT/bin/ssh.fixture"
run_wt() {
  HOME="$TEST_ROOT/mac" PATH="$TEST_ROOT/bin:$PATH" \
    bash "$REPO/bin/wt" "$@"
}
records() { sed -n '/^{/p' | jq -sc 'map(select(.event == "wt_update"))'; }

scenario_version() {
  begin_scenario 'local, remote, linked and seeded version reports' || return 0
  local json expected rc=0
  expected=$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)
  json=$(run_wt -H fixture version)
  assert_eq 'remote version describes VM installation' true "$(jq -r --arg commit "$expected" '.commit == $commit and .protocol == 1' <<<"$json")"
  json=$(bash "$TEST_ROOT/vm/.local/bin/wt" version)
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/tmux"
  chmod +x "$TEST_ROOT/bin/tmux"
  assert_eq 'creation preflight reports the installed version' "$json" \
    "$(HOME="$TEST_ROOT/vm" PATH="$TEST_ROOT/bin:$PATH" sh "$REPO/lib/workgrove/vm/host-new-preflight.sh" '' none)"
  assert_eq 'linked script describes its own repository'  "$expected" "$(jq -r .commit <<<"$json")"
  cp -R "$TEST_ROOT/source" "$TEST_ROOT/seed"
  rm -rf "$TEST_ROOT/seed/.git"
  json=$(bash "$TEST_ROOT/seed/bin/wt" version)
  assert_eq 'seed never borrows a parent repository commit' '{"commit":"unknown","protocol":1}' "$json"
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
  assert_eq 'existing up-to-date line remains' true "$([[ $output == *'Already up to date.'* ]] && echo true || echo false)"
  assert_eq 'scratch installer runs' true "$([[ $output == *'installer stub'* ]] && echo true || echo false)"
  output=$(run_wt -H fixture update)
  json=$(records <<<"$output")
  assert_eq 'remote update compares both sides at both stages' true "$(jq -r '[.[] | select(.side != "local") | [.stage,.side]] == [["before","Mac"],["before","VM"],["after","Mac"],["after","VM"]]' <<<"$json")"
  assert_eq 'remote records carry VM commit and protocol' true "$(jq -r --arg commit "$expected" 'all(.[] | select(.side == "VM"); .commit == $commit and .protocol == 1)' <<<"$json")"
  end_scenario
}
scenario_update

scenario_older_vm() {
  begin_scenario 'old VM becomes versioned and failed updates retain their status' || return 0
  local output json rc=0
  rm "$TEST_ROOT/vm/.local/bin/wt"
  cat >"$TEST_ROOT/vm/.local/bin/wt" <<'VM'
#!/bin/sh
case "$1" in
  version) echo 'unknown command' >&2; exit 1 ;;
  update)
    [ "${UPDATE_FAIL:-0}" = 0 ] || exit "$UPDATE_FAIL"
    printf 'old update output\n'
    cat >"$HOME/.local/bin/wt" <<'NEW'
#!/bin/sh
printf '{"commit":"abcdef0","protocol":1}\n'
NEW
    ;;
esac
VM
  chmod +x "$TEST_ROOT/vm/.local/bin/wt"
  output=$(UPDATE_FAIL=23 run_wt -H fixture update) || rc=$?
  assert_eq 'remote update failure status survives reporting' 23 "$rc"
  assert_eq 'failed update has no after records' true "$(records <<<"$output" | jq -r 'all(.[]; .stage == "before")')"
  output=$(run_wt -H fixture update)
  json=$(records <<<"$output")
  assert_eq 'old VM before values are null' true "$(jq -r '.[] | select(.side == "VM" and .stage == "before") | .commit == null and .protocol == null' <<<"$json")"
  assert_eq 'after report queries the updated VM' true "$(jq -r '.[] | select(.side == "VM" and .stage == "after") | .commit == "abcdef0" and .protocol == 1' <<<"$json")"
  assert_eq 'old update output survives' true "$([[ $output == *'old update output'* ]] && echo true || echo false)"
  rc=0
  SSH_FAIL=255 run_wt -H fixture update >"$TEST_ROOT/disconnected" 2>&1 || rc=$?
  assert_eq 'transport failure retains existing update exit status' 1 "$rc"
  assert_eq 'transport failure names SSH recovery' true "$([[ $(cat "$TEST_ROOT/disconnected") == *'host unreachable'* ]] && echo true || echo false)"
  end_scenario
}
scenario_older_vm

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

scenario_pull() {
  begin_scenario 'confirmed scratch pull reports the changed commit' || return 0
  local before after output json
  before=$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)
  after=$(git -C "$TEST_ROOT/source" rev-parse --short HEAD)
  # A scratch terminal supplies confirmation without touching the real installation.
  output=$(python3 - "$TEST_ROOT/clone/bin/wt" <<'PYTHON'
import os
import pty
import subprocess
import sys
master, slave = pty.openpty()
try:
    os.write(master, b"y\n")
    result = subprocess.run(["bash", sys.argv[1], "update"], stdin=slave,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    sys.stdout.buffer.write(result.stdout)
    sys.exit(result.returncode)
finally:
    os.close(slave)
    os.close(master)
PYTHON
  )
  json=$(records <<<"$output")
  assert_eq 'pull reports the old commit before and new commit after' true \
    "$(jq -r --arg before "$before" --arg after "$after" 'map(.commit) == [$before,$after] and $before != $after' <<<"$json")"
  assert_eq 'confirmed pull advances only the scratch clone' "$after" "$(git -C "$TEST_ROOT/clone" rev-parse --short HEAD)"
  end_scenario
}
scenario_pull
lib_summary
