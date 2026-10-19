#!/usr/bin/env bash
# Check optional Apple Git resolution without changing the selected Git version or fixture shims.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/runner-git-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=test/runner-git.sh
source "$REPO/test/runner-git.sh"
trap lib_cleanup EXIT

mkdir -p "$TEST_ROOT/tools" "$TEST_ROOT/no-xcrun" "$TEST_ROOT/Developer Tools" "$TEST_ROOT/shim"
for tool in mkdir ln rmdir; do
  ln -s "$(command -v "$tool")" "$TEST_ROOT/tools/$tool"
  ln -s "$(command -v "$tool")" "$TEST_ROOT/no-xcrun/$tool"
done
cat >"$TEST_ROOT/tools/xcrun" <<'SH'
#!/bin/sh
printf '%s|%s\n' "$*" "${DEVELOPER_DIR:-}" >> "$GIT_TEST_LOG"
printf '%s\n' "$GIT_TEST_CANDIDATE"
exit "${GIT_TEST_XCRUN_STATUS:-0}"
SH
cat >"$TEST_ROOT/Developer Tools/git" <<'SH'
#!/bin/sh
if [ "$1" = --version ]; then
  printf '%s\n' "$GIT_TEST_VERSION"
  exit "${GIT_TEST_VERSION_STATUS:-0}"
fi
printf 'resolved Git\n'
SH
cat >"$TEST_ROOT/shim/git" <<'SH'
#!/bin/sh
printf 'fixture Git\n'
SH
chmod +x "$TEST_ROOT/tools/xcrun" "$TEST_ROOT/Developer Tools/git" "$TEST_ROOT/shim/git"
GIT_TEST_LOG=$TEST_ROOT/xcrun.log
GIT_TEST_CANDIDATE=$TEST_ROOT/Developer\ Tools/git
GIT_TEST_VERSION=$(/usr/bin/git --version)
export GIT_TEST_LOG GIT_TEST_CANDIDATE GIT_TEST_VERSION

scenario_resolve() {
  begin_scenario 'Apple Git resolution preserves versions, spaces, and fixture precedence' || return 0
  local scratch=$TEST_ROOT/valid result original_path=$PATH selected_developer
  selected_developer=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p 2>/dev/null || printf '/Developer Tools/Selected')}
  mkdir "$scratch"
  result=$(PATH="$TEST_ROOT/tools" DEVELOPER_DIR="$selected_developer" runner_git_dir Darwin /usr/bin/git "$scratch")
  assert_eq 'the helper returns its Git directory' "$scratch/git-bin" "$result"
  assert_eq 'the helper leaves the caller PATH unchanged' "$original_path" "$PATH"
  assert_eq 'the symlink preserves the candidate path with spaces' "$GIT_TEST_CANDIDATE" "$(readlink "$result/git")"
  assert_grep 'xcrun receives its arguments and selected developer directory' "$GIT_TEST_LOG" "--find git|$selected_developer"
  assert_eq 'the resolved Git runs first' 'resolved Git' "$(PATH="$result:$PATH" git fixture)"
  assert_eq 'a later fixture shim retains precedence' 'fixture Git' "$(PATH="$TEST_ROOT/shim:$result:$PATH" git fixture)"
  end_scenario
}

scenario_bypass() {
  begin_scenario 'Linux and custom Git selections bypass xcrun' || return 0
  local os selected result scratch
  rm -f "$GIT_TEST_LOG"
  for os in Linux Darwin; do
    for selected in /opt/homebrew/bin/git "$TEST_ROOT/shim/git" git; do
      scratch=$TEST_ROOT/bypass-${os}-${selected##*/}
      result=$(PATH="$TEST_ROOT/tools" runner_git_dir "$os" "$selected" "$scratch")
      assert_eq 'custom Git remains selected' '' "$result"
    done
  done
  result=$(PATH="$TEST_ROOT/tools" runner_git_dir Linux /usr/bin/git "$TEST_ROOT/linux")
  assert_eq 'Linux keeps system Git' '' "$result"
  assert_absent "$TEST_ROOT" xcrun.log
  end_scenario
}

scenario_fallback() {
  begin_scenario 'invalid resolver results preserve the original Git' || return 0
  local kind scratch result status
  local valid_candidate=$GIT_TEST_CANDIDATE valid_version=$GIT_TEST_VERSION
  for kind in missing-xcrun failing-xcrun relative missing nonexecutable directory launcher version-failure version-mismatch empty-version blocked-directory blocked-link colon-directory; do
    scratch=$TEST_ROOT/fallback-$kind
    mkdir "$scratch"
    GIT_TEST_CANDIDATE=$valid_candidate
    GIT_TEST_VERSION=$valid_version
    local GIT_TEST_XCRUN_STATUS=0 GIT_TEST_VERSION_STATUS=0 test_path=$TEST_ROOT/tools
    export GIT_TEST_XCRUN_STATUS GIT_TEST_VERSION_STATUS
    case $kind in
      missing-xcrun) test_path=$TEST_ROOT/no-xcrun ;;
      failing-xcrun) GIT_TEST_XCRUN_STATUS=1 ;;
      relative) GIT_TEST_CANDIDATE=relative/git ;;
      missing) GIT_TEST_CANDIDATE=$scratch/missing ;;
      nonexecutable) GIT_TEST_CANDIDATE=$scratch/git; printf 'not executable\n' > "$GIT_TEST_CANDIDATE" ;;
      directory) GIT_TEST_CANDIDATE=$scratch ;;
      launcher) GIT_TEST_CANDIDATE=/usr/bin/git ;;
      version-failure) GIT_TEST_VERSION_STATUS=1 ;;
      version-mismatch) GIT_TEST_VERSION='git version other' ;;
      empty-version) GIT_TEST_VERSION='' ;;
      blocked-directory) mkdir "$scratch/git-bin" ;;
      blocked-link)
        # Fail only link creation, after the helper has made its directory.
        ln() { return 1; }
        ;;
      colon-directory) scratch=$scratch:colon; mkdir "$scratch" ;;
    esac
    status=0
    result=$(PATH="$test_path" runner_git_dir Darwin /usr/bin/git "$scratch") || status=$?
    assert_eq "$kind returns success" 0 "$status"
    assert_eq "$kind leaves Git unchanged" '' "$result"
    [[ $kind != blocked-link ]] || unset -f ln
  done
  GIT_TEST_CANDIDATE=$valid_candidate
  GIT_TEST_VERSION=$valid_version
  end_scenario
}

scenario_resolve
scenario_bypass
scenario_fallback
lib_summary
