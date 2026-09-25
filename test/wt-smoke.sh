#!/usr/bin/env bash
#
# test/wt-smoke.sh: run bin/wt against throwaway repositories and assert what it did.
#   bash test/wt-smoke.sh            (KEEP=1 leaves the scratch repos behind for inspection)
#   WT_BASH=/bin/bash bash test/wt-smoke.sh    (which bash runs bin/wt — see below)
#
# Two interpreters, and they are not the same question. This file is run by whatever bash invoked it;
# bin/wt is run by $WT_BASH, printed in the header line. They default to the same `bash` from PATH, which on
# the author's Mac is Homebrew's 5.x — but bin/wt starts `#!/usr/bin/env bash` and a fresh Mac has no bash
# but /bin/bash 3.2.57, so 3.2 is the interpreter bin/wt gets there until Homebrew arrives. Run this file
# both ways, or the one that matters goes untested under the one that matters.
#
# Why this file exists: bin/wt is 1200 lines that create and DESTROY work — `wt rm` deletes a worktree, its
# branch and its uncommitted files, and `wt prune` does it in a loop without being asked twice. Everything
# standing between a task and a lost afternoon is rm_reasons, whose six branches are each a bug that was
# found the hard way: a base stored as the literal "HEAD" that compares a worktree with itself, a commit
# count taken from a detached HEAD instead of from the branch, an .env copied in by .wt-include that is in
# no git and no backup. None of that was covered by anything. These scenarios cover the refusals first, then
# what `wt new` records (the sidecar every later command reads), how a base is canonicalised (the invariant
# the refusals rest on), the name rules, the read-only commands, and the argument handling of `wt -H`.
#
# The absolute rule: nothing here may touch anything outside this run's scratch root, and nothing here may
# touch cmux, tmux, ssh or the network. Every repository is an mktemp -d under $TEST_ROOT and every wt run
# goes through wt_run, which pins HOME to a scratch home, points WT_REPOS_DIR at the scratch repos and
# CMUX_BUNDLED_CLI_PATH at a stub, and unsets the four CMUX_*/WT_* variables that would otherwise let this
# machine's real session leak in. guard_scratch_root refuses any path outside the scratch root and is
# asserted, first, to refuse — scenario 0 is that proof. Every git command that builds a fixture goes
# through fixture_git, which guards the same way, so no fixture step can reach a repository of the user's.
#
# What a green run does NOT exercise: ssh (scenario 9 asserts only the paths that return before remote_sh is
# reached — every one of them refuses in cmd_host or need_r), cmux itself (a stub answers for it), tmux, the
# `wt task`/`wt driver` pickers, `wt pr`, `wt sync`, `wt update` and VS Code (`wt open` runs a stub `code`).
#
# is_remote() is true on anything that is not a Mac, and bin/wt has no FORCE_OS to lie to it with the way
# install.sh does — adding one would be a change to the code under test. So the assertions that depend on
# being the Mac side of the ssh are guarded by $OS and counted as DARWIN_ASSERTIONS: see the comment there
# for what that leaves uncovered on Linux.
#
# Assertions are silent when they hold and loud when they do not; the script prints one line per scenario
# and a pass/fail count, and exits non-zero if any assertion failed. The count itself is asserted, against
# expected_assertions below, because a scenario that quietly stops checking things still prints "ok".
set -euo pipefail

# Fixtures are created with plain redirection, so their modes come from the ambient umask unless a scenario
# sets one on purpose. Ubuntu with user-private groups defaults to 002 and macOS to 022, which made the two
# platforms build DIFFERENT fixtures from the same line and test different things: install.sh refuses to
# rewrite a group-writable dotfile, so a ~/.bashrc scenario that meant to exercise the rewrite exercised the
# refusal instead, and only on Linux. Pin it. The scenarios that are about the mode chmod it themselves.
umask 022

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
OS="$(uname -s)"
WT="$REPO/bin/wt"
KEEP_LABEL="scratch repos"           # what lib_cleanup calls what KEEP=1 leaves behind
# shellcheck source=test/lib.sh
. "$REPO/test/lib.sh"

# The interpreter bin/wt itself is run under; see the header. Resolved to an absolute path here, once.
WT_BASH="${WT_BASH:-bash}"
WT_BASH_ABS="$(command -v "$WT_BASH" 2>/dev/null || true)"
if [[ -z "$WT_BASH_ABS" ]]; then
  echo "ABORT: WT_BASH='$WT_BASH' is not on PATH" >&2
  exit 1
fi
WT_BASH="$WT_BASH_ABS"
if ! command -v jq >/dev/null 2>&1; then
  echo "ABORT: jq is not on PATH; bin/wt refuses to run without it and so does this suite" >&2
  exit 1
fi

# Resolved before anything else runs: everything below compares against this.
REAL_HOME="$(cd "$HOME" && pwd -P)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wt-smoke.XXXXXX")"
TEST_ROOT_REAL="$(cd "$TEST_ROOT" && pwd -P)"
# …and from here on the physical path is the only one used. $TMPDIR on a Mac is a symlink, and bin/wt
# reports the physical path of everything it touches (main_root_of asks git for it, `wt rm` compares it
# with `pwd -P`), so a fixture built under the symlinked spelling would never compare equal to what wt
# printed — and a scenario that could only fail on a Mac is worse than no scenario.
TEST_ROOT="$TEST_ROOT_REAL"
case "$TEST_ROOT_REAL/" in
  "$REAL_HOME"/*)
    echo "ABORT: mktemp put the test root inside the real home ($TEST_ROOT_REAL); set TMPDIR elsewhere" >&2
    exit 1 ;;
esac
trap lib_cleanup EXIT

# ---------------------------------------------------------------------------- scratch root safety

# guard_scratch_root <dir>: the check this whole file is built around, and the first thing scenario 0
# proves. bin/wt runs `git worktree remove --force`, `git branch -D` and `rm -f` on paths it derives from
# its arguments, so a fixture built in the wrong place would be destroyed for real. Every repository, every
# worktree path and every fixture git call is passed through here first. Both sides are resolved with
# `pwd -P`, because $TMPDIR on a Mac is a symlink and a path that only LOOKS outside the home is no defence.
# Aborts the run outright — this is not a countable assertion failure.
guard_scratch_root() {
  local d="$1" resolved
  if [[ ! -d "$d" ]]; then
    echo "ABORT: scratch path '$d' is not a directory" >&2
    exit 1
  fi
  resolved="$(cd "$d" && pwd -P)"
  case "$resolved/" in
    "$REAL_HOME"/*)
      echo "ABORT: scratch path $resolved is inside the real home $REAL_HOME" >&2
      exit 1 ;;
  esac
  case "$resolved/" in
    "$TEST_ROOT_REAL"/*) : ;;
    *)
      echo "ABORT: scratch path $resolved is outside this run's scratch root $TEST_ROOT_REAL" >&2
      exit 1 ;;
  esac
}

SCRATCH_HOME="$TEST_ROOT/home"
REPOS_DIR="$TEST_ROOT/repos"          # $WT_REPOS_DIR for wt_run; a scenario may point it somewhere else
FAKE_BIN="$TEST_ROOT/bin"             # first on wt_run's PATH: the agent `wt run` starts lives here
CMUX_LOG="$TEST_ROOT/cmux-calls.log"  # every argv the cmux stub was called with, one per line
AGENT_LOG="$TEST_ROOT/agent-argv.log" # the argv `wt run` handed the agent
mkdir -p "$SCRATCH_HOME" "$REPOS_DIR" "$FAKE_BIN"

# ---------------------------------------------------------------------------- assertions
# describe, pass, fail, assert_eq, assert_grep, assert_link, assert_absent, assert_regular and
# assert_not_link are in test/lib.sh, sourced above. What follows is what only this suite needs.

# assert_has <what> <haystack> <fixed string>: the string is somewhere in the text. Fixed, never a pattern:
# every message this suite looks for contains a path, and a path is full of characters grep would read.
assert_has() {
  case "$2" in
    *"$3"*) pass ;;
    *) fail "$1: expected '$3' in the output, got: $(printf '%s' "$2" | tr '\n' '|' | cut -c1-200)" ;;
  esac
}

assert_dir() {   # <what> <path>
  if [[ -d "$2" ]]; then pass; else fail "$1: expected a directory at $2, found $(describe "$2")"; fi
}

assert_gone() {  # <what> <path> — nothing there at all
  if [[ -e "$2" || -L "$2" ]]; then fail "$1: expected $2 to be gone, found $(describe "$2")"; else pass; fi
}

assert_same_bytes() {  # <what> <file a> <file b>
  if [[ ! -f "$2" || ! -f "$3" ]]; then
    fail "$1: expected two regular files, found $(describe "$2") and $(describe "$3")"
    return 0
  fi
  if ! cmp -s "$2" "$3"; then
    fail "$1: $2 and $3 differ"
    return 0
  fi
  pass
}

assert_matches() {  # <what> <regex> <actual>
  if [[ "$3" =~ $2 ]]; then pass; else fail "$1: expected something matching /$2/, found '$3'"; fi
}

# assert_branch <repo> <branch> <yes|no>: whether that ref exists. `wt rm` deleting a branch, or declining
# to, is half of what it does, and the worktree directory says nothing about it.
assert_branch() {
  local have=no
  if fixture_git "$1" show-ref -q --verify "refs/heads/$2"; then have=yes; fi
  assert_eq "branch $2 in $(basename "$1")" "$3" "$have"
}

# assert_registered <repo> <name> <yes|no>: git's own worktree list, not just the directory. A worktree
# whose directory exists but whose registration is gone is a different animal, and require_wt says so.
assert_registered() {
  local p have=no
  p="$1/.worktrees/$2"
  if fixture_git "$1" worktree list --porcelain | grep -qxF "worktree $p"; then have=yes; fi
  assert_eq "$2 is registered in $(basename "$1")" "$3" "$have"
}

# assert_meta <repo> <name> <key> <value>: the sidecar every later command reads. A missing key reads as
# "(missing)" rather than "", because a key stored empty and a key that was never written are not the same
# bug: meta_get maps both to "" on purpose, and this is the one place that has to tell them apart.
assert_meta() {
  local f="$1/.git/wt/$2.json" got
  if [[ ! -f "$f" ]]; then
    fail "$2.json $3: expected '$4', but $f is $(describe "$f")"
    return 0
  fi
  got="$(jq -r --arg k "$3" 'if has($k) then (.[$k] | if type == "string" then . else tojson end)
                             else "(missing)" end' "$f")"
  assert_eq "$2.json $3" "$4" "$got"
}

assert_meta_matches() {  # <repo> <name> <key> <regex>
  local f="$1/.git/wt/$2.json" got
  if [[ ! -f "$f" ]]; then
    fail "$2.json $3: expected /$4/, but $f is $(describe "$f")"
    return 0
  fi
  got="$(jq -r --arg k "$3" 'if has($k) then (.[$k] | tostring) else "(missing)" end' "$f")"
  assert_matches "$2.json $3" "$4" "$got"
}

# assert_cmux_calls <what> <expected log>: every argv the stub was called with since the last stub_cmux,
# newline separated. The point is as much what is NOT there as what is: `wt new` against a cmux that is not
# running must ask `ping` and then give up, not go on to create rows.
assert_cmux_calls() {
  local got=""
  if [[ -f "$CMUX_LOG" ]]; then got="$(cat "$CMUX_LOG")"; fi
  assert_eq "$1" "$2" "$got"
}

# ---------------------------------------------------------------------------- fixtures

# fixture_git <repo> <git args…>: every git command this suite runs to BUILD a fixture, and the only one.
# It guards the path first, so no fixture step can reach a repository outside the scratch root, and it runs
# with the scratch HOME so the author's own git config cannot change what a fixture is — a global
# commit.gpgsign or core.hooksPath would otherwise decide whether these repositories can be committed to.
fixture_git() {
  local r="$1"
  shift
  guard_scratch_root "$r"
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT \
      HOME="$SCRATCH_HOME" XDG_CONFIG_HOME="$SCRATCH_HOME/.config" git -C "$r" "$@"
}

# fixture_commit <repo-or-worktree> <file> <text>: one commit, in whichever checkout it is pointed at.
fixture_commit() {
  printf '%s\n' "$3" >"$1/$2"
  fixture_git "$1" add -- "$2"
  fixture_git "$1" commit -q -m "$2"
}

# new_repo [name]: a throwaway repository under $REPOS_DIR with one commit on main. The identity and the
# default branch are set per repository rather than inherited, so nothing here depends on the machine.
# mktemp's suffix is alphanumeric, so the basename survives repo_id unchanged and the row title a scenario
# expects is just "<basename>:<name>" — scenario 3 tests the substitution rule separately.
new_repo() {
  local r
  r="$(mktemp -d "$REPOS_DIR/${1:-repo}-XXXXXX")"
  guard_scratch_root "$r"
  fixture_git "$r" init -q -b main
  fixture_git "$r" config user.name 'Smoke Test'
  fixture_git "$r" config user.email 'smoke@example.invalid'
  fixture_commit "$r" README 'a scratch repo'
  printf '%s\n' "$r"
}

# sha256_of <file>: computed here rather than through bin/wt's file_hash, which is the thing being checked.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

# The brief scenario 1 writes and reads back. Quotes, a '$', backticks, a backslash, a newline and
# non-ASCII: `wt new` writes it with printf '%s' and `wt run` reads it back with read -r -d '', and every
# one of those characters is a way for a shell to mangle a string it is only supposed to carry.
PROMPT_FIXTURE=$'first "line": $HOME `date` \'quoted\' back\\slash\nsecond line: café — ünïcode ✓'

# stub_cmux dead|alive: cmux_bin (bin/wt:~76) prefers $CMUX_BUNDLED_CLI_PATH when it is executable, so this
# is all it takes to decide what cmux_ok believes. "dead" logs its argv and exits 1, which is a cmux that is
# not running; "alive" answers ping 0 and serves $WT_ROWS for `workspace list --json`. Both truncate the log,
# so assert_cmux_calls always reads one scenario's worth.
CMUX_DEAD="$TEST_ROOT/cmux-dead/cmux"
CMUX_ALIVE="$TEST_ROOT/cmux-alive/cmux"
WT_STUB="$CMUX_DEAD"
WT_ROWS="$TEST_ROOT/rows.json"
WT_WINDOWS="$TEST_ROOT/windows.txt"          # what `cmux list-windows` prints; empty = a one-window cmux
WT_ROWS_DIR="$TEST_ROOT/rows-by-window"      # <window uuid>.json: the rows `workspace list --window` serves
mkdir -p "$(dirname "$CMUX_DEAD")" "$(dirname "$CMUX_ALIVE")" "$WT_ROWS_DIR"
cat >"$CMUX_DEAD" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CMUX_STUB_LOG"
exit 1
STUB
cat >"$CMUX_ALIVE" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CMUX_STUB_LOG"
if [ "$1" = ping ]; then exit 0; fi
if [ "$1" = list-windows ]; then
  if [ -s "$CMUX_STUB_WINDOWS" ]; then cat "$CMUX_STUB_WINDOWS"; fi
  exit 0
fi
if [ "$1" = workspace ] && [ "$2" = list ]; then
  w=""; prev=""
  for a in "$@"; do if [ "$prev" = --window ]; then w="$a"; fi; prev="$a"; done
  if [ -z "$w" ]; then cat "$CMUX_STUB_ROWS"
  elif [ -f "$CMUX_STUB_ROWS_DIR/$w.json" ]; then cat "$CMUX_STUB_ROWS_DIR/$w.json"
  else echo '{"workspaces":[]}'
  fi
  exit 0
fi
echo "workspace:99"
exit 0
STUB
chmod +x "$CMUX_DEAD" "$CMUX_ALIVE"
printf '{"workspaces":[]}\n' >"$WT_ROWS"
stub_cmux() {
  case "$1" in
    dead)  WT_STUB="$CMUX_DEAD" ;;
    alive) WT_STUB="$CMUX_ALIVE" ;;
    *) echo "ABORT: stub_cmux takes dead or alive, not '$1'" >&2; exit 1 ;;
  esac
  : >"$CMUX_LOG"
  # back to a one-window cmux; stub_windows opts in again. Guarded like every other path this suite
  # destroys: this is the only rm in the file that takes a glob, and the header promises all of them go
  # through guard_scratch_root before anything is removed.
  : >"$WT_WINDOWS"; guard_scratch_root "$WT_ROWS_DIR"; rm -f "$WT_ROWS_DIR"/*.json
}

# stub_windows <window uuid…>: what `cmux list-windows` prints, in cmux's own format, and an empty row list
# for each window named. A scenario then fills "$WT_ROWS_DIR/<uuid>.json" for the window it cares about.
# Called after stub_cmux, which resets this: with no call, list-windows prints nothing, rows_json falls back
# to the single-window call it made before windows were merged, and every other scenario sees the same cmux
# it always saw. The uuids must LOOK like uuids — rows_json takes only uuid-shaped fields from that output,
# so that a cmux which prints something else entirely is treated as one that cannot be enumerated.
stub_windows() {
  local u i=0
  : >"$WT_WINDOWS"
  for u in "$@"; do
    printf '  %d: %s selected_workspace=%s workspaces=0\n' "$i" "$u" "$u" >>"$WT_WINDOWS"
    printf '{"workspaces":[]}\n' >"$WT_ROWS_DIR/$u.json"
    i=$((i + 1))
  done
}

# The agent `wt run` starts. It is first on wt_run's PATH so the real claude can never be reached, and it
# records its argv, which is the only way to see that the brief survived the round trip.
cat >"$FAKE_BIN/claude" <<'AGENT'
#!/bin/sh
printf '%s\n' "$@" >"$AGENT_ARGV_LOG"
echo "FAKE-AGENT ran"
AGENT
chmod +x "$FAKE_BIN/claude"

# ---------------------------------------------------------------------------- running bin/wt

# wt_run <args…>: the only place bin/wt is ever invoked. Sets WT_OUT (stdout and stderr together, because
# every refusal this suite reads is on stderr) and WT_RC; never fails the caller, so `set -e` cannot end the
# run at the first non-zero exit — a non-zero exit is usually the assertion.
#   HOME is a scratch directory: cmux_bin falls back to $HOME/.cmux/bin/cmux, open_workspace builds a
#   command out of $HOME/.local/bin/wt and repo_menu prints paths relative to it.
#   GIT_CONFIG_GLOBAL/SYSTEM/COUNT are unset because any of them would override HOME for every `git config`
#   and every `git -C` bin/wt runs, and reach the author's own config through it.
#   CMUX_SSH_ATTEMPT_ID and CMUX_SOCKET_PATH are unset because is_remote() reads both, and this suite runs
#   inside a cmux pane that sets them — with either one inherited, every `wt new` would take the VM branch.
#   CMUX_WORKSPACE_ID is unset because relay_env would otherwise address a real row on this machine.
#   WT_AGENT, WT_AGENT_ARGS and WT_HOST are unset because the author's shell exports them and each one
#   changes what `wt new` records or which branch `wt new` takes.
#   CODEX_SANDBOX is pinned to $WT_SANDBOX, empty unless a scenario sets it: Codex sets it inside its
#   sandbox, and `wt open` refuses there — so a run of this suite from a Codex session would fail otherwise.
#   stdin is /dev/null so nothing can block on a read.
WT_OUT=""
WT_RC=0
WT_CWD=""          # where the next wt_run runs; empty means the scratch root, which is not a git repo
WT_SANDBOX=""      # CODEX_SANDBOX for the next wt_run; empty means not inside Codex's sandbox
wt_run() {
  WT_RC=0
  WT_OUT="$(cd "${WT_CWD:-$TEST_ROOT}" \
    && env -u CMUX_SSH_ATTEMPT_ID -u CMUX_SOCKET_PATH -u CMUX_WORKSPACE_ID \
           -u WT_AGENT -u WT_AGENT_ARGS -u WT_HOST \
           -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT \
           HOME="$SCRATCH_HOME" XDG_CONFIG_HOME="$SCRATCH_HOME/.config" \
           WT_REPOS_DIR="$REPOS_DIR" CMUX_BUNDLED_CLI_PATH="$WT_STUB" \
           CMUX_STUB_LOG="$CMUX_LOG" CMUX_STUB_ROWS="$WT_ROWS" AGENT_ARGV_LOG="$AGENT_LOG" \
           CMUX_STUB_WINDOWS="$WT_WINDOWS" CMUX_STUB_ROWS_DIR="$WT_ROWS_DIR" \
           CODEX_SANDBOX="$WT_SANDBOX" PATH="$FAKE_BIN:$PATH" \
           "$WT_BASH" "$WT" "$@" 2>&1 </dev/null)" || WT_RC=$?
  return 0
}

# assert_wt_ok <what> <args…>: run it and fail loudly, with the output, if it did not exit 0.
assert_wt_ok() {
  local what="$1"
  shift
  wt_run "$@"
  if [[ $WT_RC -ne 0 ]]; then
    fail "$what: wt $* exited $WT_RC, expected 0; output follows:"
    printf '%s\n' "$WT_OUT" | sed 's/^/      | /' >&2
    return 1
  fi
  pass
}

# assert_wt_fails <expected rc> <fixed string> <args…>: the other half. Every refusal bin/wt makes is
# supposed to be made BEFORE it changes anything, so each caller also asserts that nothing moved; that is
# the half a mutation deleting a guard would otherwise pass.
assert_wt_fails() {
  local want="$1" msg="$2"
  shift 2
  wt_run "$@"
  assert_eq "wt $* exit status" "$want" "$WT_RC"
  assert_has "wt $* said why it refused" "$WT_OUT" "$msg"
}

# refuses <repo> <name> <fixed string>: `wt rm` refuses with 3, names the reason, and the worktree is still
# there. Three assertions, and the third is the one that matters.
refuses() {
  assert_wt_fails 3 "$3" rm "$2" -r "$1"
  assert_dir "wt rm $2 left the worktree alone" "$1/.worktrees/$2"
}

# forced <repo> <name>: --force is the one deliberate way past every reason above.
forced() {
  assert_wt_ok "wt rm --force $2" rm "$2" -r "$1" --force
  assert_gone "wt rm --force $2 removed the worktree" "$1/.worktrees/$2"
}

# wt_line <name>: the columns wt list printed for one worktree, whitespace normalised, without the
# relative-time column (which has spaces in it and says nothing this suite can pin down).
wt_line() {
  printf '%s\n' "$WT_OUT" | awk -v n="$1" '$1 == n { print $1, $2, $3, $4, $5, $6; exit }'
}

# ---------------------------------------------------------------------------- scenarios

# 0. The guard, first, because every other scenario trusts it. Each branch is provoked in a subshell: the
# guard aborts the run, so a caller that wants to see it refuse cannot be in the same shell.
scenario_guard() {
  begin_scenario "0. guard_scratch_root refuses anything outside this run's scratch root"
  local out rc
  mkdir -p "$TEST_ROOT/fakehome/inner"

  rc=0; out="$( (REAL_HOME="$TEST_ROOT_REAL/fakehome"; guard_scratch_root "$TEST_ROOT_REAL/fakehome/inner") 2>&1 )" || rc=$?
  assert_eq "a path under the real home aborts" 1 "$rc"
  assert_has "…and says so" "$out" "is inside the real home"

  rc=0; out="$(guard_scratch_root /tmp 2>&1)" || rc=$?
  assert_eq "a path outside the scratch root aborts" 1 "$rc"
  assert_has "…and says so" "$out" "outside this run's scratch root"

  rc=0; out="$(guard_scratch_root "$TEST_ROOT/no-such-thing" 2>&1)" || rc=$?
  assert_eq "a path that is not a directory aborts" 1 "$rc"
  assert_has "…and says so" "$out" "is not a directory"

  rc=0; out="$(guard_scratch_root "$TEST_ROOT/fakehome" 2>&1)" || rc=$?
  assert_eq "a real scratch path is allowed" 0 "$rc"
  assert_eq "…silently" "" "$out"
  end_scenario
}

# 1. What `wt new` makes, and the sidecar every later command reads back.
scenario_new_and_sidecar() {
  begin_scenario "1. wt new: the worktree, the branch, the sidecar and the brief"
  local r id p
  r="$(new_repo new)"
  id="$(basename "$r")"
  p="$r/.worktrees/demo"

  stub_cmux dead
  assert_wt_ok "wt new demo" new demo --no-workspace -r "$r" -p "$PROMPT_FIXTURE"
  assert_dir "the worktree directory" "$p"
  assert_branch "$r" wt/demo yes
  assert_registered "$r" demo yes
  assert_has "wt new said what it made" "$WT_OUT" "created demo"

  assert_meta "$r" demo base main
  assert_meta "$r" demo agent claude
  assert_meta "$r" demo title "$id:demo"
  assert_meta "$r" demo session "wt-$id-demo"
  assert_meta "$r" demo includes ""
  assert_meta_matches "$r" demo created '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

  # the brief, byte for byte: printf '%s' writes it with no trailing newline, and that is what `wt run`
  # reads back with `read -r -d ''`
  printf '%s' "$PROMPT_FIXTURE" >"$TEST_ROOT/expected.prompt"
  assert_same_bytes "the .prompt file" "$TEST_ROOT/expected.prompt" "$r/.git/wt/demo.prompt"
  assert_absent "$r/.git/wt" demo.started

  # `wt run` is what creates .started, and what hands the brief to the agent
  rm -f "$AGENT_LOG"
  assert_wt_ok "wt run demo" run demo -r "$r"
  assert_has "wt run started the agent on this suite's PATH" "$WT_OUT" "FAKE-AGENT ran"
  assert_regular "$r/.git/wt" demo.started
  assert_eq "the agent got '-- <brief>'" "$(printf -- '--\n%s' "$PROMPT_FIXTURE")" "$(cat "$AGENT_LOG")"

  # …and the second run resumes instead of replaying the brief, because .started exists now
  rm -f "$AGENT_LOG"
  assert_wt_ok "wt run demo again" run demo -r "$r"
  assert_eq "the second run resumes with -c" "-c" "$(cat "$AGENT_LOG")"
  end_scenario
}

# 2. Base resolution and canonicalisation. bin/wt spends six lines of comment on this: a base that
# re-resolves in every worktree to that worktree's own tip compares a worktree with itself, and rm and
# prune then read it as "nothing to lose". Nothing checked it until now.
scenario_base_resolution() {
  begin_scenario "2. wt new: the base is canonicalised, so rm and prune can trust it"
  local r sha
  r="$(new_repo base)"
  sha="$(fixture_git "$r" rev-parse main)"
  stub_cmux dead

  assert_wt_ok "wt new b-default" new b-default --no-workspace -r "$r"
  assert_meta "$r" b-default base main          # a plain ref name means the same thing in every worktree

  # every spelling of "wherever this worktree is" is pinned to the commit it meant at creation
  assert_wt_ok "wt new -b HEAD" new b-head --no-workspace -r "$r" -b HEAD
  assert_meta "$r" b-head base "$sha"
  assert_wt_ok "wt new -b @" new b-at --no-workspace -r "$r" -b '@'
  assert_meta "$r" b-at base "$sha"
  assert_wt_ok "wt new -b @{0}" new b-reflog --no-workspace -r "$r" -b '@{0}'
  assert_meta "$r" b-reflog base "$sha"
  assert_wt_ok "wt new -b main~0" new b-expr --no-workspace -r "$r" -b 'main~0'
  assert_meta "$r" b-expr base "$sha"

  # …while a plain ref name is kept AS a ref, because that is the one thing that still means the same
  # branch tomorrow
  fixture_git "$r" branch feature main
  assert_wt_ok "wt new -b feature" new b-ref --no-workspace -r "$r" -b feature
  assert_meta "$r" b-ref base feature

  # --head is this checkout's HEAD: its branch, or its commit when HEAD is detached
  fixture_git "$r" switch -q --detach "$sha"
  WT_CWD="$r"
  assert_wt_ok "wt new --head from a detached HEAD" new b-detached --head --no-workspace
  assert_meta "$r" b-detached base "$sha"

  # The regression this guards: from a DETACHED checkout `git rev-parse --symbolic-full-name HEAD` prints
  # the bare word "HEAD", which used to match the "it is already a plain ref" arm — so the literal "HEAD",
  # the one value the comment above that case says must never be stored, was stored after all. rm_reasons
  # caught it downstream, so nothing was destroyed, but the worktree was unremovable without --force.
  assert_wt_ok "wt new -b HEAD from a detached HEAD" new b-literal --no-workspace -b HEAD
  assert_meta "$r" b-literal base "$sha"
  WT_CWD=""
  fixture_git "$r" switch -q main
  assert_wt_ok "…and the worktree it made is removable" rm b-literal -r "$r"

  assert_wt_fails 1 "base ref not found: nosuch" new b-bad --no-workspace -r "$r" -b nosuch
  assert_gone "a base that does not resolve makes nothing" "$r/.worktrees/b-bad"

  # git allows '|' in a branch name, and a base like 'feat|x' used to shift every column of the status
  # line right; WT_FS is why it does not any more
  fixture_git "$r" branch 'feat|x' main
  assert_wt_ok "wt new -b 'feat|x'" new b-pipe --no-workspace -r "$r" -b 'feat|x'
  assert_meta "$r" b-pipe base 'feat|x'
  assert_wt_ok "wt list" list -r "$r"
  assert_eq "a base with a '|' keeps wt list's columns straight" "b-pipe wt/b-pipe feat|x 0 0 0" "$(wt_line b-pipe)"
  assert_wt_ok "wt show b-pipe" show b-pipe -r "$r"
  assert_has "…and wt show's too" "$WT_OUT" "(+0 / -0 vs feat|x)"
  end_scenario
}

# 3. Names: what is tidied, what is generated, what is refused, and what is already taken.
scenario_names_and_collisions() {
  begin_scenario "3. wt new: tidied names, generated names, refused names, taken names"
  local r name long
  r="$(new_repo names)"
  stub_cmux dead

  assert_wt_ok "wt new 'Fix Auth'" new 'Fix Auth' --no-workspace -r "$r"
  assert_has "tidy_name lowercases and joins on whitespace" "$WT_OUT" "created fix-auth"
  assert_dir "…and that is the directory it made" "$r/.worktrees/fix-auth"

  # Deliberate: an uppercase name is tidied, not refused — need_name never sees the original. `wt new
  # "Fix Auth"` is a natural thing to type, and tidy_name runs on the reading side too (the task picker),
  # so the capitalised spelling still finds the worktree. Only git and tmux see the lowercase name.
  assert_wt_ok "wt new ABC" new ABC --no-workspace -r "$r"
  assert_has "an uppercase name is lowercased rather than refused" "$WT_OUT" "created abc"

  assert_wt_ok "wt new with only a brief" new --no-workspace -r "$r" -p 'Add OAuth login, please!'
  assert_has "the name is slugified from the brief" "$WT_OUT" "created add-oauth-login-please"
  assert_wt_ok "wt new with a long brief" new --no-workspace -r "$r" -p 'one two three four five six seven'
  assert_has "…cut to five words" "$WT_OUT" "created one-two-three-four-five"

  assert_wt_ok "wt new with neither" new --no-workspace -r "$r"
  name="$(printf '%s\n' "$WT_OUT" | sed -n 's/^created //p')"
  assert_matches "no name and no brief falls back to a timestamp" '^task-[0-9]{8}-[0-9]{6}$' "$name"
  assert_dir "…and makes it" "$r/.worktrees/$name"

  assert_wt_fails 1 "invalid name 'a.b'" new 'a.b' --no-workspace -r "$r"
  assert_gone "a refused name makes nothing" "$r/.worktrees/a.b"
  assert_wt_fails 1 "new: unknown option -x" new -x --no-workspace -r "$r"
  long="$(printf '%064d' 0 | tr 0 a)"
  assert_wt_fails 1 "invalid name" new "$long" --no-workspace -r "$r"
  assert_wt_ok "63 characters is still a name" new "${long%a}" --no-workspace -r "$r"

  assert_wt_ok "wt new dup" new dup --no-workspace -r "$r"
  assert_wt_fails 1 "worktree 'dup' already exists" new dup --no-workspace -r "$r"
  fixture_git "$r" branch wt/ghost main
  assert_wt_fails 1 "branch wt/ghost already exists" new ghost --no-workspace -r "$r"
  assert_gone "…and the worktree a taken branch would have needed is not made" "$r/.worktrees/ghost"
  end_scenario
}

# 4. The read-only commands. --json was removed in b317fbc; it must now be refused like any other
# unknown option rather than silently ignored.
scenario_list_show_path() {
  begin_scenario "4. wt list / show / path / open"
  local saved="$REPOS_DIR" ra rb base
  REPOS_DIR="$TEST_ROOT/two-repos"        # --all walks every repo on the search path, so give it exactly two
  mkdir -p "$REPOS_DIR"
  ra="$(new_repo alpha)"
  rb="$(new_repo bravo)"
  stub_cmux dead
  assert_wt_ok "wt new a1" new a1 --no-workspace -r "$ra"
  assert_wt_ok "wt new b1" new b1 --no-workspace -r "$rb"

  assert_wt_ok "wt list" list -r "$ra"
  assert_eq "the columns" "NAME BRANCH BASE AHEAD BEHIND DIRTY LAST" \
            "$(printf '%s\n' "$WT_OUT" | awk '$1 == "NAME" { $1 = $1; print; exit }')"
  assert_eq "the row" "a1 wt/a1 main 0 0 0" "$(wt_line a1)"
  assert_eq "one repo means one repo" "1" \
            "$(printf '%s\n' "$WT_OUT" | grep -c '^[^ ].*  (' || true)"

  assert_wt_ok "wt list --all" list --all
  assert_eq "--all walks both repos on the search path" "2" \
            "$(printf '%s\n' "$WT_OUT" | grep -c '^[^ ].*  (' || true)"
  assert_eq "…the first repo's task" "a1 wt/a1 main 0 0 0" "$(wt_line a1)"
  assert_eq "…and the second repo's" "b1 wt/b1 main 0 0 0" "$(wt_line b1)"

  assert_wt_ok "wt path a1" path a1 -r "$ra"
  assert_eq "wt path prints the worktree path" "$ra/.worktrees/a1" "$WT_OUT"
  assert_wt_fails 1 "no worktree named 'nosuch'" path nosuch -r "$ra"
  assert_wt_fails 1 "show: worktree name required" show -r "$ra"
  assert_wt_fails 1 "not inside a git repo" list

  assert_wt_fails 1 "list: unknown option --json" list --json -r "$ra"
  assert_wt_fails 1 "show: unknown option --json" show a1 --json -r "$ra"

  # a worktree whose HEAD is detached at the BASE while its branch is one commit ahead: the counts are
  # supposed to be the branch's, not HEAD's — HEAD's would read 0 and call this nothing to lose
  assert_wt_ok "wt new det" new det --no-workspace -r "$ra"
  base="$(fixture_git "$ra" rev-parse main)"
  fixture_commit "$ra/.worktrees/det" work.txt 'one commit ahead'
  fixture_git "$ra/.worktrees/det" switch -q --detach "$base"
  assert_wt_ok "wt show det" show det -r "$ra"
  assert_has "wt show says the HEAD is detached" "$WT_OUT" "wt/det (HEAD detached)"
  assert_has "…and counts against the branch, not HEAD" "$WT_OUT" "(+1 / -0 vs main)"
  assert_wt_ok "wt list" list -r "$ra"
  assert_eq "wt list agrees" "det wt/det (HEAD detached) main 1" "$(wt_line det)"
  if [[ $OS == Darwin ]]; then
    # DARWIN-ONLY: is_remote() is true anywhere else, and wt show then adds a session: line by asking tmux
    assert_eq "no session line on the Mac side" "0" \
              "$(printf '%s\n' "$WT_OUT" | grep -c 'session:' || true)"
    # …and wt open is the one command here that launches an app, so it must not claim a launch that did not
    # happen. The stub `code` is first on PATH, so the real VS Code is never started. It exits 0 first,
    # which is what the real one does inside Codex's sandbox while no window opens.
    printf '#!/bin/sh\nexit 0\n' >"$FAKE_BIN/code"
    chmod +x "$FAKE_BIN/code"
    WT_SANDBOX=seatbelt
    assert_wt_fails 1 "the Codex sandbox blocks app launches" open a1 -r "$ra"
    assert_eq "…and does not claim VS Code opened" "0" \
              "$(printf '%s\n' "$WT_OUT" | grep -c 'opened in VS Code' || true)"
    WT_SANDBOX=""
    assert_wt_ok "wt open outside the sandbox" open a1 -r "$ra"
    assert_has "…says it opened" "$WT_OUT" "opened in VS Code: $ra/.worktrees/a1"
    printf '#!/bin/sh\necho "launch refused" >&2\nexit 7\n' >"$FAKE_BIN/code"
    assert_wt_fails 1 "VS Code did not open $ra/.worktrees/a1: code exited 7: launch refused" open a1 -r "$ra"
    rm -f "$FAKE_BIN/code"
  fi
  REPOS_DIR="$saved"
  end_scenario
}

# 5. The two per-repo hooks.
scenario_include_and_setup() {
  begin_scenario "5. .wt-include copies ignored files; .wt-setup runs in the new worktree"
  local r p
  r="$(new_repo hooks)"
  printf '%s\n' '.env' '*.log' >"$r/.gitignore"
  fixture_git "$r" add .gitignore
  fixture_git "$r" commit -q -m gitignore
  printf 'SECRET=1\n' >"$r/.env"
  printf 'noise\n' >"$r/other.log"
  printf '%s\n' '.env' >"$r/.wt-include"
  # the hook writes to a gitignored name here on purpose, so that this half tests the hook and nothing else;
  # a hook that dirties the worktree is the last block of this scenario, and scenario 6 has dirt on its own
  # shellcheck disable=SC2016   # the hook is a script: those are for it to expand, not for this file
  printf '%s\n' '#!/bin/sh' 'printf "%s %s\n" "$WT_NAME" "$WT_REPO" >setup-ran.log' >"$r/.wt-setup"
  chmod +x "$r/.wt-setup"
  stub_cmux dead

  p="$r/.worktrees/inc"
  assert_wt_ok "wt new inc" new inc --no-workspace -r "$r"
  assert_same_bytes "an ignored file .wt-include names is copied in" "$r/.env" "$p/.env"
  assert_meta "$r" inc includes ".env:$(sha256_of "$p/.env")"
  assert_gone "an ignored file it does not name is not" "$p/other.log"
  assert_regular "$p" setup-ran.log
  assert_eq ".wt-setup ran in the worktree with WT_NAME and WT_REPO set" "inc $r" \
            "$(cat "$p/setup-ran.log")"

  # an untouched copy is not a reason to refuse: it is still byte-identical to what was recorded
  assert_wt_ok "wt rm inc" rm inc -r "$r"
  assert_gone "…so the worktree goes" "$p"

  printf '%s\n' '#!/bin/sh' 'exit 7' >"$r/.wt-setup"
  assert_wt_ok "a .wt-setup that fails does not fail the creation" new badsetup --no-workspace -r "$r"
  assert_has "…it warns" "$WT_OUT" ".wt-setup exited non-zero"
  assert_dir "…and the worktree is there" "$r/.worktrees/badsetup"

  # A hook that rewrites a TRACKED file — `uv sync`, `npm ci`, anything that regenerates a committed
  # lockfile — leaves the worktree dirty from birth. What the hook wrote is hashed into the sidecar at
  # creation and subtracted from rm's dirty count, because otherwise every worktree in such a repo would be
  # unremovable for its whole life and --force, which also discards unmerged commits, would be the only way
  # to tidy up. The subtraction is by content, not by name: the file is excused only while it still holds
  # exactly what the hook left in it.
  printf 'lock v1\n' >"$r/lock.txt"
  fixture_git "$r" add lock.txt
  fixture_git "$r" commit -q -m lock
  printf '%s\n' '#!/bin/sh' 'printf "lock v2\n" >lock.txt' >"$r/.wt-setup"
  p="$r/.worktrees/relock"
  assert_wt_ok "wt new relock, whose .wt-setup rewrites a tracked file" new relock --no-workspace -r "$r"
  assert_meta "$r" relock setup "lock.txt:$(sha256_of "$p/lock.txt")"
  assert_wt_ok "what .wt-setup itself wrote is not a reason to refuse" rm relock -r "$r"
  assert_gone "…so the worktree goes" "$p"

  assert_wt_ok "wt new relock again" new relock --no-workspace -r "$r"
  printf 'my own work\n' >>"$p/lock.txt"
  refuses "$r" relock "1 uncommitted change(s)"      # an edit on top of the hook's output is real work
  printf 'lock v2\n' >"$p/lock.txt"
  assert_wt_ok "putting it back byte for byte makes it removable again" rm relock -r "$r"
  end_scenario
}

# 6. The refusals. Every branch of rm_reasons, each one a way to lose work that `git worktree remove
# --force` would take without a word. If one of these stops firing, that is a data-loss regression and the
# test is right and the code is wrong.
scenario_rm_refusals() {
  begin_scenario "6. wt rm refuses to destroy work, and --force is the one way past it"
  local r ri p side
  r="$(new_repo rm)"
  stub_cmux dead

  # a) uncommitted changes
  assert_wt_ok "wt new dirty" new dirty --no-workspace -r "$r"
  printf 'unsaved\n' >"$r/.worktrees/dirty/scratch.txt"
  refuses "$r" dirty "1 uncommitted change(s)"

  # b) commits that are neither merged into the base nor still on a remote
  assert_wt_ok "wt new commits" new commits --no-workspace -r "$r"
  fixture_commit "$r/.worktrees/commits" work.txt 'worth keeping'
  refuses "$r" commits "1 commit(s) on wt/commits not merged into main and not on a remote"

  # c) a detached HEAD: a bisect or a `git checkout <sha>` that removing the worktree throws away
  assert_wt_ok "wt new det" new det --no-workspace -r "$r"
  fixture_git "$r/.worktrees/det" switch -q --detach HEAD
  refuses "$r" det "HEAD is detached at"

  # d) a HEAD that is some other branch: the checks above are all about wt/<name>, so this is its own reason
  assert_wt_ok "wt new other" new other --no-workspace -r "$r"
  fixture_git "$r/.worktrees/other" switch -q -c sidebranch
  refuses "$r" other "HEAD is on sidebranch, not wt/other"

  # e) a base that no longer resolves: it fails the merged check and the ahead count, and each failure
  # reads as "nothing to lose"
  fixture_git "$r" branch tmpbase main
  assert_wt_ok "wt new gonebase" new gonebase --no-workspace -r "$r" -b tmpbase
  fixture_git "$r" branch -D tmpbase >/dev/null
  refuses "$r" gonebase "base 'tmpbase' cannot be compared with wt/gonebase"

  # f) an .wt-include copy edited inside the worktree: in no git, in no backup, and `worktree remove
  # --force` eats it without a word
  ri="$(new_repo include)"
  printf '%s\n' '.env' >"$ri/.gitignore"
  fixture_git "$ri" add .gitignore
  fixture_git "$ri" commit -q -m gitignore
  printf 'SECRET=1\n' >"$ri/.env"
  printf '%s\n' '.env' >"$ri/.wt-include"
  assert_wt_ok "wt new edited" new edited --no-workspace -r "$ri"
  printf 'SECRET=2\n' >"$ri/.worktrees/edited/.env"
  refuses "$ri" edited ".env was edited or created inside the worktree"

  # --force is the one deliberate way past each of them
  forced "$r" dirty
  forced "$r" commits
  forced "$r" det
  forced "$r" other
  forced "$r" gonebase
  forced "$ri" edited

  # you are standing in it
  assert_wt_ok "wt new inside" new inside --no-workspace -r "$r"
  WT_CWD="$r/.worktrees/inside"
  assert_wt_fails 1 "you are inside inside; cd out first" rm inside -r "$r"
  WT_CWD=""
  assert_dir "…and it is still there" "$r/.worktrees/inside"

  # --keep-branch removes the worktree and says what it kept
  assert_wt_ok "wt rm --keep-branch" rm inside -r "$r" --keep-branch
  assert_has "…and says the branch was kept" "$WT_OUT" "removed inside (branch wt/inside kept)"
  assert_branch "$r" wt/inside yes

  # git's own merged-check is the last line of defence behind the reasons above: this branch is merged into
  # its BASE (so nothing refuses) but not into the main checkout's HEAD, and `branch -d` declines. The
  # worktree goes; the branch is kept, and said to be kept.
  side="$r/.worktrees/kept"
  fixture_git "$r" branch side main
  assert_wt_ok "wt new kept -b side" new kept --no-workspace -r "$r" -b side
  fixture_commit "$side" kept.txt 'merged into side, not into main'
  fixture_git "$r" update-ref refs/heads/side "$(fixture_git "$r" rev-parse wt/kept)"
  assert_wt_ok "wt rm kept" rm kept -r "$r"
  assert_has "git would not call the branch merged, so wt keeps it" "$WT_OUT" \
             "kept branch wt/kept: git will not delete it as merged"
  assert_has "…and says so in what it printed" "$WT_OUT" "removed kept (branch wt/kept kept)"
  assert_gone "…the worktree still goes" "$side"
  assert_branch "$r" wt/kept yes
  end_scenario
}

# 7. rm_reasons has two callers and bin/wt's comment says "the two can never disagree". Nothing checked it.
scenario_prune_agrees() {
  begin_scenario "7. wt prune --dry-run keeps exactly what wt rm refuses"
  local r n verdict want
  r="$(new_repo prune)"
  stub_cmux dead

  assert_wt_ok "wt new clean" new clean --no-workspace -r "$r"
  assert_wt_ok "wt new dirty" new dirty --no-workspace -r "$r"
  printf 'unsaved\n' >"$r/.worktrees/dirty/scratch.txt"
  assert_wt_ok "wt new commits" new commits --no-workspace -r "$r"
  fixture_commit "$r/.worktrees/commits" work.txt 'worth keeping'
  assert_wt_ok "wt new det" new det --no-workspace -r "$r"
  fixture_git "$r/.worktrees/det" switch -q --detach HEAD
  fixture_git "$r" branch tmpbase main
  assert_wt_ok "wt new gonebase" new gonebase --no-workspace -r "$r" -b tmpbase
  fixture_git "$r" branch -D tmpbase >/dev/null

  assert_wt_ok "wt prune --dry-run" prune --dry-run -r "$r"
  local dry="$WT_OUT"
  assert_eq "a dry run removes nothing" "5" \
            "$(find "$r/.worktrees" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

  for n in clean dirty commits det gonebase; do
    verdict=keep
    case "$n" in clean) verdict=would-remove ;; esac
    if [[ "$verdict" == keep ]]; then want="keep $n ("; else want="would remove $n ("; fi
    assert_has "prune's verdict on $n" "$dry" "$want"
    wt_run rm "$n" -r "$r"
    if [[ "$verdict" == keep ]]; then
      assert_eq "wt rm $n agrees with prune" 3 "$WT_RC"
    else
      assert_eq "wt rm $n agrees with prune" 0 "$WT_RC"
    fi
  done
  end_scenario
}

# 8. cmux. DARWIN-ONLY, all of it: is_remote() is true on anything that is not a Mac, and on that side
# `wt new` asks the Mac for a row through the relay instead of talking to cmux at all, and check_identity
# asks tmux rather than the row list. See DARWIN_ASSERTIONS.
scenario_cmux() {
  begin_scenario "8. a cmux that is not running, and one that is"
  if [[ $OS != Darwin ]]; then
    end_scenario
    return 0
  fi
  local r id
  r="$(new_repo cmux)"
  id="$(basename "$r")"

  # not running: the worktree is still made, the row is not, and nothing but `ping` is asked
  stub_cmux dead
  assert_wt_ok "wt new ws, cmux down" new ws -r "$r"
  assert_has "…it says the row was skipped" "$WT_OUT" "cmux is not running; skipped workspace creation"
  assert_dir "…and the worktree is there anyway" "$r/.worktrees/ws"
  assert_cmux_calls "…and cmux was only ever asked whether it is there" "$(printf 'ping\nping')"

  # running, and the row title this name would take belongs to another repo
  stub_cmux alive
  cat >"$WT_ROWS" <<ROWS
{"workspaces":[
  {"id":"workspace:1","title":"$id:taken","description":"@local","current_directory":"$REPOS_DIR"}
]}
ROWS
  assert_wt_fails 1 "row '$id:taken' already belongs to" new taken --no-workspace -r "$r"
  assert_gone "…and refuses before it makes anything" "$r/.worktrees/taken"

  # two rows share a title; only the host tells them apart, and with no host asked for it is the local row
  # that answers. Here the local row is this repo's own, so the name is free.
  cat >"$WT_ROWS" <<ROWS
{"workspaces":[
  {"id":"workspace:1","title":"$id:dup","description":"@vm1",
   "remote":{"enabled":true,"destination":"vm1"},"current_directory":"$REPOS_DIR"},
  {"id":"workspace:2","title":"$id:dup","description":"@local","current_directory":"$r"}
]}
ROWS
  assert_wt_ok "the local row is the one consulted" new dup --no-workspace -r "$r"

  # …and the other way round, to show the @host row is not what answered above
  cat >"$WT_ROWS" <<ROWS
{"workspaces":[
  {"id":"workspace:1","title":"$id:swap","description":"@vm1",
   "remote":{"enabled":true,"destination":"vm1"},"current_directory":"$r"},
  {"id":"workspace:2","title":"$id:swap","description":"@local","current_directory":"$REPOS_DIR"}
]}
ROWS
  assert_wt_fails 1 "row '$id:swap' already belongs to" new swap --no-workspace -r "$r"
  assert_gone "…and again refuses before it makes anything" "$r/.worktrees/swap"

  # The same two lookups with the row sitting in a SECOND cmux window, which is how two tasks are put side
  # by side: a cmux window shows one workspace at a time. `workspace list --json` answers for one window, so
  # until rows_json merged them both assertions below quietly went the other way — the clash was not seen,
  # and `wt rm` closed no row while still reporting the worktree removed.
  local w1=AAAAAAAA-0000-0000-0000-00000000000A w2=BBBBBBBB-0000-0000-0000-00000000000B
  stub_cmux alive
  stub_windows "$w1" "$w2"
  printf '{"workspaces":[]}\n' >"$WT_ROWS"     # empty: a one-window list is what this scenario must NOT rely on
  cat >"$WT_ROWS_DIR/$w2.json" <<ROWS
{"workspaces":[
  {"id":"row-in-window-two","title":"$id:moved","description":"@local","current_directory":"$REPOS_DIR"}
]}
ROWS
  assert_wt_fails 1 "row '$id:moved' already belongs to" new moved --no-workspace -r "$r"
  assert_gone "…and makes nothing, though the row is in the other window" "$r/.worktrees/moved"
  assert_has "…having enumerated the windows to find it" "$(cat "$CMUX_LOG")" "list-windows"

  # and the row `wt rm` has to close is reached there too
  stub_cmux alive
  stub_windows "$w1" "$w2"
  printf '{"workspaces":[]}\n' >"$WT_ROWS"
  assert_wt_ok "a worktree whose row is in the other window" new elsewhere --no-workspace -r "$r"
  cat >"$WT_ROWS_DIR/$w2.json" <<ROWS
{"workspaces":[
  {"id":"row-in-window-two","title":"$id:elsewhere","description":"@local","current_directory":"$r"}
]}
ROWS
  assert_wt_ok "wt rm removes it" rm elsewhere -r "$r"
  assert_has "…and closed the row it could not have seen before" "$(cat "$CMUX_LOG")" \
             "workspace close row-in-window-two"

  # A cmux that cannot be enumerated — no list-windows, or output that is not a window list — must keep the
  # single-window behaviour rather than lose the lookup altogether. stub_cmux has just reset it to that.
  stub_cmux alive
  cat >"$WT_ROWS" <<ROWS
{"workspaces":[
  {"id":"workspace:1","title":"$id:onewin","description":"@local","current_directory":"$REPOS_DIR"}
]}
ROWS
  assert_wt_fails 1 "row '$id:onewin' already belongs to" new onewin --no-workspace -r "$r"
  stub_cmux dead
  end_scenario
}

# 9. `wt -H <host>`: the argument handling, and only that. Every case below returns from cmd_host or need_r
# BEFORE remote_sh is reached, so no host has to exist and nothing is sent anywhere — the host name is a
# .invalid one so that a case that ever did reach ssh would fail this suite rather than dial out.
scenario_host_args() {
  begin_scenario "9. wt -H: the checks that happen before any ssh"
  local h=smoke.invalid sub
  stub_cmux dead

  # -r is required, because a remote call has no cwd to infer a repo from
  for sub in show path attach open rm; do
    assert_wt_fails 1 "$sub: -r <repo> is required with -H" -H "$h" "$sub" x
  done

  # …and what it is given has to mean something on the other machine
  assert_wt_fails 1 "show: -r must be an absolute path on $h" -H "$h" show -r '' x
  assert_wt_fails 1 "show: -r must be an absolute path on $h" -H "$h" show -r . x
  assert_wt_fails 1 "show: -r must be an absolute path on $h" -H "$h" show -r .. x
  assert_wt_fails 1 "show: -r must be an absolute path on $h" -H "$h" show -r rel/path x
  # a trailing slash is normalised away rather than refused: it would otherwise change repo_id, and with it
  # the row title host_rm closes
  assert_wt_fails 1 "does not run remotely" -H "$h" badsub -r /abs/path/

  assert_wt_fails 1 "wt -H: 'badsub' does not run remotely" -H "$h" badsub
  assert_wt_fails 1 "invalid host '-bad'" -H -bad list
  assert_wt_fails 1 "usage: wt -H <host> <command>" -H "$h"

  # -h wins over the -r requirement: asking what a command takes must answer, not complain about an
  # argument it is asking about
  for sub in attach open rm new; do
    assert_wt_ok "wt -H $h $sub -h prints usage" -H "$h" "$sub" -h
    assert_has "…the usage, locally" "$WT_OUT" "wt new  [name]"
  done
  end_scenario
}

# 10. The invariants two files promise each other in comments and nothing enforced: bin/cmux-hook's copy
# of tmux_cmd must match bin/wt's line for line (the command is the one bin/cmux-hook's own comment gives), and
# the two must merge the per-window row lists identically.
scenario_shared_tmux_cmd() {
  begin_scenario "10. bin/wt and bin/cmux-hook agree on tmux_cmd and on the row list"
  local a b
  a="$(sed -n '/^tmux_cmd()/,/^}/p' "$REPO/bin/wt" | grep -v '^ *#')"
  b="$(sed -n '/^tmux_cmd()/,/^}/p' "$REPO/bin/cmux-hook" | grep -v '^ *#')"
  assert_has "bin/wt has a tmux_cmd" "$a" "tmux new-session"
  assert_has "bin/cmux-hook has one too" "$b" "tmux new-session"
  assert_eq "the two bodies are identical" "$a" "$b"
  # The second promise: rows_json in wt and ws_load in the hook both merge the per-window row lists, and a
  # row the two disagreed about would be one wt could act on and the hook could not, or the reverse. They
  # cannot share the body — the hook wraps every cmux call in its deadline — so what is compared is the jq
  # program that does the merging.
  a="$(sed -n "s/.*| jq -s -c '\(.*\)'.*/\1/p" "$REPO/bin/wt")"
  b="$(sed -n "s/.*| jq -s -c '\(.*\)'.*/\1/p" "$REPO/bin/cmux-hook")"
  assert_has "bin/wt merges the windows' row lists" "$a" "workspaces"
  assert_eq "bin/cmux-hook merges them the same way" "$a" "$b"
  # …and they must agree on which fields of `cmux list-windows` count as a window, for the same reason:
  # a pattern that matched in one file and not the other would give the two a different set of windows.
  a="$(sed -n "s/.*grep -Ex '\(.*\)'.*/\1/p" "$REPO/bin/wt")"
  b="$(sed -n "s/.*grep -Ex '\(.*\)'.*/\1/p" "$REPO/bin/cmux-hook")"
  assert_eq "the two take the same window uuids" "$a" "$b"
  end_scenario
}

# 11. lib_cleanup's backstop, which no real run reaches: both suites build $TEST_ROOT with mktemp -d and
# refuse one inside the real home before arming the trap, so the refusal below only ever fires for a suite
# that did neither — and a branch nothing exercises is a branch nobody knows is broken. Both cases are
# played out on directories inside this run's own scratch root, with HOME pointed at one of them, so
# nothing outside it is so much as named even if the guard were wrong.
# shellcheck disable=SC2016   # the $1 in the bash -c program is for THAT bash to expand, not this file
scenario_cleanup_guard() {
  begin_scenario "11. lib_cleanup refuses a scratch root it must not remove"
  local bad="$TEST_ROOT/cleanup-bad" good="$TEST_ROOT/cleanup-good" out
  mkdir -p "$bad/home/inner" "$good/inner"
  guard_scratch_root "$bad"
  guard_scratch_root "$good"
  # In a bash of its own, not a subshell: TEST_ROOT and HOME reach it as environment, so this run's own
  # values are never shadowed even for an instant, and what runs is test/lib.sh exactly as a suite sources
  # it. A non-zero exit cannot abort this suite either — it would show up in the assertions below instead.

  # a root with the home directory inside it: refused, and nothing removed
  out="$(TEST_ROOT="$bad" HOME="$bad/home" KEEP='' "$BASH" -c '. "$1"; lib_cleanup' _ "$REPO/test/lib.sh" 2>&1)" || true
  assert_has "it says which root it refused" "$out" "refusing to remove"
  assert_dir "…and removed nothing" "$bad"

  # …and a root that is plainly this run's own is still removed, or the guard would have stopped the trap
  # from doing its job at all, which is a worse bug than the one it is here to prevent.
  out="$(TEST_ROOT="$good" KEEP='' "$BASH" -c '. "$1"; lib_cleanup' _ "$REPO/test/lib.sh" 2>&1)" || true
  assert_gone "a root with nothing of the user's under it is still removed" "$good"
  assert_eq "…and says nothing about it" "" "$out"
  end_scenario
}

# ---------------------------------------------------------------------------- main

# expected_assertions: what a complete run makes. Asserting the TOTAL is what catches the failure mode a
# pass/fail count cannot see — a scenario that stops asserting rather than starts failing. The same guard in
# test/install-smoke.sh once caught a mutation that took it from 323 assertions to 318 with every scenario
# still green.
expected_assertions() {
  local n=$FIXED_ASSERTIONS
  if [[ $OS == Darwin ]]; then n=$((n + DARWIN_ASSERTIONS)); fi
  echo "$n"
}

# Everything that is not Darwin-only. Bump it in the same commit as the assertion you added.
FIXED_ASSERTIONS=237
# The assertions that only a Mac can make, counted apart so the total is right on both platforms.
# is_remote() (bin/wt:~88) is true on any machine that is not a Darwin one, and bin/wt has no FORCE_OS to
# lie to it with — install.sh has one, but adding the equivalent here would be a change to the code under
# test. So on Linux: scenario 8 is skipped whole (there, `wt new` without --no-workspace asks the Mac for a
# row over the relay and never consults cmux, and check_identity asks tmux instead of the row list, so
# neither the "row belongs to another repo" refusal nor cmux_row_field's local-row preference is reachable),
# and scenario 4 does not assert that `wt show` prints no session: line, because there it prints one, nor
# run `wt open`, which there asks the Mac over the relay instead of running `code`.
DARWIN_ASSERTIONS=28

# shellcheck disable=SC2016   # $BASH_VERSION below is for the OTHER bash to expand, not this one
main() {
  echo "wt smoke test: repo $REPO, scratch root $TEST_ROOT"
  echo "  this suite under bash ${BASH_VERSION}; bin/wt under $WT_BASH" \
       "($("$WT_BASH" -c 'echo "$BASH_VERSION"'))"
  scenario_guard
  scenario_new_and_sidecar
  scenario_base_resolution
  scenario_names_and_collisions
  scenario_list_show_path
  scenario_include_and_setup
  scenario_rm_refusals
  scenario_prune_agrees
  scenario_cmux
  scenario_host_args
  scenario_shared_tmux_cmd
  scenario_cleanup_guard
  lib_summary "$(expected_assertions)"
}

main "$@"
