#!/usr/bin/env bash
# Check all five scripts with /bin/bash and controlled Homebrew candidates.
# Copies use scratch paths, so the suite never changes installed interpreters.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bash5-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
trap lib_cleanup EXIT

BASH5=$BASH
SCRIPTS=(wt azml-ssh-host github-guard cmux-hook agent-notify)
mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/copies" "$TEST_ROOT/lib/workgrove" "$TEST_ROOT/nolib/bin"
FIRST="$TEST_ROOT/first-bash"
SECOND="$TEST_ROOT/second-bash"
for script in "${SCRIPTS[@]}"; do
  sed -e "s|/opt/homebrew/bin/bash|$FIRST|g" -e "s|/usr/local/bin/bash|$SECOND|g" \
    "$REPO/bin/$script" > "$TEST_ROOT/copies/$script"
done
# A copy loads the libraries from ../lib, as the scripts in bin/ do. So copies/ needs lib/ beside it.
cp "$REPO"/lib/workgrove/*.sh "$TEST_ROOT/lib/workgrove/"
# These copies have no ../lib, so they test what each script does when it cannot load the library.
for script in wt cmux-hook agent-notify; do
  cp "$REPO/bin/$script" "$TEST_ROOT/nolib/bin/$script"
done
cat > "$TEST_ROOT/bash-env" <<'BASH_ENV_FILE'
# Bash before 5.2 reads BASH_ENV before it sets $0 to the script path. Until then, $0 is the
# interpreter as run_script spells it: /bin/bash 3.2 on the Mac, or /usr/bin/bash 5.1 on Ubuntu 22.04.
if [[ $0 == "$SCRIPT_UNDER_TEST" || $0 == "$BASH_UNDER_TEST" ]]; then
  printf '%s:%s\n' "${BASH_VERSINFO[0]}" "$BASH" >> "$BASH_TRACE"
fi
BASH_ENV_FILE

run_script() {
  local script=$1 file=$2 interpreter=$3 expected_rc=$4 expected_bash=$5
  local rc=0 out remaining args=()
  case $script in wt|azml-ssh-host) args=(help);; esac
  : > "$TEST_ROOT/trace"
  # A shared file descriptor lets the parent check how much input the hook consumed.
  exec 3<<<'{}'
  env -i PATH="$PATH" \
    HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/home/.local/state" \
    BASH_ENV="$TEST_ROOT/bash-env" SCRIPT_UNDER_TEST="$file" BASH_UNDER_TEST="$interpreter" \
    BASH_TRACE="$TEST_ROOT/trace" \
    "$interpreter" "$file" "${args[@]}" > "$TEST_ROOT/out" 2> "$TEST_ROOT/err" <&3 || rc=$?
  remaining=$(cat <&3)
  exec 3<&-
  out=$(cat "$TEST_ROOT/out")
  assert_eq "$script exit status" "$expected_rc" "$rc"
  assert_eq "$script final interpreter" "$expected_bash" "$(tail -1 "$TEST_ROOT/trace")"
  if [[ $expected_rc == 1 ]]; then
    assert_grep "$script names the fix" "$TEST_ROOT/err" 'brew install bash'
  else
    case $script in
      wt) assert_grep 'wt receives its help argument' "$TEST_ROOT/out" 'wt new  [name]';;
      azml-ssh-host) assert_grep 'azml-ssh-host receives its help argument' "$TEST_ROOT/out" 'azml-ssh-host help';;
      *) assert_eq "$script gives no hook answer" '' "$out"
         if [[ $script == cmux-hook ]]; then
           assert_eq "$script leaves stdin unread" '{}' "$remaining"
         else
           assert_eq "$script drains its payload" '' "$remaining"
         fi;;
    esac
  fi
}

scenario_direct_bash5() {
  begin_scenario 'all scripts run directly under bash 5' || return 0
  for script in "${SCRIPTS[@]}"; do
    run_script "$script" "$REPO/bin/$script" "$BASH5" 0 "${BASH_VERSINFO[0]}:$BASH5"
  done
  end_scenario
}
scenario_direct_bash5

scenario_missing_library() {
  begin_scenario 'scripts with no library: wt stops and the hooks exit 0' || return 0
  for script in wt cmux-hook agent-notify; do
    rc=0
    args=()
    [[ $script == wt ]] && args=(help)
    exec 3<<<'{}'
    env -i PATH="$PATH" HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/home/.local/state" \
      "$BASH5" "$TEST_ROOT/nolib/bin/$script" "${args[@]}" > "$TEST_ROOT/out" 2> "$TEST_ROOT/err" <&3 || rc=$?
    remaining=$(cat <&3)
    exec 3<&-
    if [[ $script == wt ]]; then
      assert_eq 'wt exit status with no library' 1 "$rc"
      assert_grep 'wt says that it cannot load the library' "$TEST_ROOT/err" 'cannot load'
    else
      assert_eq "$script exit status with no library" 0 "$rc"
      assert_eq "$script gives no hook answer with no library" '' "$(cat "$TEST_ROOT/out")"
      if [[ $script == cmux-hook ]]; then
        assert_eq "$script leaves stdin unread with no library" '{}' "$remaining"
      else
        assert_eq "$script drains its payload with no library" '' "$remaining"
      fi
      if [[ $script == agent-notify ]]; then
        assert_grep 'agent-notify says that it cannot load the library' "$TEST_ROOT/err" 'cannot load'
      fi
    fi
  done
  end_scenario
}
scenario_missing_library

# install.sh links each script into ~/.local/bin. Here a relative link points to an absolute link, which
# points to the script in this checkout. Each run starts in another folder, so only the link leads to lib/.
mkdir -p "$TEST_ROOT/links/bin" "$TEST_ROOT/links/chain"
for script in wt cmux-hook agent-notify; do
  ln -s "$REPO/bin/$script" "$TEST_ROOT/links/chain/$script"
  ln -s "../chain/$script" "$TEST_ROOT/links/bin/$script"
done
scenario_linked_library() {
  begin_scenario 'scripts find the library through a chain of links' || return 0
  out=$(cd "$TEST_ROOT/home" && env -i PATH="$PATH" HOME="$TEST_ROOT/home" "$TEST_ROOT/links/bin/wt" help 2>&1) || true
  assert_eq 'wt prints its help through the links' yes "$([[ $out == *'wt new  [name]'* ]] && echo yes || echo "$out")"
  out=$(cd "$TEST_ROOT/links/bin" && env -i PATH="$PATH" HOME="$TEST_ROOT/home" "$BASH5" wt help 2>&1) || true
  assert_eq 'bash wt, in the folder of the link, prints the help' yes "$([[ $out == *'wt new  [name]'* ]] && echo yes || echo "$out")"
  cat > "$TEST_ROOT/cmux" <<'CMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$CMUX_LOG"
exit 1
CMUX
  chmod +x "$TEST_ROOT/cmux"
  out=$(cd "$TEST_ROOT/home" && env -i PATH="$PATH" HOME="$TEST_ROOT/home" \
    XDG_STATE_HOME="$TEST_ROOT/home/.local/state" CMUX_LOG="$TEST_ROOT/cmux.log" \
    CMUX_BUNDLED_CLI_PATH="$TEST_ROOT/cmux" \
    CMUX_AUTOMATION_EVENT_JSON='{"name":"notification.created","workspace_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","payload":{"notification_id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"}}' \
    "$TEST_ROOT/links/bin/cmux-hook" --event 2>&1) || true
  assert_grep 'cmux-hook loads the library through the links' "$TEST_ROOT/cmux.log" 'list-windows'
  out=$(cd "$TEST_ROOT/home" && printf '{}\n' | env -i PATH="$PATH" HOME="$TEST_ROOT/home" \
    XDG_STATE_HOME="$TEST_ROOT/home/.local/state" "$TEST_ROOT/links/bin/agent-notify" 2>&1) || true
  assert_eq 'agent-notify loads the library through the links' '' "$out"
  end_scenario
}
scenario_linked_library

# Linux has no older /bin/bash. The Mac exercises the actual bash 3.2 handoff.
SYS_MAJOR=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')
scenario_installed_bash5() {
  begin_scenario 'all scripts reach installed bash 5 when /bin/bash starts them' || return 0
  local installed='' candidate script
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x $candidate ]] && "$candidate" -c '((BASH_VERSINFO[0] >= 5))'; then
      installed=$candidate
      break
    fi
  done
  for script in "${SCRIPTS[@]}"; do
    run_script "$script" "$REPO/bin/$script" /bin/bash 0 "${BASH_VERSINFO[0]}:$installed"
  done
  end_scenario
}

scenario_candidate_selection() {
  local scenario=$1 chosen script rc major
  begin_scenario "candidate selection: $scenario" || return 0
  rm -f "$FIRST" "$SECOND"
  case $scenario in
    first-valid) ln -s "$BASH5" "$FIRST"; ln -s "$BASH5" "$SECOND"; chosen=$FIRST;;
    first-old) ln -s /bin/bash "$FIRST"; ln -s "$BASH5" "$SECOND"; chosen=$SECOND;;
    first-missing) ln -s "$BASH5" "$SECOND"; chosen=$SECOND;;
    none) chosen=/bin/bash;;
    both-old) ln -s /bin/bash "$FIRST"; ln -s /bin/bash "$SECOND"; chosen=/bin/bash;;
  esac
  for script in "${SCRIPTS[@]}"; do
    rc=0
    major=${BASH_VERSINFO[0]}
    if [[ $chosen == /bin/bash ]]; then
      major=$SYS_MAJOR
      case $script in wt|azml-ssh-host) rc=1;; esac
    fi
    run_script "$script" "$TEST_ROOT/copies/$script" /bin/bash "$rc" "$major:$chosen"
  done
  end_scenario
}

if ((SYS_MAJOR < 5)); then
  scenario_installed_bash5
  for scenario in first-valid first-old first-missing none both-old; do
    scenario_candidate_selection "$scenario"
  done
fi
lib_summary
