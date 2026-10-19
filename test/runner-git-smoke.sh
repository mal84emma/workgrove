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
for tool in mkdir chmod rm rmdir; do
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
if [ "$1" = --args ]; then
  shift
  printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "$3"
  exit 0
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
  assert_regular "$scratch" git-bin/git
  assert_grep 'xcrun receives its arguments and selected developer directory' "$GIT_TEST_LOG" "--find git|$selected_developer"
  assert_eq 'the resolved Git runs first' 'resolved Git' "$(PATH="$result:$PATH" git fixture)"
  assert_eq 'a later fixture shim retains precedence' 'fixture Git' "$(PATH="$TEST_ROOT/shim:$result:$PATH" git fixture)"
  end_scenario
}

scenario_path_quoting() {
  begin_scenario 'resolved Git preserves quoted paths and argument boundaries' || return 0
  local odd_directory=$TEST_ROOT/$'Developer\'s Tools\n$(exit 99)' scratch=$TEST_ROOT/quoted result
  local original_candidate=$GIT_TEST_CANDIDATE
  mkdir -p "$odd_directory" "$scratch"
  cp "$GIT_TEST_CANDIDATE" "$odd_directory/git"
  GIT_TEST_CANDIDATE=$odd_directory/git
  result=$(PATH="$TEST_ROOT/tools" runner_git_dir Darwin /usr/bin/git "$scratch")
  assert_eq 'a quoted candidate path still executes' 'resolved Git' "$("$result/git" fixture)"
  assert_eq 'the wrapper preserves spaces, empty arguments, and globs' '3|two words||*' \
    "$("$result/git" --args 'two words' '' '*')"
  GIT_TEST_CANDIDATE=$original_candidate
  end_scenario
}

scenario_runtime_paths() {
  begin_scenario 'Apple Git keeps its installed helpers and templates' || return 0
  if [[ $(uname -s) != Darwin ]]; then
    pass
    end_scenario
    return 0
  fi
  local scratch=$TEST_ROOT/runtime result original_output resolved_output original_rc=0 resolved_rc=0
  local GIT_OBJECT_DIRECTORY=$scratch/ambient-objects GIT_INDEX_FILE=$scratch/ambient-index
  local XDG_CONFIG_HOME=$scratch/ambient-config
  export GIT_OBJECT_DIRECTORY GIT_INDEX_FILE XDG_CONFIG_HOME
  local runtime_env=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_EXEC_PATH -u GIT_TEMPLATE_DIR
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_INDEX_FILE -u GIT_SHALLOW_FILE -u GIT_NAMESPACE
    -u GIT_CONFIG -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS
    "HOME=$scratch/home" "XDG_CONFIG_HOME=$scratch/home/.config" GIT_CONFIG_NOSYSTEM=1)
  mkdir -p "$scratch/home" "$scratch/ambient-config/git" "$scratch/ambient-template"
  printf 'ambient template\n' >"$scratch/ambient-template/ambient-marker"
  printf '[init]\n\ttemplateDir = %s\n' "$scratch/ambient-template" >"$scratch/ambient-config/git/config"
  result=$(runner_git_dir Darwin /usr/bin/git "$scratch")
  if [[ -z $result ]]; then
    fail 'Apple Git resolution did not produce a wrapper'
    end_scenario
    return 0
  fi
  assert_eq 'the helper directory stays unchanged' \
    "$("${runtime_env[@]}" /usr/bin/git --exec-path)" "$("${runtime_env[@]}" "$result/git" --exec-path)"
  assert_eq 'the documentation directory stays unchanged' \
    "$("${runtime_env[@]}" /usr/bin/git --html-path)" "$("${runtime_env[@]}" "$result/git" --html-path)"
  "${runtime_env[@]}" /usr/bin/git submodule -h >/dev/null 2>&1 || original_rc=$?
  "${runtime_env[@]}" "$result/git" submodule -h >/dev/null 2>&1 || resolved_rc=$?
  assert_eq 'submodule help keeps the selected Git status' "$original_rc" "$resolved_rc"
  original_output=$("${runtime_env[@]}" /usr/bin/git -c init.defaultBranch=main \
    init -q "$scratch/original" 2>&1)
  resolved_rc=0
  resolved_output=$("${runtime_env[@]}" "$result/git" -c init.defaultBranch=main \
    init -q "$scratch/resolved" 2>&1) || resolved_rc=$?
  assert_eq 'resolved Git initializes a repository' 0 "$resolved_rc"
  assert_eq 'initialization keeps the selected Git diagnostics' "$original_output" "$resolved_output"
  assert_eq 'initialization keeps the selected Git templates' \
    "$([[ -f $scratch/original/.git/hooks/pre-commit.sample ]] && echo yes || echo no)" \
    "$([[ -f $scratch/resolved/.git/hooks/pre-commit.sample ]] && echo yes || echo no)"
  assert_absent "$scratch" ambient-objects
  assert_absent "$scratch" ambient-index
  assert_absent "$scratch/original" .git/ambient-marker
  assert_absent "$scratch/resolved" .git/ambient-marker
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
  for kind in missing-xcrun failing-xcrun relative missing nonexecutable directory launcher version-failure version-mismatch empty-version blocked-directory blocked-write blocked-mode colon-directory; do
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
      blocked-write)
        printf() { return 1; }
        ;;
      blocked-mode)
        chmod() { return 1; }
        ;;
      colon-directory) scratch=$scratch:colon; mkdir "$scratch" ;;
    esac
    status=0
    result=$(PATH="$test_path" runner_git_dir Darwin /usr/bin/git "$scratch") || status=$?
    assert_eq "$kind returns success" 0 "$status"
    assert_eq "$kind leaves Git unchanged" '' "$result"
    [[ $kind != blocked-write ]] || unset -f printf
    [[ $kind != blocked-mode ]] || unset -f chmod
  done
  GIT_TEST_CANDIDATE=$valid_candidate
  GIT_TEST_VERSION=$valid_version
  end_scenario
}

scenario_resolve
scenario_path_quoting
scenario_runtime_paths
scenario_bypass
scenario_fallback
lib_summary
