#!/usr/bin/env bash
# Test the shared shell functions with scratch SSH configuration, fixed cmux responses, and a stub tmux.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lib-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=lib/workgrove/common.sh
source "$REPO/lib/workgrove/common.sh"
trap lib_cleanup EXIT
# shellcheck source=test/fakes/rows.sh
source "$REPO/test/fakes/rows.sh"

scenario_fake_ssh() {
  begin_scenario 'shared fake SSH shell selection and command execution' || return 0
  local fixture="$TEST_ROOT/fake-ssh" tool selected out rc
  mkdir -p "$fixture/bin"
  # A controlled PATH makes shell selection independent of the installed shells.
  for tool in cat chmod; do
    ln -s "$(command -v "$tool")" "$fixture/bin/$tool"
  done
  ln -s "$BASH" "$fixture/bin/bash"
  cat >"$fixture/bin/sh" <<'SHELL'
#!/bin/sh
export FAKE_LOGIN_SHELL=${0##*/}
exec /bin/sh "$@"
SHELL
  cp "$fixture/bin/sh" "$fixture/bin/zsh"
  chmod +x "$fixture/bin/sh" "$fixture/bin/zsh"
  printf 'input survives SSH\n' >"$fixture/input"
  for selected in zsh sh; do
    if [[ $selected == sh ]]; then rm "$fixture/bin/zsh"; fi
    PATH="$fixture/bin" make_fake_ssh "$fixture/ssh"
    rc=0
    # shellcheck disable=SC2016  # The selected shell expands its name in the remote command.
    out=$(PATH="$fixture/bin" "$fixture/ssh" -T -o BatchMode=yes -o ConnectTimeout=5 \
      test.invalid 'printf "%s\n" "$FAKE_LOGIN_SHELL"; cat; exit 23' <"$fixture/input" 2>&1) || rc=$?
    assert_eq "$selected receives the command and stdin" "$selected"$'\ninput survives SSH' "$out"
    assert_eq "$selected preserves the remote exit status" 23 "$rc"
    rc=0
    out=$(PATH="$fixture/bin" "$fixture/ssh" test.invalid printf "'%s'" "'two words'" 2>&1) || rc=$?
    assert_eq "$selected joins split SSH command arguments" 'two words' "$out"
    assert_eq "$selected returns success from a split command" 0 "$rc"
  done
  end_scenario
}
scenario_fake_ssh

scenario_draining_readers() {
  begin_scenario 'bounded readers drain large pipeline input' || return 0
  local rows output rc=0 fixture="$TEST_ROOT/early-picker" status
  rows=$(printf 'workspace:%s\n' {1..20000})
  output=$(printf '%s\n' "$rows" | cmux_ref) || rc=$?
  assert_eq 'cmux reference lookup preserves the first match' workspace:1 "$output"
  assert_eq 'cmux reference lookup drains its producer' 0 "$rc"
  mkdir -p "$fixture"
  cat >"$fixture/fzf" <<'FZF'
#!/bin/sh
printf 'query\nselection\n'
exit "$PICKER_STATUS"
FZF
  chmod +x "$fixture/fzf"
  # shellcheck source=lib/workgrove/picker.sh
  source "$REPO/lib/workgrove/picker.sh"
  for status in 0 130; do
    rc=0
    output=$(printf '%s\n' "$rows" | PATH="$fixture:$PATH" PICKER_STATUS="$status" pick repo) || rc=$?
    if [[ $status == 0 ]]; then
      assert_eq 'early picker selection drains its producer' 0 "$rc"
      assert_eq 'early picker selection keeps its output' selection "$output"
    else
      assert_eq 'early picker cancellation keeps its status' 1 "$rc"
      assert_eq 'early picker cancellation emits no selection' '' "$output"
    fi
  done
  end_scenario
}
scenario_draining_readers

close_row_result() (
  local reply=$1 close_status=$2 rc=0
  fake_cmux_init "$TEST_ROOT/close-state"
  export CMUX_BUNDLED_CLI_PATH="$REPO/test/fakes/cmux"
  fake_queue workspace-close "$reply" "$close_status"
  CMUX_ERROR=''
  close_row row-test || rc=$?
  printf '%s\n%s' "$rc" "$CMUX_ERROR"
)

scenario_close_row() {
  begin_scenario 'closing a row tolerates only an already-closed row' || return 0
  assert_eq 'a successful close is silent' 0 "$(close_row_result '' 0)"
  assert_eq 'a row closed during the request is already gone' 0 \
    "$(close_row_result 'Error: not_found: Workspace not found' 1)"
  assert_eq 'other close failures retain the error and recovery command' \
    $'1\ncould not close cmux row row-test: Permission denied\non the Mac: cmux workspace close row-test' \
    "$(close_row_result 'Permission denied' 1)"
  end_scenario
}
scenario_close_row

scenario_cmux_require() {
  begin_scenario 'wrapped cmux failures always explain the cause' || return 0
  local mode rc out expected
  local CMUX_ROWS_FULL=1 CMUX_ROWS_JSON='{"workspaces":null}'
  for mode in empty explicit warning; do
    rc=0
    out=$(
      # shellcheck disable=SC2329  # cmux_require invokes this function.
      wrapped_failure() {
        case $mode in
          empty) return 1 ;;
          explicit) cmux_error 'specific cause' ;;
          warning) CMUX_ERROR='nonfatal cause'; return 0 ;;
        esac
      }
      CMUX_ERROR='stale cause'
      cmux_require wrapped_failure >"$TEST_ROOT/wrapped.out" 2>"$TEST_ROOT/wrapped.err"
    ) || rc=$?
    expected=1
    [[ $mode != warning ]] || expected=0
    assert_eq "$mode keeps the wrapper exit status" "$expected" "$rc"
    assert_eq "$mode emits no stdout" '' "$out$(cat "$TEST_ROOT/wrapped.out")"
    case $mode in
      empty) expected='wt: wrapped_failure failed' ;;
      explicit) expected='wt: specific cause' ;;
      warning) expected='wt: nonfatal cause' ;;
    esac
    assert_eq "$mode explains the cause on stderr" "$expected" "$(cat "$TEST_ROOT/wrapped.err")"
    if grep -xF 'wt: ' "$TEST_ROOT/wrapped.err" >/dev/null; then fail 'the wrapper printed an empty diagnostic'; else pass; fi
  done
  for mode in host rows; do
    rc=0
    out=$(
      # shellcheck disable=SC2329  # cmux_row_create_ssh invokes this function.
      ssh_host_check() { [[ $mode != host ]]; }
      cmux_require cmux_row_create_ssh test-vm task '@test-vm · repo' true 2>"$TEST_ROOT/create.err"
    ) || rc=$?
    assert_eq "$mode prevents SSH row creation" 1 "$rc"
    assert_eq "$mode emits no stdout" '' "$out"
    if [[ $mode == host ]]; then expected='wt: SSH host validation failed for test-vm'
    else expected='wt: cannot read existing cmux row IDs'; fi
    assert_grep "$mode reports the creation failure" "$TEST_ROOT/create.err" "$expected"
  done
  end_scenario
}
scenario_cmux_require

scenario_results() {
  begin_scenario 'versioned wt results' || return 0
  record=$(WG_MACHINE_RESULT=1 wt_result new created task '/repos/two words' wt-two-words-task)
  assert_eq 'result round trip' 'created|task|/repos/two words|wt-two-words-task' \
    "$(wt_read_result "$record" new | jq -r '[.status,.name,.repo,.session] | join("|" )')"
  rc=0
  diagnostic=$(wt_read_result "${record/\"version\":1/\"version\":2}" new 2>&1) || rc=$?
  assert_eq 'unsupported protocol has its own status' 3 "$rc"
  assert_eq 'hook callers receive an update hint without hook changes' true \
    "$([[ $diagnostic == *'wt update'* ]] && echo true || echo false)"
  assert_eq 'reader 2 retains the protocol 1 decoder' "${record#*$'\t'}" \
    "$(WT_PROTOCOL=2 wt_read_result "$record" new)"
  assert_eq 'ordinary commands do not emit records' '' "$(WG_MACHINE_RESULT='' wt_result new created task /repos/project)"
  assert_eq 'newer reader requests still receive protocol 1' "$record" \
    "$(WG_MACHINE_RESULT=2 wt_result new created task '/repos/two words' wt-two-words-task)"
  assert_eq 'unknown scalar keys are retained' 'true' \
    "$(wt_read_result "${record%\}} ,\"extra\":true}" new | jq -r .extra)"
  for request in 0 -1 invalid 1.5; do
    assert_eq "invalid request $request stays silent" '' "$(WG_MACHINE_RESULT=$request wt_result new created task /repo)"
  done
  for sample in text empty malformed duplicate blank-duplicate version command control missing duplicate-status duplicate-name duplicate-repo duplicate-version escaped-key nested multiple-objects nul-value nul-key extra-control; do
    rc=0
    case $sample in
      text) output='created task'; expected=2 ;;
      empty) output=$'WT_RESULT\t'; expected=1 ;;
      malformed) output=$'WT_RESULT\t{broken'; expected=1 ;;
      duplicate) output="$record"$'\n'"$record"; expected=1 ;;
      blank-duplicate) output=$'WT_RESULT\t\n'"$record"; expected=1 ;;
      version) output=${record/\"version\":1/\"version\":2}; expected=3 ;;
      command) output=${record/\"new\"/\"show\"}; expected=1 ;;
      control) output=${record/task/task\\n}; expected=1 ;;
      missing) output=$'WT_RESULT\t{"version":1,"command":"new"}'; expected=1 ;;
      duplicate-status) output=${record/\"status\":/\"status\":\"found\",\"status\":}; expected=1 ;;
      duplicate-name) output=${record/\"name\":/\"name\":\"other\",\"name\":}; expected=1 ;;
      duplicate-repo) output=${record/\"repo\":/\"repo\":\"\/other\",\"repo\":}; expected=1 ;;
      duplicate-version) output=${record/\"version\":/\"version\":2,\"version\":}; expected=1 ;;
      escaped-key) output=${record/\"status\":/\"st\\u0061tus\":\"found\",\"status\":}; expected=1 ;;
      nested) output=${record/\"status\":/\"extra\":\{\"value\":1\},\"status\":}; expected=1 ;;
      nul-value) output=${record%\}}',"extra":"ok\u0000status\u0000missing"}'; expected=1 ;;
      nul-key) output=${record%\}}',"extra\u0000status":"missing"}'; expected=1 ;;
      extra-control) output=${record%\}}',"extra":"line\nnext"}'; expected=1 ;;
      multiple-objects) output=$'WT_RESULT\t{"version":1} {"command":"new","status":"created","name":"task","repo":"/repo","session":"session","state":""}'; expected=1 ;;
    esac
    wt_read_result "$output" new >/dev/null 2>&1 || rc=$?
    assert_eq "$sample result status" "$expected" "$rc"
  done
  end_scenario
}
scenario_results

scenario_doctor_results() {
  begin_scenario 'doctor results validate checks without display text' || return 0
  local record output parsed rc sample
  record=$(WG_MACHINE_RESULT=1 wt_result doctor PASS '' '' '' '' \
    '{"checks":[{"name":"check","status":"PASS","repair":"wt update"}]}')
  local -A fields=()
  rc=0
  wt_read_result_into "$record" doctor fields || rc=$?
  assert_eq 'doctor record is valid' 0 "$rc"
  assert_eq 'doctor checks decode as JSON' 'check|PASS|wt update' \
    "$(jq -r '.[] | [.name,.status,.repair] | join("|")' <<<"${fields[checks]:-[]}")"
  for sample in warn fail empty missing nested unknown control duplicate duplicate-array duplicate-empty status inconsistent newer; do
    rc=0
    case $sample in
      warn) output=${record/\"PASS\"/\"FAIL\"}; output=${output/\"status\":\"PASS\"/\"status\":\"WARN\"} ;;
      fail) output=${record//\"PASS\"/\"FAIL\"} ;;
      empty) output=$(jq -c '.checks=[]' <<<"${record#*$'\t'}") ;;
      missing) output=$(jq -c 'del(.checks[0].repair)' <<<"${record#*$'\t'}") ;;
      nested) output=$(jq -c '.checks[0].name={value:"check"}' <<<"${record#*$'\t'}") ;;
      unknown) output=$(jq -c '.checks[0].extra="value"' <<<"${record#*$'\t'}") ;;
      control) output=$(jq -c '.checks[0].repair="line\nnext"' <<<"${record#*$'\t'}") ;;
      duplicate) output=${record/\"name\":\"check\"/\"name\":\"other\",\"name\":\"check\"} ;;
      duplicate-array) output=${record/\"checks\":/\"checks\":[{\"name\":\"other\"\}],\"checks\":} ;;
      duplicate-empty) output=${record/\"checks\":/\"checks\":[],\"checks\":} ;;
      status) output=$(jq -c '.checks[0].status="OK"' <<<"${record#*$'\t'}") ;;
      inconsistent) output=$(jq -c '.status="FAIL"' <<<"${record#*$'\t'}") ;;
      newer) output=${record/\"version\":1/\"version\":2} ;;
    esac
    [[ $output == WT_RESULT$'\t'* ]] || output=WT_RESULT$'\t'$output
    parsed=$(wt_read_result "$output" doctor 2>/dev/null) || rc=$?
    case $sample in
      warn|fail) assert_eq "$sample is valid" 0 "$rc"
        assert_eq "$sample overall result fails" FAIL "$(jq -r .status <<<"$parsed")" ;;
      newer) assert_eq 'newer doctor protocol requires an update' 3 "$rc" ;;
      *) assert_eq "$sample doctor record is invalid" 1 "$rc" ;;
    esac
  done
  end_scenario
}
scenario_doctor_results

scenario_vm_results() {
  begin_scenario 'VM results preserve command status and reject invalid identities' || return 0
  local sample output expected
  for sample in facts text malformed version wrong-name wrong-session missing wrong-repo path-old path-facts transport field-injection; do
    case $sample in
      facts) expected='0|0|visible|task|wt-repo-task|false|true|' ;;
      text) expected='0|0|created task
  repo: /repo
  session: wt-repo-task|task|wt-repo-task|||' ;;
      malformed|wrong-name|wrong-session|wrong-repo|field-injection) expected=1 ;;
      version) expected=3 ;;
      missing) expected='0|1||task||||' ;;
      path-old|path-facts) expected='0|0|/repo/.worktrees/task|task||||/repo/.worktrees/task' ;;
      transport) expected='2|255|connection lost|task||||' ;;
    esac
    output=$(
      vm_wt() {
        case $sample in
          text) printf 'created task\n  repo: /repo\n  session: wt-repo-task\n'; return ;;
          malformed) printf 'WT_RESULT\t{broken\n'; return ;;
          transport) printf 'connection lost\n'; return 255 ;;
        esac
        local command=show sample_name=task repo=/repo session=wt-repo-task sample_status=found facts='{"agent":false,"attached":false,"started":true}'
        case $sample in
          version) printf 'WT_RESULT\t{"version":2,"command":"show"}\n'; return ;;
          wrong-name) sample_name=other ;;
          wrong-session) session=main ;;
          missing|wrong-repo) command=path; sample_status=missing; session=''; facts='{}' ;;
          path-old|path-facts) command=path; session=''; facts='{}' ;;
          field-injection) command=path; session=''; facts='{"extra":"ok\u0000status\u0000missing"}' ;;
        esac
        [[ $sample != wrong-repo ]] || repo=/other
        case $sample in
          path-old|path-facts) printf '/repo/.worktrees/task\n' ;;
          missing|wrong-repo) ;;
          *) printf 'visible\n' ;;
        esac
        [[ $sample != path-facts ]] || facts='{"path":"/repo/.worktrees/task"}'
        WG_MACHINE_RESULT=1 wt_result "$command" "$sample_status" "$sample_name" "$repo" "$session" 'changed wording' "$facts"
        [[ $sample_status != missing && $sample != field-injection ]] || return 1
        return 0
      }
      local -A record=()
      local visible errors rc parsed=0 sub=show
      case $sample in text) sub=new ;; missing|wrong-repo|path-*|field-injection) sub=path ;; esac
      vm_result fixture "$sub" record visible errors rc -- task -r /repo || parsed=$?
      local expected_errors=''
      if [[ $rc != 0 && $rc != 255 ]]; then expected_errors="wt $sub on fixture exited $rc"; fi
      [[ $errors == "$expected_errors" ]] || printf 'unexpected diagnostic: %s' "$errors"
      case $sample in
        malformed|version|wrong-name|wrong-session|wrong-repo|field-injection) printf '%s' "$parsed" ;;
        *) printf '%s|%s|%s|%s|%s|%s|%s|%s' "$parsed" "$rc" "$visible" \
          "${record[name]-}" "${record[session]-}" "${record[agent]-}" "${record[started]-}" "${record[path]-}" ;;
      esac
    )
    assert_eq "$sample VM result" "$expected" "$output"
  done
  for sample in agent attached started path; do
    output=$(WG_MACHINE_RESULT=1 wt_result show found task /repo wt-repo-task '' "{\"$sample\":7}")
    local rc=0
    wt_read_result "$output" show >/dev/null || rc=$?
    assert_eq "$sample rejects an invalid type" 1 "$rc"
  done
  end_scenario
}
scenario_vm_results

scenario_vm_streams() {
  begin_scenario 'VM result decoding keeps diagnostics out of legacy paths' || return 0
  local mode output
  for mode in text legacy facts; do
    output=$(
      vm_wt() {
        printf 'SSH warning\n' >&2
        if [[ $mode != facts ]]; then printf '/repo/.worktrees/task\n'; fi
        if [[ $mode != text ]]; then
          local facts='{}'
          [[ $mode != facts ]] || facts='{"path":"/repo/.worktrees/task"}'
          WG_MACHINE_RESULT=1 wt_result path found task /repo '' '' "$facts"
        fi
      }
      local -A fields=()
      local stdout stderr rc parsed=0
      vm_result fixture path fields stdout stderr rc -- task -r /repo || parsed=$?
      printf '%s|%s|%s|%s|%s' "$parsed" "$rc" "${fields[path]-}" "$stderr" "$stdout"
    )
    local visible_path=/repo/.worktrees/task
    [[ $mode != facts ]] || visible_path=''
    assert_eq "$mode keeps the path and diagnostic separate" "0|0|/repo/.worktrees/task|SSH warning|$visible_path" "$output"
  done
  end_scenario
}
scenario_vm_streams

scenario_vm_failure_policy() {
  begin_scenario 'VM failure policies preserve messages and exit statuses' || return 0
  local policy command_rc parsed status rc output expected
  while IFS='|' read -r policy command_rc parsed status rc expected; do
    local actual_rc=0
    output=$({
      # shellcheck disable=SC2329  # The close policy invokes this function.
      log() { printf '%s\n' "$*"; }
      vm_wt_failure fixture "$policy" "$command_rc" 'wt -H fixture list -r /repo' "$parsed" "$status" task /repo
    } 2>&1) || actual_rc=$?
    assert_eq "$policy/$command_rc/$parsed/$status preserves status" "$rc" "$actual_rc"
    assert_eq "$policy/$command_rc/$parsed/$status preserves message" "$expected" "$output"
  done <<'CASES'
raw|0|0||0|
raw|42|0||42|
raw|255|0||1|wt: host unreachable: is the VM running? (ssh fixture)
version|255|0||1|wt: host unreachable: is the VM running? (ssh fixture)
version|127|0||0|
new|0|0|created|0|
new|0|2||1|wt: fixture did not report created/repo/session; the worktree may exist; inspect with: wt -H fixture list -r /repo before retrying
new|0|3||1|wt: unsupported result protocol from fixture; run wt update on the Mac; the worktree may exist; inspect with: wt -H fixture list -r /repo before retrying
new|0|0|found|1|wt: unexpected output from fixture; the worktree may exist; inspect with: wt -H fixture list -r /repo before retrying
path|0|0|found|0|
path|0|2||1|wt: unexpected output from fixture
path|0|3||1|wt: unsupported result protocol from fixture; run wt update on the Mac
path|42|3||42|
show|0|2||1|wt: fixture reported no session for task (try: wt -H fixture show task -r /repo)
show|0|1||1|wt: unexpected output from fixture
close|1|0|missing|0|
close|0|0|missing|1|ignored wt-close for task task of /repo on fixture: could not confirm its worktree is gone
close|255|2||1|ignored wt-close for task task of /repo on fixture: could not confirm its worktree is gone
close|1|3||1|ignored wt-close for task task of /repo on fixture: unsupported result protocol; run wt update on the Mac
protocol|0|3||3|wt: unsupported result protocol; run wt update on the Mac
CASES
  output=$({
    vm_wt_failure fixture version 255 '' 0 || true
    printf 'caller continued'
  } 2>&1)
  assert_eq 'version failure returns without exiting its caller' true "$([[ $output == *'caller continued' ]] && echo true || echo false)"
  end_scenario
}
scenario_vm_failure_policy

scenario_vm_definitions() {
  begin_scenario 'VM failure messages have one definition' || return 0
  local message
  for message in 'host unreachable' 'unsupported result protocol'; do
    assert_eq "$message has one definition" 1 "$(grep -rn "$message" "$REPO/bin" "$REPO/lib" | wc -l | tr -d ' ')"
  done
  end_scenario
}
scenario_vm_definitions

scenario_vm_options() {
  begin_scenario 'VM calls and probes share connection options without disabling terminals' || return 0
  local fixture="$TEST_ROOT/shared-options" option output
  mkdir -p "$fixture/bin"
  cat >"$fixture/bin/ssh" <<'SSH'
#!/bin/sh
printf '%s\n' "$@" >"$SSH_OPTIONS_LOG"
cat >/dev/null
SSH
  chmod +x "$fixture/bin/ssh"
  # shellcheck disable=SC2016  # The child shell owns these variables.
  PATH="$fixture/bin:$PATH" SSH_OPTIONS_LOG="$fixture/call" "$BASH" -c '
    source "$1/lib/workgrove/common.sh"
    source "$1/lib/workgrove/hosts.sh"
    WG_LIB_DIR="$1/lib/workgrove"
    ssh_host_check() { :; }
    vm_ssh fixture true -t </dev/null
    SSH_OPTIONS_LOG="$2/probe" probe_host fixture
  ' bash "$REPO" "$fixture"
  for option in BatchMode=yes NumberOfPasswordPrompts=0 ConnectTimeout=5 ConnectionAttempts=1 ServerAliveInterval=5 ServerAliveCountMax=2; do
    assert_grep "VM call uses $option" "$fixture/call" "$option"
    assert_grep "probe uses $option" "$fixture/probe" "$option"
  done
  for output in call probe; do
    assert_eq "$output retains the alias host-key policy" 0 "$(grep -c StrictHostKeyChecking "$fixture/$output" || true)"
  done
  assert_grep 'the caller can request a terminal' "$fixture/call" '-t'
  assert_eq 'VM calls do not disable terminals' 0 "$(grep -cx -- -T "$fixture/call" || true)"
  assert_grep 'probes disable terminals' "$fixture/probe" '-T'
  for option in yes accept-new; do
    printf 'Host fixture\n  StrictHostKeyChecking %s\n' "$option" >"$fixture/config"
    output=$(ssh -G -F "$fixture/config" "${VM_SSH_OPTIONS[@]}" fixture 2>/dev/null)
    local expected=$option
    [[ $option != yes ]] || expected=true
    assert_eq "SSH retains the configured $option policy" 1 "$(grep -cx "stricthostkeychecking $expected" <<<"$output" | tr -d ' ')"
  done
  end_scenario
}
scenario_vm_options

scenario_vm_ssh() {
  begin_scenario 'VM commands share SSH options and preserve argument quoting' || return 0
  local output
  output=$(
    ssh_host_check() { return 0; }
    # shellcheck disable=SC2329  # VM_SSH_RUN invokes this function.
    vm_capture() { printf '%s\n' "$@"; return 42; }
    VM_SSH_RUN=(vm_capture)
    rc=0
    vm_wt fixture --machine show task -r '/repos/two words' || rc=$?
    printf 'status=%s' "$rc"
  )
  assert_eq 'VM commands use keepalives' true "$([[ $output == *$'ServerAliveInterval=5\n'* ]] && echo true || echo false)"
  assert_eq 'VM commands preserve SSH failures' true "$([[ $output == *status=42 ]] && echo true || echo false)"
  # shellcheck disable=SC2016  # HOME belongs to the VM shell.
  assert_eq 'machine requests stay inline' true "$([[ $output == *'WT_MACHINE=1 exec "$HOME/.local/bin/wt" show task -r /repos/two\ words'* ]] && echo true || echo false)"
  # shellcheck disable=SC2016
  assert_eq 'run commands quote the repository' '"$HOME/.local/bin/wt" run task -r /repos/two\ words' "$(vm_run_line task '/repos/two words')"
  end_scenario
}
scenario_vm_ssh

scenario_protocol_hint() {
  begin_scenario 'unsupported results name wt update in creation and recovery' || return 0
  local command output rc
  for command in new attach; do
    rc=0
    output=$(
      # shellcheck source=lib/workgrove/remote.sh
      source "$REPO/lib/workgrove/remote.sh"
      # shellcheck source=lib/workgrove/recovery.sh
      source "$REPO/lib/workgrove/recovery.sh"
      host_new_preflight() { :; }
      vm_wt() { printf 'WT_RESULT\t{"version":2,"command":"%s"}\n' "$3"; }
      if [[ $command == new ]]; then host_new fixture task -r /repo --no-workspace 2>&1
      else host_attach fixture task -r /repo 2>&1; fi
    ) || rc=$?
    assert_eq "$command rejects unsupported protocol" 1 "$rc"
    assert_eq "$command names wt update" true "$([[ $output == *'wt update'* ]] && echo true || echo false)"
  done
  end_scenario
}
scenario_protocol_hint

scenario_version_validation() {
  begin_scenario 'version reports require one object and share null fallback behavior' || return 0
  local sample reply parsed rc home="$TEST_ROOT/version-home"
  mkdir -p "$home/.local/bin"
  cat >"$home/.local/bin/wt" <<'WT'
#!/bin/sh
printf '%s\n' "$VERSION_REPLY"
WT
  chmod +x "$home/.local/bin/wt"
  for sample in multiple garbage array missing-commit missing-protocol commit-type protocol-type fractional zero empty; do
    case $sample in
      multiple) reply=$'{"commit":"abc","protocol":1}\n{"commit":"def","protocol":1}' ;;
      garbage) reply='{"commit":"abc","protocol":1}garbage' ;;
      array) reply='[{"commit":"abc","protocol":1}]' ;;
      missing-commit) reply='{"protocol":1}' ;;
      missing-protocol) reply='{"commit":"abc"}' ;;
      commit-type) reply='{"commit":7,"protocol":1}' ;;
      protocol-type) reply='{"commit":"abc","protocol":"1"}' ;;
      fractional) reply='{"commit":"abc","protocol":1.5}' ;;
      zero) reply='{"commit":"abc","protocol":0}' ;;
      empty) reply='' ;;
    esac
    rc=0
    parsed=$(wt_read_version <<<"$reply" 2>/dev/null) || rc=$?
    assert_eq "$sample version is rejected" true "$([[ $rc -ne 0 ]] && echo true || echo false)"
    assert_eq "$sample probe version becomes null" '{"commit":null,"protocol":null}' \
      "$(HOME="$home" VERSION_REPLY="$reply" wt_vm_version)"
    parsed=$(
      # shellcheck source=lib/workgrove/remote.sh
      source "$REPO/lib/workgrove/remote.sh"
      vm_wt() { printf '%s\n' "$reply"; }
      host_version fixture
    )
    assert_eq "$sample update version becomes null" '{"commit":null,"protocol":null}' "$parsed"
  done
  assert_eq 'valid extra fields are normalized' '{"commit":"abc","protocol":1}' \
    "$(wt_read_version <<<'{"extra":true,"protocol":1,"commit":"abc"}')"
  end_scenario
}
scenario_version_validation

assert_result() { # <what> <expected: yes|no> <function> <argument>
  local what=$1 expected=$2 actual=no
  shift 2
  if "$@"; then actual=yes; fi
  assert_eq "$what" "$expected" "$actual"
}

scenario_aliases() {
  begin_scenario 'SSH alias syntax' || return 0
  assert_result 'letter first' yes valid_host alpha
  assert_result 'digit first and punctuation later' yes valid_host '9a._-'
  assert_result 'capital letter' yes valid_host Alpha
  assert_result 'hyphen first' no valid_host -alpha
  assert_result 'dot first' no valid_host .alpha
  assert_result 'slash' no valid_host alpha/beta
  assert_result 'space' no valid_host 'alpha beta'
  assert_result 'empty alias' no valid_host ''
  end_scenario
}
scenario_aliases

scenario_paths() {
  begin_scenario 'paths accepted by the Mac hook' || return 0
  assert_result 'absolute path' yes hook_safe_path '/tmp/task name/.hidden'
  assert_result 'single component' yes hook_safe_path '/task'
  assert_result 'root path' no hook_safe_path /
  assert_result 'relative path' no hook_safe_path 'tmp/task'
  assert_result 'trailing slash' no hook_safe_path '/tmp/task/'
  assert_result 'newline' no hook_safe_path $'/tmp/a\nb'
  assert_result 'single quote' no hook_safe_path "/tmp/a'b"
  assert_result 'double quote' no hook_safe_path '/tmp/a"b'
  assert_result 'backtick' no hook_safe_path '/tmp/a`b'
  assert_result 'dollar sign' no hook_safe_path "/tmp/a\$b"
  assert_result 'backslash' no hook_safe_path '/tmp/a\b'
  assert_result 'semicolon' no hook_safe_path '/tmp/a;b'
  assert_result 'double slash' no hook_safe_path '/tmp//task'
  assert_result 'parent component' no hook_safe_path '/tmp/../task'
  assert_result 'final parent component' no hook_safe_path '/tmp/..'
  end_scenario
}
scenario_paths

name63=$(printf 'a%.0s' {1..63})
name64=${name63}a
# The output functions format invalid names too. valid_name makes the refusal decision.
check_identity() { # <name> <repo id> <valid: yes|no>
  local name=$1 id=$2 valid=$3
  assert_eq "repo id for $name" "$id" "$(repo_id "/repos/$name")"
  assert_eq "row title for $name" "$name" "$(row_title "$name")"
  assert_eq "session for $name" "wt-$id-$name" "$(wt_session "$name" "/repos/$name")"
  assert_result "valid name for $name" "$valid" valid_name "$name"
}

scenario_identities() {
  begin_scenario 'task and repository identities' || return 0
  check_identity task task yes
  check_identity 'two words' two-words no
  check_identity 'has.dot' has-dot no
  check_identity Upper Upper no
  check_identity "$name63" "$name63" yes
  check_identity "$name64" "$name64" no
  assert_eq 'repo id uses only the last path component' final "$(repo_id '/repos/other/final')"
  assert_result 'underscore after the first character' yes valid_name task_2
  assert_result 'underscore first' no valid_name _task
  assert_result 'empty task name' no valid_name ''
  end_scenario
}
scenario_identities

scenario_fake_replay() {
  begin_scenario 'the shared fake replays plain and scoped top responses' || return 0
  local fake="$REPO/test/fakes/cmux" id=00000000-0000-4000-8000-000000000001
  local rc scope
  for scope in plain scoped; do
    local args=(top --json)
    [[ $scope != scoped ]] || args=(top --workspace "$id" --json)
    rc=0
    env -u FAKE_CMUX_STATE -u CMUX_FIXTURES "$fake" "${args[@]}" >"$TEST_ROOT/replayed-top" 2>"$TEST_ROOT/replayed-error" || rc=$?
    assert_eq "$scope top replay succeeds" 0 "$rc"
    if cmp -s "$FAKE_CMUX_FIXTURES/top.json" "$TEST_ROOT/replayed-top"; then pass
    else fail "$scope top replay differs from the recorded response"; fi
  done
  local -x FAKE_CMUX_STATE="$TEST_ROOT/top-state"
  fake_cmux_init "$FAKE_CMUX_STATE"
  mkdir -p "$FAKE_CMUX_STATE/top"
  fake_top global-caller 0 >"$FAKE_CMUX_STATE/top.json"
  fake_top scoped-caller 1 >"$FAKE_CMUX_STATE/top/$id.json"
  assert_eq 'an unknown workspace uses the global top override' global-caller \
    "$("$fake" top --workspace other --json | jq -r .caller.workspace_id)"
  assert_eq 'a workspace keeps its scoped top override' scoped-caller \
    "$("$fake" top --workspace "$id" --json | jq -r .caller.workspace_id)"
  end_scenario
}
scenario_fake_replay

scenario_fake_mutations() {
  begin_scenario 'persistent fake rows stay consistent across window snapshots' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/mutation-state"
  local fake="$REPO/test/fakes/cmux" ref id
  local first=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA second=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
  fake_cmux_init "$FAKE_CMUX_STATE"
  : >"$FAKE_CMUX_STATE/mutate"
  fake_windows "$first" "$second" >"$FAKE_CMUX_STATE/windows.json"
  fake_rows >"$FAKE_CMUX_STATE/rows/$first.json"
  fake_rows >"$FAKE_CMUX_STATE/rows/$second.json"
  ref=$("$fake" ssh test-vm --name task --no-focus)
  assert_eq 'persistent creation returns a workspace ref' workspace:1 "$ref"
  id=$(jq -r '.workspaces[0].id' "$FAKE_CMUX_STATE/rows.json")
  assert_eq 'the global snapshot contains the new row' 1 "$(jq '.workspaces | length' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'the active window contains the new row' 1 "$(jq '.workspaces | length' "$FAKE_CMUX_STATE/rows/$first.json")"
  assert_eq 'the other window stays empty' 0 "$(jq '.workspaces | length' "$FAKE_CMUX_STATE/rows/$second.json")"
  cmux_rows_load checked "$fake"
  assert_eq 'checked enumeration finds the created row' "$id" "$(jq -r '.workspaces[0].id' <<<"$CMUX_ROWS_JSON")"
  "$fake" workspace-action --workspace "$ref" --action set-description --description '@test-vm · repo'
  assert_eq 'description changes update the global snapshot' '@test-vm · repo' \
    "$(jq -r '.workspaces[0].description' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'description changes update the window snapshot' '@test-vm · repo' \
    "$(jq -r '.workspaces[0].description' "$FAKE_CMUX_STATE/rows/$first.json")"
  "$fake" workspace close "$id" --force
  assert_eq 'closure removes the global row' 0 "$(jq '.workspaces | length' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'closure removes the window row' 0 "$(jq '.workspaces | length' "$FAKE_CMUX_STATE/rows/$first.json")"
  cmux_rows_load checked "$fake"
  assert_eq 'checked enumeration confirms closure' 0 "$(jq '.workspaces | length' <<<"$CMUX_ROWS_JSON")"
  end_scenario
}
scenario_fake_mutations

scenario_fake_seeded_rows() {
  begin_scenario 'persistent fake creation reserves seeded UUIDs and workspace refs' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/seeded-state"
  local fake="$REPO/test/fakes/cmux" ref id seed other
  local first=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA second=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
  fake_cmux_init "$FAKE_CMUX_STATE"
  : >"$FAKE_CMUX_STATE/mutate"
  fake_windows "$first" "$second" >"$FAKE_CMUX_STATE/windows.json"
  seed=$(fake_row 00000000-0000-4000-8000-000000000001 seed old test-vm connected cmux-tui null workspace:7)
  other=$(fake_row 00000000-0000-4000-8000-000000000002 other old test-vm connected cmux-tui null workspace:3)
  fake_rows "$seed" >"$FAKE_CMUX_STATE/rows.json"
  fake_rows "$seed" >"$FAKE_CMUX_STATE/rows/$first.json"
  fake_rows "$other" >"$FAKE_CMUX_STATE/rows/$second.json"
  ref=$("$fake" ssh test-vm --name new --no-focus)
  id=$(jq -r '.workspaces[] | select(.title == "new") | .id' "$FAKE_CMUX_STATE/rows.json")
  assert_eq 'creation skips reserved global and scoped identities' workspace:4 "$ref"
  assert_eq 'creation assigns an unused UUID' 00000000-0000-4000-8000-000000000004 "$id"
  assert_eq 'the global rows keep distinct UUIDs' 2 "$(jq '[.workspaces[].id] | unique | length' "$FAKE_CMUX_STATE/rows.json")"
  "$fake" workspace close "$id" --force
  assert_eq 'closing the new row preserves the global seed' seed "$(jq -r '.workspaces[].title' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'closing the new row preserves the active window seed' seed "$(jq -r '.workspaces[].title' "$FAKE_CMUX_STATE/rows/$first.json")"
  assert_eq 'the other window keeps its reserved ref' workspace:3 "$(jq -r '.workspaces[0].ref' "$FAKE_CMUX_STATE/rows/$second.json")"
  end_scenario
}
scenario_fake_seeded_rows

scenario_fake_command_validation() {
  begin_scenario 'the shared fake rejects unsupported recorded command forms' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/command-state"
  local fake="$REPO/test/fakes/cmux" command rc
  local args=()
  fake_cmux_init "$FAKE_CMUX_STATE"
  printf '{}\n' >"$FAKE_CMUX_STATE/agent-hook-status.json"
  for command in 'events --invalid-option' 'automation show wrong-rule' '--json agent completely-invalid' \
    'top --jsno' 'workspace list --jsno' '--json list-windows --nonsense' '--json list-notifications --nonsense'; do
    read -r -a args <<<"$command"
    rc=0
    "$fake" "${args[@]}" >"$TEST_ROOT/invalid-response" 2>"$TEST_ROOT/invalid-error" || rc=$?
    assert_eq "$command is rejected before serving a response" 64 "$rc"
  done
  assert_eq 'the supported agent hook command still serves its override' '{}' \
    "$("$fake" --json agent hook status claude codex)"
  end_scenario
}
scenario_fake_command_validation

scenario_fake_seed_refs() {
  begin_scenario 'seeded rows expose unique stable workspace references' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/seed-refs-state"
  local fake="$REPO/test/fakes/cmux" first second ref first_ref second_ref
  local window=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
  fake_cmux_init "$FAKE_CMUX_STATE"
  : >"$FAKE_CMUX_STATE/mutate"
  fake_windows "$window" >"$FAKE_CMUX_STATE/windows.json"
  first=$(fake_row seed-one first original test-vm)
  second=$(fake_row seed-two second original test-vm)
  first_ref=$(jq -r .ref <<<"$first"); second_ref=$(jq -r .ref <<<"$second")
  assert_eq 'seeded references use the cmux workspace form' true "$(jq -n --arg a "$first_ref" --arg b "$second_ref" '[$a,$b] | all(.[]; test("^workspace:[1-9][0-9]*$"))')"
  assert_eq 'different seeds advertise different references' true "$([[ $first_ref != "$second_ref" ]] && echo true || echo false)"
  fake_rows "$first" "$second" >"$FAKE_CMUX_STATE/rows.json"
  fake_window_rows "$window" "$first" "$second" >"$FAKE_CMUX_STATE/rows/$window.json"
  "$fake" workspace-action --workspace "$first_ref" --action set-description --description changed
  assert_eq 'targeting one ref changes only its global row' '["changed","original"]' "$(jq -c '[.workspaces[].description]' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'targeting one ref changes only its scoped row' '["changed","original"]' "$(jq -c '[.workspaces[].description]' "$FAKE_CMUX_STATE/rows/$window.json")"
  "$fake" workspace close "$first_ref" --force
  assert_eq 'closing one ref preserves the other global seed' seed-two "$(jq -r '.workspaces[].id' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'closing one ref preserves the other scoped seed' seed-two "$(jq -r '.workspaces[].id' "$FAKE_CMUX_STATE/rows/$window.json")"
  ref=$(fake_row explicit-seed explicit '' test-vm connected cmux-tui null workspace:99 | jq -r .ref)
  assert_eq 'a seed can specify an explicit unused reference' workspace:99 "$ref"
  assert_eq 'rebuilding a seed keeps its reference' "$second_ref" "$(fake_row seed-two second original test-vm | jq -r .ref)"
  end_scenario
}
scenario_fake_seed_refs

scenario_fake_legacy_refs() {
  begin_scenario 'legacy row IDs cannot alias another row reference' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/legacy-ref-state"
  local fake="$REPO/test/fakes/cmux" first second row collision rc
  local window=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
  fake_cmux_init "$FAKE_CMUX_STATE"
  touch "$FAKE_CMUX_STATE/mutate"
  fake_windows "$window" >"$FAKE_CMUX_STATE/windows.json"
  first=$(fake_row workspace:2 first original test-vm)
  second=$(fake_row workspace:1 second original test-vm)
  assert_eq 'a legacy ID defaults to its own reference' workspace:2 "$(jq -r .ref <<<"$first")"
  assert_eq 'reverse seed order preserves a distinct legacy alias' workspace:1 "$(jq -r .ref <<<"$second")"
  fake_rows "$first" "$second" >"$FAKE_CMUX_STATE/rows.json"
  fake_window_rows "$window" "$first" "$second" >"$FAKE_CMUX_STATE/rows/$window.json"
  "$fake" workspace-action --workspace workspace:1 --action set-description --description changed
  assert_eq 'a legacy alias updates only its global row' '["original","changed"]' "$(jq -c '[.workspaces[].description]' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'a legacy alias updates only its scoped row' '["original","changed"]' "$(jq -c '[.workspaces[].description]' "$FAKE_CMUX_STATE/rows/$window.json")"
  "$fake" workspace close workspace:1 --force
  assert_eq 'closing a legacy alias preserves the other global row' workspace:2 "$(jq -r '.workspaces[].id' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'closing a legacy alias preserves the other scoped row' workspace:2 "$(jq -r '.workspaces[].id' "$FAKE_CMUX_STATE/rows/$window.json")"

  FAKE_CMUX_STATE="$TEST_ROOT/legacy-ref-collision-state"
  fake_cmux_init "$FAKE_CMUX_STATE"
  fake_windows "$window" >"$FAKE_CMUX_STATE/windows.json"
  row=$(fake_row workspace:9 legacy original test-vm connected cmux-tui null workspace:1)
  assert_eq 'a legacy seed can keep an explicit distinct reference' workspace:1 "$(jq -r .ref <<<"$row")"
  fake_rows "$row" >"$FAKE_CMUX_STATE/rows.json"
  fake_window_rows "$window" "$row" >"$FAKE_CMUX_STATE/rows/$window.json"
  cat "$FAKE_CMUX_STATE/rows.json" "$FAKE_CMUX_STATE/rows/$window.json" "$FAKE_CMUX_STATE/references.json" >"$TEST_ROOT/alias-before"
  for collision in reference id; do
    rc=0
    case $collision in
      reference) fake_row other-row collision '' test-vm connected cmux-tui null workspace:9 >"$TEST_ROOT/alias-output" 2>&1 || rc=$? ;;
      id) fake_row workspace:1 collision '' test-vm >"$TEST_ROOT/alias-output" 2>&1 || rc=$? ;;
    esac
    assert_eq "a new $collision cannot alias another row" 64 "$rc"
    cat "$FAKE_CMUX_STATE/rows.json" "$FAKE_CMUX_STATE/rows/$window.json" "$FAKE_CMUX_STATE/references.json" >"$TEST_ROOT/alias-after"
    if cmp -s "$TEST_ROOT/alias-before" "$TEST_ROOT/alias-after"; then pass
    else fail "a rejected $collision collision changed state"; fi
  done
  assert_eq 'automatic allocation reserves legacy IDs as well as references' workspace:10 "$(fake_row automatic-row automatic '' test-vm | jq -r .ref)"
  assert_eq 'rebuilding a legacy seed preserves its existing binding' workspace:1 "$(fake_row workspace:9 legacy original test-vm | jq -r .ref)"
  end_scenario
}
scenario_fake_legacy_refs

scenario_fake_unsupported_action() {
  begin_scenario 'unsupported workspace actions preserve every snapshot' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/action-state"
  local fake="$REPO/test/fakes/cmux" row ref rc=0 window=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
  fake_cmux_init "$FAKE_CMUX_STATE"
  : >"$FAKE_CMUX_STATE/mutate"
  fake_windows "$window" >"$FAKE_CMUX_STATE/windows.json"
  row=$(fake_row action-row task original test-vm); ref=$(jq -r .ref <<<"$row")
  fake_rows "$row" >"$FAKE_CMUX_STATE/rows.json"
  fake_window_rows "$window" "$row" >"$FAKE_CMUX_STATE/rows/$window.json"
  cp "$FAKE_CMUX_STATE/rows.json" "$TEST_ROOT/action-global-before"
  cp "$FAKE_CMUX_STATE/rows/$window.json" "$TEST_ROOT/action-window-before"
  cp "$FAKE_CMUX_STATE/windows.json" "$TEST_ROOT/action-metadata-before"
  "$fake" workspace-action --workspace "$ref" --action set-title --title renamed >"$TEST_ROOT/action-output" 2>&1 || rc=$?
  assert_eq 'an unsupported action is rejected' 64 "$rc"
  local pair
  for pair in 'rows.json:action-global-before' "rows/$window.json:action-window-before" 'windows.json:action-metadata-before'; do
    if cmp -s "$FAKE_CMUX_STATE/${pair%%:*}" "$TEST_ROOT/${pair#*:}"; then pass
    else fail 'a rejected action changed a snapshot'; fi
  done
  end_scenario
}
scenario_fake_unsupported_action

scenario_fake_window_metadata() {
  begin_scenario 'persistent window metadata follows row membership' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/window-metadata-state"
  local fake="$REPO/test/fakes/cmux" first second first_id second_id
  local window=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA other=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
  fake_cmux_init "$FAKE_CMUX_STATE"
  : >"$FAKE_CMUX_STATE/mutate"
  fake_windows "$window" "$other" >"$FAKE_CMUX_STATE/windows.json"
  assert_eq 'empty windows have no selected workspace or members' true "$(jq 'all(.[]; .workspace_count == 0 and .selected_workspace_id == null)' "$FAKE_CMUX_STATE/windows.json")"
  assert_eq 'one window has focus' 1 "$(jq '[.[] | select(.key)] | length' "$FAKE_CMUX_STATE/windows.json")"
  first=$("$fake" ssh test-vm --name first --no-focus)
  first_id=$(jq -r '.workspaces[0].id' "$FAKE_CMUX_STATE/rows.json")
  assert_eq 'creation updates the active window metadata' true "$(jq --arg id "$first_id" '.[0].workspace_count == 1 and .[0].selected_workspace_id == $id' "$FAKE_CMUX_STATE/windows.json")"
  assert_eq 'creation preserves the empty other window' true "$(jq '.[1].workspace_count == 0 and .[1].selected_workspace_id == null' "$FAKE_CMUX_STATE/windows.json")"
  assert_eq 'scoped rows retain a window reference' window:1 "$(jq -r .window_ref "$FAKE_CMUX_STATE/rows/$window.json")"
  second=$("$fake" ssh test-vm --name second --no-focus)
  second_id=$(jq -r '.workspaces[1].id' "$FAKE_CMUX_STATE/rows.json")
  assert_eq 'an unfocused create preserves the selected row' true "$(jq --arg id "$first_id" '.[0].workspace_count == 2 and .[0].selected_workspace_id == $id' "$FAKE_CMUX_STATE/windows.json")"
  "$fake" workspace close "$first" --force
  assert_eq 'closing the selected row selects a remaining row' true "$(jq --arg id "$second_id" '.[0].workspace_count == 1 and .[0].selected_workspace_id == $id' "$FAKE_CMUX_STATE/windows.json")"
  "$fake" workspace close "$second" --force
  assert_eq 'closing the last row clears window metadata' true "$(jq '.[0].workspace_count == 0 and .[0].selected_workspace_id == null' "$FAKE_CMUX_STATE/windows.json")"
  end_scenario
}
scenario_fake_window_metadata

scenario_fake_recorded_ref() {
  begin_scenario 'rebuilding a recorded seed preserves its existing reference' || return 0
  local -x FAKE_CMUX_STATE="$TEST_ROOT/recorded-ref-state"
  local id ref rebuilt rc=0
  fake_cmux_init "$FAKE_CMUX_STATE"
  cp "$FAKE_CMUX_FIXTURES/rows.json" "$FAKE_CMUX_STATE/rows.json"
  id=$(jq -r '.workspaces[0].id' "$FAKE_CMUX_STATE/rows.json")
  ref=$(jq -r '.workspaces[0].ref' "$FAKE_CMUX_STATE/rows.json")
  fake_row "$id" conflicting '' test-vm connected cmux-tui null workspace:999 >"$TEST_ROOT/rebind-output" 2>&1 || rc=$?
  assert_eq 'a recorded reference cannot be rebound before registration' 64 "$rc"
  if [[ ! -e $FAKE_CMUX_STATE/references.json ]]; then pass
  else fail 'a rejected rebind created a registry'; fi
  rc=0
  rebuilt=$(fake_row "$id" rebuilt original test-vm)
  assert_eq 'a rebuilt recorded UUID keeps its advertised ref' "$ref" "$(jq -r .ref <<<"$rebuilt")"
  assert_eq 'the registry records the existing snapshot binding' "$ref" "$(jq -r --arg id "$id" '.[$id]' "$FAKE_CMUX_STATE/references.json")"
  fake_rows "$rebuilt" >"$FAKE_CMUX_STATE/rows/recorded.json"
  touch "$FAKE_CMUX_STATE/mutate"
  "$REPO/test/fakes/cmux" workspace-action --workspace "$ref" --action set-description --description updated
  assert_eq 'a recorded ref updates the global snapshot' updated "$(jq -r --arg id "$id" '.workspaces[] | select(.id == $id) | .description' "$FAKE_CMUX_STATE/rows.json")"
  assert_eq 'a recorded ref updates the rebuilt scoped snapshot' updated "$(jq -r '.workspaces[0].description' "$FAKE_CMUX_STATE/rows/recorded.json")"
  cp "$FAKE_CMUX_STATE/rows.json" "$TEST_ROOT/recorded-ref-before"
  cp "$FAKE_CMUX_STATE/references.json" "$TEST_ROOT/registry-before"
  fake_row "$id" conflicting '' test-vm connected cmux-tui null workspace:999 >"$TEST_ROOT/rebind-output" 2>&1 || rc=$?
  assert_eq 'an existing reference cannot be rebound' 64 "$rc"
  if cmp -s "$FAKE_CMUX_STATE/rows.json" "$TEST_ROOT/recorded-ref-before"; then pass
  else fail 'a rejected rebind changed the recorded snapshot'; fi
  if cmp -s "$FAKE_CMUX_STATE/references.json" "$TEST_ROOT/registry-before"; then pass
  else fail 'a rejected rebind changed the registry'; fi
  fake_rows "$rebuilt" | jq '.workspaces[0].ref="workspace:999"' >"$FAKE_CMUX_STATE/rows/conflicting.json"
  rc=0
  fake_row "$id" conflicting '' test-vm >"$TEST_ROOT/conflict-output" 2>&1 || rc=$?
  assert_eq 'conflicting snapshot bindings are rejected' 64 "$rc"
  end_scenario
}
scenario_fake_recorded_ref

fake_cmux_init "$TEST_ROOT/cmux-state"
ROW_WINDOW_ONE=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
ROW_WINDOW_TWO=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
ROW_WINDOW_THREE=CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC
ROW_ONE=$(fake_row row-one task '@local · repo')
ROW_TWO=$(fake_row row-two task '@test-vm · repo' test-vm)
ROW_EXPECTED="{\"workspaces\":[$ROW_ONE,$ROW_TWO]}"

row_cmux_reset() {
  ROW_WINDOWS=$(fake_windows "$ROW_WINDOW_ONE")
  ROW_WINDOWS_RC=0 ROW_ONE_RC=0 ROW_TWO_RC=0 ROW_FALLBACK_RC=0
  ROW_ONE_LIST="[$ROW_ONE]"
  ROW_TWO_LIST="{\"workspaces\":[$ROW_TWO]}"
  ROW_FALLBACK_LIST="[$ROW_ONE]"
  : >"$FAKE_CMUX_STATE/calls.log"
  : >"$TEST_ROOT/row-caps"
}
load_test_rows() {
  local key status
  printf '%s' "$ROW_WINDOWS" >"$FAKE_CMUX_STATE/windows.json"
  printf '%s' "$ROW_ONE_LIST" >"$FAKE_CMUX_STATE/rows/$ROW_WINDOW_ONE.json"
  printf '%s' "$ROW_TWO_LIST" >"$FAKE_CMUX_STATE/rows/$ROW_WINDOW_TWO.json"
  printf '[]' >"$FAKE_CMUX_STATE/rows/$ROW_WINDOW_THREE.json"
  printf '%s' "$ROW_FALLBACK_LIST" >"$FAKE_CMUX_STATE/rows.json"
  for key in list-windows workspace-list--$ROW_WINDOW_ONE workspace-list--$ROW_WINDOW_TWO workspace-list; do
    case $key in
      list-windows) status=$ROW_WINDOWS_RC ;;
      "workspace-list--$ROW_WINDOW_ONE") status=$ROW_ONE_RC ;;
      "workspace-list--$ROW_WINDOW_TWO") status=$ROW_TWO_RC ;;
      workspace-list) status=$ROW_FALLBACK_RC ;;
    esac
    rm -f "$FAKE_CMUX_STATE/fail/$key"
    if [[ $status != 0 ]]; then fake_failure "$key" "$status"; fi
  done
  local policy=$1
  shift
  cmux_rows_load "$policy" "$@" "$REPO/test/fakes/cmux"
}
row_capped() {
  printf '%s\n' "${*:2}" >>"$TEST_ROOT/row-caps"
  "$@"
}
check_rows_load() {
  local policy=$1 expected_rc=$2 expected_json=$3 expected_full=$4 rc=0
  load_test_rows "$policy" row_capped || rc=$?
  assert_eq "$policy returns the expected status" "$expected_rc" "$rc"
  assert_eq "$policy returns the expected rows" "$expected_json" "$CMUX_ROWS_JSON"
  assert_eq "$policy records list completeness" "$expected_full" "$CMUX_ROWS_FULL"
  assert_eq "$policy wraps every cmux call" "$(cat "$FAKE_CMUX_STATE/calls.log")" "$(cat "$TEST_ROOT/row-caps")"
}

scenario_row_windows() {
  begin_scenario 'cmux row lists across windows' || return 0
  for policy in skip stop checked; do
    row_cmux_reset
    check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 1
    ROW_ONE_LIST="{\"workspaces\":[$ROW_ONE]}"
    check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 1
    ROW_WINDOWS="${ROW_WINDOWS%]},{\"id\":\"$ROW_WINDOW_TWO\"}]"
    check_rows_load "$policy" 0 "$ROW_EXPECTED" 1
    assert_eq "$policy queries windows by UUID" \
      "$(printf -- '--json list-windows\nworkspace list --json --window %s\nworkspace list --json --window %s' "$ROW_WINDOW_ONE" "$ROW_WINDOW_TWO")" \
      "$(tail -3 "$FAKE_CMUX_STATE/calls.log")"
  done
  end_scenario
}
scenario_row_windows

scenario_row_failures() {
  begin_scenario 'cmux window failures and older versions' || return 0
  for policy in skip stop checked; do
    row_cmux_reset
    ROW_WINDOWS="${ROW_WINDOWS%]},{\"id\":\"$ROW_WINDOW_TWO\"},{\"id\":\"$ROW_WINDOW_THREE\"}]"
    ROW_TWO_RC=142
    if [[ $policy == skip ]]; then
      check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 0
      assert_grep 'display lookups continue after a failed window' "$FAKE_CMUX_STATE/calls.log" "$ROW_WINDOW_THREE"
    else
      check_rows_load "$policy" 142 '' 0
      assert_eq "$policy stops at the failing window" "workspace list --json --window $ROW_WINDOW_TWO" "$(tail -1 "$FAKE_CMUX_STATE/calls.log")"
    fi
    row_cmux_reset
    ROW_WINDOWS='' ROW_WINDOWS_RC=1
    if [[ $policy == checked ]]; then
      check_rows_load "$policy" 1 '' 0
      assert_eq 'checked requires successful enumeration' '--json list-windows' "$(cat "$FAKE_CMUX_STATE/calls.log")"
    else
      check_rows_load "$policy" 0 "{\"workspaces\":[$ROW_ONE]}" 0
      assert_eq "$policy falls back without --json list-windows" $'--json list-windows\nworkspace list --json' "$(cat "$FAKE_CMUX_STATE/calls.log")"
    fi
  done
  row_cmux_reset
  ROW_WINDOWS='a window line in a new format'
  check_rows_load stop 0 "{\"workspaces\":[$ROW_ONE]}" 0
  check_rows_load checked 1 '' 0
  row_cmux_reset
  ROW_WINDOWS="${ROW_WINDOWS%]}"',{ "id":"unrecognized-window"}]'
  check_rows_load stop 0 "{\"workspaces\":[$ROW_ONE]}" 0
  check_rows_load checked 1 '' 0
  row_cmux_reset
  ROW_WINDOWS='[]'
  check_rows_load checked 0 "{\"workspaces\":[$ROW_ONE]}" 1
  ROW_FALLBACK_RC=142
  check_rows_load stop 142 '' 0
  check_rows_load checked 142 '' 0
  end_scenario
}
scenario_row_failures

scenario_row_validation() {
  begin_scenario 'cmux checked row validation' || return 0
  row_cmux_reset
  ROW_ONE_LIST='[]'
  check_rows_load checked 0 '{"workspaces":[]}' 1
  for invalid in '' ' ' 'not json' '{}' 'null' '{"workspaces":{}}' \
    '[{"title":"task"}]' '[{"id":"","title":"task"}]' '[{"id":4,"title":"task"}]' \
    '[{"id":"row"}]' '[{"id":"row","title":4}]' '[{"id":"row","title":"task","description":4}]' \
    '[{"id":"row","title":"task","remote":false}]' \
    '[{"id":"row","title":"task","remote":{"enabled":"true"}}]' \
    '[{"id":"row","title":"task","remote":{"destination":4}}]'; do
    ROW_ONE_LIST=$invalid
    assert_result "checked rejects $invalid" no load_test_rows checked
    assert_eq 'a failed validation clears the previous snapshot' '' "$CMUX_ROWS_JSON"
  done
  ROW_ONE_LIST='{"workspaces":['
  assert_result 'the hook rejects invalid JSON' no load_test_rows stop
  row_cmux_reset
  ROW_WINDOWS="${ROW_WINDOWS%]},{\"id\":\"$ROW_WINDOW_TWO\"}]"
  ROW_TWO_LIST=''
  check_rows_load stop 0 "{\"workspaces\":[$ROW_ONE]}" 0
  check_rows_load checked 1 '' 0
  end_scenario
}
scenario_row_validation

scenario_row_lookup() {
  begin_scenario 'cmux row lookup by title, repository and host' || return 0
  ROW_LOOKUP="[$ROW_TWO,{\"id\":\"other-repo\",\"title\":\"task\",\"description\":\"@local · other\"},$ROW_ONE,\
{\"id\":\"legacy\",\"title\":\"repo:old-task\"},\
{\"id\":\"description-host\",\"title\":\"task\",\"description\":\"@other-vm · repo\",\"remote\":{\"enabled\":true,\"destination\":\"user@other-vm\"}},\
{\"id\":\"disabled-remote\",\"title\":\"local-task\",\"description\":\"@test-vm · repo\",\"remote\":{\"enabled\":false,\"destination\":\"test-vm\"}},\
{\"id\":\"no-repo\",\"title\":\"driver\"}]"
  assert_eq 'a local lookup ignores remote and other repository rows' row-one "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo id)"
  assert_eq 'an object list finds the remote row' row-two "$(printf '{\"workspaces\":%s}' "$ROW_LOOKUP" | cmux_find_row task repo id test-vm)"
  assert_eq 'a lookup can return another field' '@local · repo' "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo description)"
  assert_eq 'an older title still matches' legacy "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row old-task repo id)"
  assert_eq 'the description can identify the host' description-host "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo id other-vm)"
  assert_eq 'a row with remote disabled is local' disabled-remote "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row local-task repo id)"
  assert_eq 'a row can have no repository' no-repo "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row driver '' id)"
  assert_eq 'a missing field prints an empty string' '' "$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo current_directory)"
  rc=0
  out=$(printf '%s' "$ROW_LOOKUP" | cmux_find_row task repo id missing-vm) || rc=$?
  assert_eq 'a missing host prints nothing' '' "$out"
  assert_eq 'a missing host returns a failure' 4 "$rc"
  assert_result 'a remote description alone cannot enable a remote row' no cmux_find_row local-task repo id test-vm <<<"$ROW_LOOKUP"
  assert_result 'another repository does not match' no cmux_find_row task absent id <<<"$ROW_LOOKUP"
  assert_eq 'the first matching row wins' row-one "$(printf '[%s,{"id":"later-row","title":"task","description":"@local · repo"}]' "$ROW_ONE" | cmux_find_row task repo id)"
  end_scenario
}
scenario_row_lookup

mkdir -p "$TEST_ROOT/home/.ssh"
cat >"$TEST_ROOT/home/.ssh/config" <<'CONFIG'
# This line has no aliases.
Host beta alpha # later words are comments
  Host gamma beta
Host wildcard-* literal? !blocked delta
Host !negated epsilon
Host alpha
host lowercase
CONFIG

test_ssh_hosts() {
  local HOME="$TEST_ROOT/home"
  begin_scenario 'SSH aliases from the config file' || return 0
  assert_eq 'literal aliases are sorted and unique' $'alpha\nbeta\ndelta\nepsilon\ngamma' \
    "$(ssh_hosts)"
  assert_result 'known literal alias' yes known_host beta
  assert_result 'wildcard is absent' no known_host 'wildcard-*'
  assert_result 'question mark pattern is absent' no known_host 'literal?'
  assert_result 'negated alias is absent' no known_host '!blocked'
  assert_result 'comment is absent' no known_host later
  assert_result 'partial alias is absent' no known_host alp
  HOME="$TEST_ROOT/empty-home"
  assert_eq 'missing config has no aliases' '' "$(ssh_hosts)"
  assert_result 'missing config has no known alias' no known_host beta
  end_scenario
}
test_ssh_hosts

scenario_tmux_commands() {
  begin_scenario 'exact tmux command lines' || return 0
  expected_task=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test' echo\ task\ ready\;\ exec\ bash 2>/dev/null; for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; tmux set-environment -t '=wt-test' WT_CMUX_CLOSE_ON_EXIT 1; exec tmux attach -d -t '=wt-test'
COMMAND
  )
  assert_eq 'task command line with a command' "$expected_task." "$(tmux_cmd wt-test 'echo task ready'; printf '.')"
  expected_shared=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test' echo\ task\ ready\;\ exec\ bash 2>/dev/null; tmux attach -t '=wt-test'
COMMAND
  )
  assert_eq 'shared command line with a command' "$expected_shared." "$(tmux_cmd wt-test 'echo task ready' shared; printf '.')"
  expected_reinit=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; exec tmux attach -d -t '=wt-test'
COMMAND
  )
  assert_eq 'replacement command line' "$expected_reinit." "$(tmux_cmd wt-test '' '' reinit; printf '.')"
  expected_task_shell=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; for v in CMUX_SOCKET_PATH CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID CMUX_TERMINAL_LIFECYCLE_ID; do export "$v="; tmux set-environment -t '=wt-test' "$v" ''; done; for v in CMUX_TUI_SOCKET CMUX_TUI_TERMINAL_ID CMUX_TUI_SESSION_ID; do tmux set-environment -t '=wt-test' "$v" "$(printenv "$v")"; done; tmux set-environment -t '=wt-test' WT_CMUX_CLOSE_ON_EXIT 1; exec tmux attach -d -t '=wt-test'
COMMAND
  )
  assert_eq 'task command line without a command' "$expected_task_shell." "$(tmux_cmd wt-test; printf '.')"
  expected_shared_shell=$(cat <<'COMMAND'
tmux new-session -d -s 'wt-test'  2>/dev/null; tmux attach -t '=wt-test'
COMMAND
  )
  assert_eq 'shared command line without a command' "$expected_shared_shell." "$(tmux_cmd wt-test '' shared; printf '.')"
  end_scenario
}
scenario_tmux_commands

with_relay_env() {
  local PATH="$TEST_ROOT/bin:$PATH" TMUX=/tmp/fake
  local -x CMUX_SOCKET_PATH=127.0.0.1:1111 CMUX_WORKSPACE_ID=pane-workspace CMUX_SURFACE_ID=pane-surface
  local -x CMUX_PANEL_ID=pane-panel CMUX_TAB_ID=pane-tab CMUX_TERMINAL_LIFECYCLE_ID=pane-lifecycle
  local -x CMUX_TUI_SOCKET=/tmp/pane-native CMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local -x CMUX_TUI_SESSION_ID=pane-session
  local relay_tui_socket relay_tui_terminal relay_ident
  local -x RELAY_TMUX_ENV="$TEST_ROOT/tmux.env" RELAY_TMUX_LOG="$TEST_ROOT/tmux.log" RELAY_TMUX_FAIL=''
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/no-tmux"
  cat > "$TEST_ROOT/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELAY_TMUX_LOG"
[[ $1 == "$RELAY_TMUX_FAIL" ]] && exit 1
case $* in
  'display-message -p #S') echo task:identity ;;
  'show-environment -t =task:identity') cat "$RELAY_TMUX_ENV" ;;
  *) exit 1 ;;
esac
TMUX
  chmod +x "$TEST_ROOT/bin/tmux"
  : > "$RELAY_TMUX_LOG"
  : > "$RELAY_TMUX_ENV"

  "$@"
}

scenario_relay_without_tmux() {
  begin_scenario 'relay identity without tmux' || return 0
  TMUX=''
  assert_result 'a pane identity is usable outside tmux' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'the pane supplies the native socket' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'the pane supplies the native terminal' term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$relay_tui_terminal"
  assert_eq 'all three pane variables reach the child' \
    $'CMUX_TUI_SOCKET=/tmp/pane-native\nCMUX_TUI_TERMINAL_ID=term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nCMUX_TUI_SESSION_ID=pane-session' \
    "$(printf '%s\n' "${relay_ident[@]}")"
  assert_eq 'tmux is not queried outside tmux' '' "$(cat "$RELAY_TMUX_LOG")"
  TMUX=/tmp/fake
  PATH="$TEST_ROOT/no-tmux" assert_result 'a missing tmux command keeps the pane identity' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'a missing tmux command keeps the socket' /tmp/pane-native "$relay_tui_socket"
  end_scenario
}
with_relay_env scenario_relay_without_tmux

scenario_relay_missing_values() {
  begin_scenario 'missing and unset session variables keep pane values' || return 0
  printf '%s\n' -CMUX_TUI_SOCKET CMUX_TUI_SESSION_ID=current-session > "$RELAY_TMUX_ENV"
  assert_result 'an unset session socket keeps the pane relay' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'an unset variable keeps the pane value' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'a session variable overrides the pane' current-session "$(printf '%s\n' "${relay_ident[@]}" | sed -n 's/^CMUX_TUI_SESSION_ID=//p')"
  assert_eq 'an absent variable keeps the pane value' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'one query reads the whole environment with an exact session target' \
    $'display-message -p #S\nshow-environment -t =task:identity' "$(cat "$RELAY_TMUX_LOG")"
  end_scenario
}
with_relay_env scenario_relay_missing_values

scenario_relay_empty_values() {
  begin_scenario 'empty session values clear stale pane values and child values' || return 0
  printf '%s\n' CMUX_SOCKET_PATH= CMUX_WORKSPACE_ID= CMUX_TUI_SOCKET= CMUX_TUI_TERMINAL_ID= CMUX_TUI_SESSION_ID= > "$RELAY_TMUX_ENV"
  assert_result 'cleared transports have no relay' no relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'the native socket is empty' '' "$relay_tui_socket"
  assert_eq 'the native terminal is empty' '' "$relay_tui_terminal"
  # shellcheck disable=SC2016
  assert_eq 'a child cannot inherit the stale transport identities' '||' \
    "$(env CMUX_TUI_SOCKET=stale CMUX_TUI_TERMINAL_ID=stale CMUX_TUI_SESSION_ID=stale \
      "${relay_ident[@]}" "$BASH" -c 'printf "%s|%s|%s" "$CMUX_TUI_SOCKET" "$CMUX_TUI_TERMINAL_ID" "$CMUX_TUI_SESSION_ID"')"
  end_scenario
}
with_relay_env scenario_relay_empty_values

scenario_relay_session_identity() {
  begin_scenario 'a native session overrides the pane identity' || return 0
  printf '%s\n' CMUX_SOCKET_PATH= CMUX_WORKSPACE_ID= CMUX_SURFACE_ID= CMUX_PANEL_ID= CMUX_TAB_ID= \
    CMUX_TERMINAL_LIFECYCLE_ID= CMUX_TUI_SOCKET=/tmp/current-native \
    CMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb CMUX_TUI_SESSION_ID=current-session > "$RELAY_TMUX_ENV"
  : > "$RELAY_TMUX_LOG"
  assert_result 'the native session is usable' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'the native session supplies the socket' /tmp/current-native "$relay_tui_socket"
  assert_eq 'the native session supplies the terminal' term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$relay_tui_terminal"
  assert_eq 'all three native session values reach the child' \
    $'CMUX_TUI_SOCKET=/tmp/current-native\nCMUX_TUI_TERMINAL_ID=term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nCMUX_TUI_SESSION_ID=current-session' \
    "$(printf '%s\n' "${relay_ident[@]}")"
  assert_eq 'a native read makes only two tmux calls' \
    $'display-message -p #S\nshow-environment -t =task:identity' "$(cat "$RELAY_TMUX_LOG")"
  end_scenario
}
with_relay_env scenario_relay_session_identity

scenario_relay_query_failures() {
  begin_scenario 'tmux query failures keep pane values' || return 0
  RELAY_TMUX_FAIL=display-message
  : > "$RELAY_TMUX_LOG"
  assert_result 'a failed session lookup keeps the pane relay' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'a failed session lookup keeps the pane socket' /tmp/pane-native "$relay_tui_socket"
  assert_eq 'a failed session lookup skips the environment query' 'display-message -p #S' "$(cat "$RELAY_TMUX_LOG")"
  RELAY_TMUX_FAIL=show-environment
  assert_result 'a failed environment query keeps the pane relay' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  assert_eq 'a failed environment query keeps the pane socket' /tmp/pane-native "$relay_tui_socket"
  end_scenario
}
with_relay_env scenario_relay_query_failures

scenario_relay_unset_values() {
  begin_scenario 'unset pane variables stay unset unless the session assigns them' || return 0
  RELAY_TMUX_FAIL=''
  unset CMUX_TUI_SESSION_ID
  printf '%s\n' -CMUX_TUI_SESSION_ID > "$RELAY_TMUX_ENV"
  assert_result 'missing pane names do not prevent relay use' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  # shellcheck disable=SC2016
  assert_eq 'absent and removed names stay unset in the child' 'unset' \
    "$(env -u CMUX_TUI_SESSION_ID "${relay_ident[@]}" "$BASH" -c 'printf "%s" "${CMUX_TUI_SESSION_ID-unset}"')"
  printf '%s\n' CMUX_TUI_SESSION_ID= > "$RELAY_TMUX_ENV"
  assert_result 'explicit empty session assignments keep the relay usable' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  # shellcheck disable=SC2016
  assert_eq 'explicit empty session assignments reach the child' '' \
    "$(env -u CMUX_TUI_SESSION_ID "${relay_ident[@]}" "$BASH" -c 'printf "%s" "${CMUX_TUI_SESSION_ID-unset}"')"
  TMUX=''
  assert_result 'missing pane names outside tmux do not prevent relay use' yes relay_env relay_ident relay_tui_socket relay_tui_terminal
  # shellcheck disable=SC2016
  assert_eq 'names absent outside tmux stay unset in the child' 'unset' \
    "$(env -u CMUX_TUI_SESSION_ID "${relay_ident[@]}" "$BASH" -c 'printf "%s" "${CMUX_TUI_SESSION_ID-unset}"')"
  end_scenario
}
with_relay_env scenario_relay_unset_values

run_harness() {
  local filter=$1 body=$2
  HARNESS_RC=0
  # shellcheck disable=SC2016  # The child shell expands its positional arguments.
  HARNESS_OUT=$(ONLY="$filter" "$BASH" -eu -c 'source "$1"; eval "$2"; lib_summary' \
    _ "$REPO/test/lib.sh" "$body" 2>&1) || HARNESS_RC=$?
}

scenario_assertion_guard() {
  begin_scenario 'scenario assertion guard' || return 0
  run_harness '' 'begin_scenario empty; end_scenario'
  assert_eq 'an empty scenario fails' 1 "$HARNESS_RC"
  assert_eq 'an empty scenario reports the cause' yes \
    "$([[ $HARNESS_OUT == *'scenario made no assertions'* ]] && echo yes || echo no)"
  run_harness '' 'begin_scenario first; pass; end_scenario; begin_scenario empty; end_scenario'
  assert_eq 'a previous assertion cannot hide an empty scenario' 1 "$HARNESS_RC"
  run_harness '' 'begin_scenario broken; assert_eq value expected actual; end_scenario; begin_scenario good; pass; end_scenario'
  assert_eq 'a later pass cannot hide an earlier failure' 1 "$HARNESS_RC"
  run_harness '' 'empty() { begin_scenario empty; return 0; }; empty'
  assert_eq 'an empty early return fails' 1 "$HARNESS_RC"
  assert_eq 'an early return reports its unfinished scenario' yes \
    "$([[ $HARNESS_OUT == *'FAIL [empty] scenario did not call end_scenario'* ]] && echo yes || echo no)"
  run_harness '' 'begin_scenario unfinished; pass'
  assert_eq 'assertions cannot complete an unfinished scenario' 1 "$HARNESS_RC"
  run_harness '' 'begin_scenario first; pass; begin_scenario second; pass; end_scenario'
  assert_eq 'a later scenario cannot replace an unfinished scenario' 1 "$HARNESS_RC"
  assert_eq 'an overwritten scenario retains its name in the failure' yes \
    "$([[ $HARNESS_OUT == *'FAIL [first] scenario did not call end_scenario'* ]] && echo yes || echo no)"
  run_harness 'selected' 'begin_scenario selected; pass; begin_scenario skipped || :; end_scenario'
  assert_eq 'a skipped scenario does not replace an active scenario' 0 "$HARNESS_RC"
  run_harness '' 'end_scenario'
  assert_eq 'ending without a matching begin fails' 1 "$HARNESS_RC"
  assert_eq 'an unmatched end reports its cause' yes \
    "$([[ $HARNESS_OUT == *'end_scenario called without begin_scenario'* ]] && echo yes || echo no)"
  run_harness '' 'begin_scenario complete; pass; end_scenario; end_scenario'
  assert_eq 'ending the same scenario twice fails' 1 "$HARNESS_RC"
  run_harness '' 'begin_scenario good; pass; pass; end_scenario'
  assert_eq 'the summary derives the total' 0 "$HARNESS_RC"
  assert_eq 'the summary reports the derived total' yes \
    "$([[ $HARNESS_OUT == *'2 assertions: 2 passed, 0 failed'* ]] && echo yes || echo no)"
  end_scenario
}
scenario_assertion_guard

scenario_filter() {
  begin_scenario 'scenario name filter' || return 0
  local body
  body=$(cat <<'BODY'
first() { begin_scenario 'first scenario' || return 0; fail 'unselected scenario ran'; end_scenario; }
second() { begin_scenario 'second scenario' || return 0; pass; end_scenario; }
first
second
BODY
)
  local pattern
  for pattern in second 'sec*scenario' '?econd scenario'; do
    run_harness "$pattern" "$body"
    assert_eq "$pattern selects one scenario" 0 "$HARNESS_RC"
    assert_eq "$pattern skips the other assertions" yes \
      "$([[ $HARNESS_OUT == *'1 assertions: 1 passed, 0 failed'* && $HARNESS_OUT != *'unselected scenario ran'* ]] && echo yes || echo no)"
  done
  run_harness missing "$body"
  assert_eq 'an unmatched filter fails' 1 "$HARNESS_RC"
  assert_eq 'an unmatched filter reports the cause' yes \
    "$([[ $HARNESS_OUT == *'no scenarios matched ONLY=missing'* ]] && echo yes || echo no)"
  run_harness '' "$body"
  assert_eq 'an empty filter runs the failing scenario too' 1 "$HARNESS_RC"
  end_scenario
}
scenario_filter

scenario_poll_interval() {
  begin_scenario 'poll interval defaults and overrides' || return 0
  local out
  out=$(unset WG_POLL_INTERVAL; sleep() { printf '%s' "$1"; }; wg_sleep)
  assert_eq 'the production poll interval defaults to one second' 1 "$out"
  out=$(WG_POLL_INTERVAL=0; sleep() { printf '%s' "$1"; }; wg_sleep)
  assert_eq 'tests can select a zero interval' 0 "$out"
  out=$(WG_POLL_INTERVAL=0.25; sleep() { printf '%s' "$1"; }; wg_sleep)
  assert_eq 'the poll interval accepts fractional seconds' 0.25 "$out"
  end_scenario
}
scenario_poll_interval

lib_summary
