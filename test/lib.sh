# shellcheck shell=bash
#
# test/lib.sh: the assertion vocabulary test/install-smoke.sh and test/wt-smoke.sh both speak.
# Sourced, never run, and it sets no shell options — the suite that sources it owns those.
#
# Why it exists: this vocabulary was written once, inside install-smoke.sh, and wt-smoke.sh was about to
# make a second copy of it. A counter incremented in two files drifts, and an assert_eq fixed in one file
# and not the other is worse than no assert_eq at all — so the two suites share one body and each keeps
# only the fixtures and helpers that are actually its own.
#
# Nothing here is installed anywhere. install.sh links home/, bin/ and the skills and never looks at test/,
# and remove_retired_links only ever walks directories under $HOME (see its `dirs` list), so a new file in
# test/ is invisible to both: adding this one cannot change what a machine gets or what a rerun retires.
#
# What a caller sets before the first call:
#   REPO             the workstation checkout root — assert_link compares link targets against it
#   TEST_ROOT        this run's scratch directory — lib_cleanup is what removes it
#   KEEP_LABEL       what lib_cleanup calls what it keeps ("scratch homes", "scratch repos")
#   LIB_BASE_LABEL   optional: how the <base> half of a <base> <rel> pair reads in a failure message.
#                    install-smoke.sh sets "~", because every base it passes IS a scratch HOME and "~/.zshrc"
#                    is how that file is spoken about; left unset, the real base path is printed, which is
#                    what a suite whose bases are repositories rather than homes wants.
#
# Assertions are silent when they hold and loud when they do not. They never return non-zero for a failed
# assertion — a suite under `set -e` would exit at the first one and report nothing about the rest — so a
# caller that needs to branch on the result checks the thing itself.

PASS=0
FAIL=0
SCENARIO="(startup)"
SCENARIO_FAILS=0

# lib_label <base> <rel>: how a base/rel pair is named in a failure message. See LIB_BASE_LABEL.
lib_label() {
  printf '%s/%s' "${LIB_BASE_LABEL:-$1}" "$2"
}

# describe <path>: what is actually there, for a failure message that names found as well as expected.
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

# assert_absent <base> <rel>: nothing there at all, not even a dangling link.
assert_absent() {
  local p="$1/$2"
  if [[ -e "$p" || -L "$p" ]]; then
    fail "at $(lib_label "$1" "$2"): expected nothing, found $(describe "$p")"
    return 0
  fi
  pass
}

# assert_regular <base> <rel>: a real file, not a symlink — the shape a stranger's own dotfile must keep.
assert_regular() {
  local p="$1/$2"
  if [[ -L "$p" || ! -f "$p" ]]; then
    fail "at $(lib_label "$1" "$2"): expected a regular file, found $(describe "$p")"
    return 0
  fi
  pass
}

# assert_not_link <base> <rel>: weaker than assert_absent, for a path a fallback legitimately creates.
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

# assert_grep <what> <file> <fixed string>: the file still carries a line the user wrote.
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

begin_scenario() {
  SCENARIO="$1"
  SCENARIO_FAILS=0
}

end_scenario() {
  if [[ $SCENARIO_FAILS -eq 0 ]]; then
    echo "ok   $SCENARIO"
  else
    echo "FAIL $SCENARIO ($SCENARIO_FAILS assertion(s) failed)"
  fi
}

# lib_cleanup: the EXIT trap both suites install. KEEP=1 keeps the scratch tree for inspection, and so does
# any failure — a failed assertion is exactly when you want to look at what was left behind.
lib_cleanup() {
  [[ -n "${TEST_ROOT:-}" ]] || return 0
  if [[ -n "${KEEP:-}" || $FAIL -gt 0 ]]; then
    echo "${KEEP_LABEL:-scratch files} kept in $TEST_ROOT"
    return 0
  fi
  rm -rf "$TEST_ROOT"
}

# lib_summary <expected assertions>: the count line, and the check that catches the failure mode a pass/fail
# count cannot see — a scenario that stops asserting rather than starts failing. One mutation quietly took
# install-smoke.sh from 323 assertions to 318 that way, with every scenario still green. Exits non-zero on
# either kind of failure, so it is the last thing a suite's main() runs.
lib_summary() {
  echo "$((PASS + FAIL)) assertions: $PASS passed, $FAIL failed"
  if [[ $((PASS + FAIL)) -ne $1 ]]; then
    echo "FAIL: expected $1 assertions, ran $((PASS + FAIL)) — a scenario skipped its assertions" \
         "instead of failing them, or one was added without updating FIXED_ASSERTIONS" >&2
    exit 1
  fi
  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}
