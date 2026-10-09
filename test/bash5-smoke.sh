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
# A copy loads the library from ../lib, as the scripts in bin/ do. So copies/ needs lib/ beside it.
cp "$REPO/lib/workgrove/common.sh" "$TEST_ROOT/lib/workgrove/common.sh"
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
         assert_eq "$script drains its payload" '' "$remaining";;
    esac
  fi
}

begin_scenario 'all scripts run directly under bash 5'
for script in "${SCRIPTS[@]}"; do
  run_script "$script" "$REPO/bin/$script" "$BASH5" 0 "${BASH_VERSINFO[0]}:$BASH5"
done
end_scenario

begin_scenario 'scripts with no library: wt stops and the hooks exit 0'
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
    assert_eq "$script drains its payload with no library" '' "$remaining"
  fi
done
end_scenario

# Linux has no older /bin/bash. The Mac exercises the actual bash 3.2 handoff.
SYS_MAJOR=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')
OLD_ASSERTIONS=0
if ((SYS_MAJOR < 5)); then
  OLD_ASSERTIONS=108
  installed=''
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x $candidate ]] && "$candidate" -c '((BASH_VERSINFO[0] >= 5))'; then
      installed=$candidate
      break
    fi
  done
  begin_scenario 'all scripts reach installed bash 5 when /bin/bash starts them'
  for script in "${SCRIPTS[@]}"; do
    run_script "$script" "$REPO/bin/$script" /bin/bash 0 "${BASH_VERSINFO[0]}:$installed"
  done
  end_scenario

  for scenario in first-valid first-old first-missing none both-old; do
    rm -f "$FIRST" "$SECOND"
    case $scenario in
      first-valid) ln -s "$BASH5" "$FIRST"; ln -s "$BASH5" "$SECOND"; chosen=$FIRST;;
      first-old) ln -s /bin/bash "$FIRST"; ln -s "$BASH5" "$SECOND"; chosen=$SECOND;;
      first-missing) ln -s "$BASH5" "$SECOND"; chosen=$SECOND;;
      none) chosen=/bin/bash;;
      both-old) ln -s /bin/bash "$FIRST"; ln -s /bin/bash "$SECOND"; chosen=/bin/bash;;
    esac
    begin_scenario "candidate selection: $scenario"
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
  done
fi
lib_summary $((26 + OLD_ASSERTIONS))
