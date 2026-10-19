# shellcheck shell=bash
#
# test/lib.sh: the assertion vocabulary that every suite in test/ uses.
# A suite sources this file; nothing runs it directly. It sets no shell options, because the suite that
# sources it owns those.
#
# Why it exists: this vocabulary was first written inside install-smoke.sh, and wt-smoke.sh was about to
# make a second copy of it. A counter that two files increment drifts. An assert_eq that is fixed in one
# file but not in the other is worse than no assert_eq. So the suites share one body, and each suite
# keeps only the fixtures and helpers that are its own.
#
# Nothing here is installed: install.sh links home/, bin/ and the skills, and never looks at test/.
# remove_retired_links walks only directories under $HOME (see its `dirs` list). So neither install.sh nor
# remove_retired_links sees a new file in test/. Adding this file therefore cannot change what a machine
# gets or what a rerun retires.
#
# What a caller sets before the first call:
#   REPO             the workgrove checkout root. assert_link compares link targets with it.
#   TEST_ROOT        this run's scratch directory, which lib_cleanup removes. lib_cleanup refuses only the
#                    roots that can never be safe ("/", the home directory, or any ancestor of it). So the
#                    suite must check that its root is in a safe place.
#   KEEP_LABEL       the name that lib_cleanup gives to what it keeps ("scratch homes", "scratch repos").
#   LIB_BASE_LABEL   optional: how the <base> part of a <base> <rel> pair reads in a failure message.
#                    install-smoke.sh sets "~", because every base it passes IS a scratch HOME, and
#                    "~/.zshrc" is the usual name of that file. When LIB_BASE_LABEL is unset, lib_label
#                    prints the real base path. A suite whose bases are repositories, not homes, wants that.
#
# Assertions are silent when they hold and loud when they fail. A failed assertion never returns non-zero,
# because a suite under `set -e` would then exit at the first failure and report nothing about the rest.
# So a caller that must branch on the result checks the condition itself.

PASS=0
FAIL=0
SCENARIO="(startup)"
SCENARIO_FAILS=0
SCENARIO_START=0
SCENARIOS=0

# lib_label <base> <rel>: how a base/rel pair is named in a failure message. See LIB_BASE_LABEL.
lib_label() {
  printf '%s/%s' "${LIB_BASE_LABEL:-$1}" "$2"
}

# describe <path>: what is at <path>. A failure message shows it next to what the assertion expected.
describe() {
  if [[ -L "$1" ]]; then
    echo "a symlink -> $(readlink "$1")"
  elif [[ -d "$1" ]]; then
    echo "a directory"
  elif [[ -f "$1" ]]; then
    echo "a regular file"
  elif [[ -e "$1" ]]; then
    echo "neither a file nor a directory"
  else
    echo "nothing"
  fi
}

pass() { PASS=$((PASS + 1)); }

fail() {
  FAIL=$((FAIL + 1))
  SCENARIO_FAILS=$((SCENARIO_FAILS + 1))
  echo "  FAIL [$SCENARIO] $*" >&2
}

# assert_link <base> <rel> <repo-relative src>: base/rel is a symlink to <repo>/src.
assert_link() {
  local p="$1/$2" want="$REPO/$3" got
  if [[ ! -L "$p" ]]; then
    fail "at $(lib_label "$1" "$2"): expected a symlink -> $want, found $(describe "$p")"
    return 0
  fi
  got="$(readlink "$p")"
  if [[ "$got" != "$want" ]]; then
    fail "at $(lib_label "$1" "$2"): expected a symlink -> $want, found a symlink -> $got"
    return 0
  fi
  pass
}

# assert_absent <base> <rel>: nothing is at base/rel, not even a dangling link.
assert_absent() {
  local p="$1/$2"
  if [[ -e "$p" || -L "$p" ]]; then
    fail "at $(lib_label "$1" "$2"): expected nothing, found $(describe "$p")"
    return 0
  fi
  pass
}

# assert_regular <base> <rel>: base/rel is a regular file, not a symlink. A stranger's own dotfile must
# keep this shape.
assert_regular() {
  local p="$1/$2"
  if [[ -L "$p" || ! -f "$p" ]]; then
    fail "at $(lib_label "$1" "$2"): expected a regular file, found $(describe "$p")"
    return 0
  fi
  pass
}

# assert_not_link <base> <rel>: base/rel is not a symlink. It is weaker than assert_absent, for a path
# that a fallback is allowed to create.
assert_not_link() {
  local p="$1/$2"
  if [[ -L "$p" ]]; then
    fail "at $(lib_label "$1" "$2"): expected not a symlink, found $(describe "$p")"
    return 0
  fi
  pass
}

assert_eq() {   # <what> <expected> <actual>
  if [[ "$2" != "$3" ]]; then
    fail "$1: expected '$2', found '$3'"
    return 0
  fi
  pass
}

# assert_grep <what> <file> <fixed string>: the file still contains a line that the user wrote.
assert_grep() {
  if [[ ! -f "$2" ]]; then
    fail "$1: expected '$3' in $2, but $2 is $(describe "$2")"
    return 0
  fi
  if ! grep -qF -- "$3" "$2"; then
    fail "$1: expected '$3' somewhere in $2, not found"
    return 0
  fi
  pass
}

lib_seconds() {
  printf '%d.%03d' "$(($1 / 1000000))" "$(($1 % 1000000 / 1000))"
}

scenario_matches() {
  # shellcheck disable=SC2053  # ONLY is a pattern, not a literal string.
  [[ $1 == *${ONLY:-}* ]]
}

# ONLY selects scenario names by shell glob, with an implicit * on each side.
# Call begin_scenario inside a function with `|| return 0` to skip an unmatched scenario.
begin_scenario() {
  scenario_matches "$1" || return 1
  SCENARIO="$1"
  SCENARIO_FAILS=0
  SCENARIO_START=$((PASS + FAIL))
  SCENARIO_STARTED=${EPOCHREALTIME:-$SECONDS.000000}
  SCENARIO_STARTED=${SCENARIO_STARTED/./}
  SCENARIOS=$((SCENARIOS + 1))
}

end_scenario() {
  if [[ $((PASS + FAIL)) -eq $SCENARIO_START ]]; then
    fail "scenario made no assertions"
  fi
  if [[ $SCENARIO_FAILS -eq 0 ]]; then
    echo "ok   $SCENARIO"
  else
    echo "FAIL $SCENARIO ($SCENARIO_FAILS assertion(s) failed)"
  fi
  local now=${EPOCHREALTIME:-$SECONDS.000000} elapsed
  now=${now/./}
  elapsed=$((now - SCENARIO_STARTED))
  ((elapsed >= 0)) || elapsed=0
  printf 'scenario time: %s: %s s\n' "$SCENARIO" "$(lib_seconds "$elapsed")"
}

# lib_cleanup: the EXIT trap that every suite installs. KEEP=1 keeps the scratch tree for inspection. Any
# failure also keeps it, because a failed assertion is when you most want to examine what was left behind.
#
# The `rm -rf` is the only destructive line in this file. It is also the only path that a suite reaches
# without a guard of its own. Every suite makes $TEST_ROOT with `mktemp -d`, resolves it with `pwd -P`, and
# refuses a root inside the real home BEFORE it arms this trap. After that, install-smoke.sh and wt-smoke.sh
# also check their fixture paths with a guard of their own: guard_scratch_home and guard_scratch_root.
#
# This file cannot see any of that, and it is written for suites that do not exist yet. So lib_cleanup
# also refuses the paths that can only be a mistake: "/", the home directory itself, and any ancestor of
# it. If a root cannot be resolved, lib_cleanup leaves it alone and does not guess. This is a backstop,
# not the check. A suite must still validate its own root, because "not obviously catastrophic" is a much
# weaker promise than "inside this run's scratch root". The suites make the second promise.
lib_cleanup() {
  [[ -n "${TEST_ROOT:-}" ]] || return 0
  if [[ -n "${KEEP:-}" || $FAIL -gt 0 ]]; then
    echo "${KEEP_LABEL:-scratch files} kept in $TEST_ROOT"
    return 0
  fi
  local root home
  root="$(cd "$TEST_ROOT" 2>/dev/null && pwd -P)" || return 0
  home="$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || home=""
  if [[ "$root" == / || ( -n "$home" && "$root" == "$home" ) ]]; then
    echo "lib_cleanup: refusing to remove TEST_ROOT=$root" >&2
    return 0
  fi
  if [[ -n "$home" && "$home/" == "$root"/* ]]; then
    echo "lib_cleanup: refusing to remove TEST_ROOT=$root; the home directory is inside it" >&2
    return 0
  fi
  rm -rf "$root"
}

# Print the derived assertion total. Fail when assertions fail or the filter selects no scenarios.
lib_summary() {
  echo "$((PASS + FAIL)) assertions: $PASS passed, $FAIL failed"
  if [[ $SCENARIOS -eq 0 ]]; then
    echo "FAIL: no scenarios matched ONLY=${ONLY:-}" >&2
    exit 1
  fi
  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}
