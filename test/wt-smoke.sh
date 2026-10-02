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
# both ways, or the one that matters goes untested under the one that matters. Scenario 11 does at least
# parse bin/wt with /bin/bash -n on every run, so a 3.2 syntax error cannot hide behind a green 5.x run.
#
# Why this file exists: bin/wt is 1500 lines that create and DESTROY work — `wt rm` deletes a worktree, its
# branch and its uncommitted files, and `wt prune` does it in a loop without being asked twice. Everything
# standing between a task and a lost afternoon is rm_reasons, whose branches are each a bug that was found
# the hard way: a base stored as the literal "HEAD" that compares a worktree with itself, a commit count
# taken from a detached HEAD instead of from the branch, an .env copied in by .wt-include that is in no git
# and no backup — and, the other way round, a squash-merged branch that only --force could remove, which
# waived the other checks too. None of that was covered by anything. These scenarios cover the refusals first, then
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
# What a green run does NOT exercise: real ssh (scenario 10 uses a fake SSH server, and scenario 9 only
# asserts the paths that return before remote_sh), cmux itself (a stub answers for it), tmux, the
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

# assert_lacks <what> <haystack> <fixed string>: the string is nowhere in the text — for the line a run must
# NOT print, such as a second fetch of a base that was refreshed a moment ago.
assert_lacks() {
  case "$2" in
    *"$3"*) fail "$1: did not expect '$3' in the output, got: $(printf '%s' "$2" | tr '\n' '|' | cut -c1-200)" ;;
    *) pass ;;
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

# add_origin <repo>: give a scratch repo a bare "origin" under the scratch root, push main to it and set
# origin/HEAD, so that default_base answers origin/main the way it does for a real clone. Prints the path
# of a second clone, the "editor": the machine on which PRs get squash-merged and head branches deleted,
# which is what GitHub does and what the repo under test then has to notice from a stale origin/main.
add_origin() {
  local r="$1" o e
  guard_scratch_root "$r"
  mkdir -p "$TEST_ROOT/origins" "$TEST_ROOT/editors"
  o="$TEST_ROOT/origins/$(basename "$r").git"; e="$TEST_ROOT/editors/$(basename "$r")"
  fixture_git "$r" init -q --bare --initial-branch=main "$o"
  fixture_git "$r" remote add origin "$o"
  fixture_git "$r" push -q -u origin main
  fixture_git "$r" remote set-head origin main
  fixture_git "$r" clone -q "$o" "$e"
  fixture_git "$e" config user.name 'Upstream Editor'
  fixture_git "$e" config user.email 'editor@example.invalid'
  printf '%s\n' "$e"
}

# land_squash <editor> <branch> <message>: what "Squash and merge" plus "delete branch" does on GitHub —
# one new commit on main carrying the branch's whole diff, the head branch gone from the remote. The repo
# under test has fetched nothing: its origin/main and origin/<branch> are exactly as they were.
land_squash() {
  fixture_git "$1" fetch -q origin
  fixture_git "$1" checkout -q main
  fixture_git "$1" merge -q --ff-only origin/main
  fixture_git "$1" merge -q --squash "origin/$2" >/dev/null 2>&1
  fixture_git "$1" commit -q -m "$3"
  fixture_git "$1" push -q origin main
  fixture_git "$1" push -q origin --delete "$2"
}

# editor_commit <editor> <file> <text|"">: one more commit on main after a squash, pushed. An empty text
# deletes the file, which is how a squash gets partially reverted.
editor_commit() {
  if [[ -n "$3" ]]; then printf '%s\n' "$3" >"$1/$2"; fixture_git "$1" add -- "$2"
  else fixture_git "$1" rm -q -- "$2"; fi
  fixture_git "$1" commit -q -m "editor: $2"
  fixture_git "$1" push -q origin main
}

# set_line <file> <n> <text>: replace line n of a file, portably (BSD and GNU sed disagree about -i).
set_line() {
  local tmp="$1.tmp"
  awk -v n="$2" -v t="$3" 'NR == n { print t; next } { print }' "$1" >"$tmp" && mv "$tmp" "$1"
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
  if [ -z "$w" ]; then
    # After a reconnect RPC armed it, each read takes remote-row's next state from the queue.
    if [ -s "$CMUX_STUB_STATE_QUEUE" ]; then
      s=$(head -1 "$CMUX_STUB_STATE_QUEUE")
      tail -n +2 "$CMUX_STUB_STATE_QUEUE" >"$CMUX_STUB_STATE_QUEUE.tmp" && mv "$CMUX_STUB_STATE_QUEUE.tmp" "$CMUX_STUB_STATE_QUEUE"
      jq --arg s "$s" '(.workspaces[] | select(.id == "remote-row") | .remote.state) = $s' "$CMUX_STUB_ROWS" >"$CMUX_STUB_ROWS.tmp"
      mv "$CMUX_STUB_ROWS.tmp" "$CMUX_STUB_ROWS"
    fi
    cat "$CMUX_STUB_ROWS"
  elif [ -f "$CMUX_STUB_ROWS_DIR/$w.json" ]; then cat "$CMUX_STUB_ROWS_DIR/$w.json"
  else echo '{"workspaces":[]}'
  fi
  exit 0
fi
if [ "$1" = rpc ] && [ "$2" = workspace.remote.reconnect ]; then
  echo '{"ok":true,"stub":"reconnect requested"}'
  # A queued list of states stands in for cmux trying and failing; without one the row just connects.
  if [ -s "$CMUX_STUB_RECONNECT_STATES" ]; then mv "$CMUX_STUB_RECONNECT_STATES" "$CMUX_STUB_STATE_QUEUE"; exit 0; fi
  jq '(.workspaces[] | select(.id == "remote-row") | .remote.state) = "connected"' "$CMUX_STUB_ROWS" >"$CMUX_STUB_ROWS.tmp"
  mv "$CMUX_STUB_ROWS.tmp" "$CMUX_STUB_ROWS"
  exit 0
fi
if [ "$1" = read-screen ]; then
  if [ -f "$CMUX_STUB_SCREEN_COUNT" ]; then n=$(cat "$CMUX_STUB_SCREEN_COUNT"); else n=0; fi
  n=$((n + 1))
  printf '%s\n' "$n" >"$CMUX_STUB_SCREEN_COUNT"
  # A line "<n> <state>" gives remote-row that state as read <n> is served: a dropout, or a reconnect, mid-poll.
  s=''; if [ -f "$CMUX_STUB_STATE_AT_READ" ]; then s=$(awk -v n="$n" '$1 == n { print $2 }' "$CMUX_STUB_STATE_AT_READ"); fi
  if [ -n "$s" ]; then
    jq --arg s "$s" '(.workspaces[] | select(.id == "remote-row") | .remote.state) = $s' "$CMUX_STUB_ROWS" >"$CMUX_STUB_ROWS.tmp"
    mv "$CMUX_STUB_ROWS.tmp" "$CMUX_STUB_ROWS"
  fi
  if [ -f "$CMUX_STUB_SCREEN_QUEUE/$n" ]; then
    cat "$CMUX_STUB_SCREEN_QUEUE/$n"
    exit 0
  fi
  if [ -f "$CMUX_STUB_SCREEN_DELAY" ]; then
    cat "$CMUX_STUB_SCREEN_DELAY"
    rm -f "$CMUX_STUB_SCREEN_DELAY"
  else
    cat "$CMUX_STUB_SCREEN"
  fi
  if [ -f "$CMUX_STUB_NONCE" ]; then
    if [ ! -f "$CMUX_STUB_NONCE_STALE" ]; then cat "$CMUX_STUB_NONCE"; fi
    rm -f "$CMUX_STUB_NONCE"
  fi
  exit 0
fi
if [ "$1" = send ] && [ -f "$CMUX_STUB_SEND_FAIL" ]; then exit 1; fi
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
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex"

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
#   WT_AGENT and WT_HOST are unset because the author's shell exports them and each one changes what `wt new`
#   records or which branch it takes. WT_AGENT_ARGS is replaced with WT_EXTRA for precedence checks.
#   CODEX_SANDBOX is pinned to $WT_SANDBOX, empty unless a scenario sets it: Codex sets it inside its
#   sandbox, and `wt open` refuses there — so a run of this suite from a Codex session would fail otherwise.
#   stdin is /dev/null so nothing can block on a read.
WT_OUT=""
WT_RC=0
WT_CWD=""          # where the next wt_run runs; empty means the scratch root, which is not a git repo
WT_SANDBOX=""      # CODEX_SANDBOX for the next wt_run; empty means not inside Codex's sandbox
WT_PATH_PREFIX=""  # a directory put before $FAKE_BIN on wt_run's PATH; scenario 6b's old-git shim lives in one
WT_RELAY_ENV=()     # a scenario can simulate a VM row against the stub cmux, never the real relay
WT_EXTRA=""        # machine-wide agent args for model precedence checks
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
           CMUX_STUB_SCREEN="$TEST_ROOT/remote-screen" CMUX_STUB_SCREEN_DELAY="$TEST_ROOT/remote-screen-delay" \
           CMUX_STUB_SCREEN_COUNT="$TEST_ROOT/remote-screen-count" CMUX_STUB_SCREEN_QUEUE="$TEST_ROOT/remote-screen-queue" \
           CMUX_STUB_NONCE="$TEST_ROOT/remote-tmux-nonce" CMUX_STUB_NONCE_STALE="$TEST_ROOT/remote-tmux-nonce-stale" \
           CMUX_STUB_STATE_AT_READ="$TEST_ROOT/remote-state-at-read" CMUX_STUB_SEND_FAIL="$TEST_ROOT/cmux-send-fail" \
           CMUX_STUB_RECONNECT_STATES="$TEST_ROOT/reconnect-states" CMUX_STUB_STATE_QUEUE="$TEST_ROOT/state-queue" \
           REMOTE_LOG="$TEST_ROOT/remote-log" \
           REMOTE_SS="$TEST_ROOT/remote-ss" REMOTE_SS_USER="$TEST_ROOT/remote-ss-user" REMOTE_PS="$TEST_ROOT/remote-ps" \
           REMOTE_SS_EST="$TEST_ROOT/remote-ss-est" REMOTE_SS_EST_USER="$TEST_ROOT/remote-ss-est-user" \
           REMOTE_SSH_CONN="$TEST_ROOT/remote-ssh-conn" REMOTE_SSH_DROP="$TEST_ROOT/remote-ssh-drop" \
           REMOTE_SSH_NOISE="$TEST_ROOT/remote-ssh-noise" \
           REMOTE_WT_STATE="$TEST_ROOT/remote-wt-state" \
           REMOTE_WT_SESSION="${REMOTE_WT_SESSION:-wt-project-task}" \
           REMOTE_TMUX="$TEST_ROOT/remote-tmux" REMOTE_TMUX_QUEUE="$TEST_ROOT/remote-tmux-queue" \
           REMOTE_TMUX_DETACH_FAIL="$TEST_ROOT/remote-tmux-detach-fail" \
           "${WT_RELAY_ENV[@]}" \
           CODEX_SANDBOX="$WT_SANDBOX" WT_AGENT_ARGS="$WT_EXTRA" PATH="${WT_PATH_PREFIX:+$WT_PATH_PREFIX:}$FAKE_BIN:$PATH" \
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
  printf '%s\n' "$WT_OUT" | awk -v n="$1" '$1 == n { print $1, $2, $3, $4, $5, $6, $7; exit }'
}

# merged_of <name>: the MERGED column alone, for a row whose branch column is one word.
merged_of() {
  printf '%s\n' "$WT_OUT" | awk -v n="$1" '$1 == n { print $6; exit }'
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
  assert_meta "$r" demo model ""
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

scenario_task_model() {
  begin_scenario "1b. a task model persists and wins on every agent launch"
  local r sidecar
  r="$(new_repo model)"
  sidecar="$r/.git/wt/chosen.json"
  assert_wt_ok "Claude model with a bracket suffix" new chosen --no-workspace -r "$r" -a claude -m 'opus[1m]' -p 'the brief'
  assert_meta "$r" chosen model 'opus[1m]'
  assert_wt_ok "show prints the model" show chosen -r "$r"
  assert_has "show prints the chosen model" "$WT_OUT" 'model:   opus[1m]'
  WT_EXTRA='--model other --fallback-model sonnet --verbose'
  rm -f "$AGENT_LOG"
  assert_wt_ok "Claude first launch" run chosen -r "$r"
  assert_eq "Claude got only the task model and the brief" "$(printf '%s\n' --model 'opus[1m]' --verbose -- 'the brief')" "$(cat "$AGENT_LOG")"
  WT_EXTRA='--model=other --fallback-model=sonnet --verbose'
  rm -f "$AGENT_LOG"
  assert_wt_ok "Claude resume" run chosen -r "$r"
  assert_eq "Claude resume kept the task model" "$(printf '%s\n' --model 'opus[1m]' --verbose -c)" "$(cat "$AGENT_LOG")"
  WT_EXTRA='-c model=unchanged'
  rm -f "$AGENT_LOG"
  assert_wt_ok "Claude keeps -c as an agent option" run chosen -r "$r"
  assert_eq "Claude -c option was not mistaken for Codex config" "$(printf '%s\n' --model 'opus[1m]' -c model=unchanged -c)" "$(cat "$AGENT_LOG")"
  WT_EXTRA=''
  rm -f "$AGENT_LOG"
  assert_wt_ok "Claude with no extra args" run chosen -r "$r"
  assert_eq "task model works without WT_AGENT_ARGS" "$(printf '%s\n' --model 'opus[1m]' -c)" "$(cat "$AGENT_LOG")"

  assert_wt_ok "Codex model" new codex-model --no-workspace -r "$r" -a codex --model gpt-5.3-codex -p 'codex brief'
  assert_meta "$r" codex-model model gpt-5.3-codex
  WT_EXTRA='-m other -c model=older --search'
  rm -f "$AGENT_LOG"
  assert_wt_ok "Codex first launch" run codex-model -r "$r"
  assert_eq "Codex got only the task model and the brief" "$(printf '%s\n' -m gpt-5.3-codex --search -- 'codex brief')" "$(cat "$AGENT_LOG")"
  WT_EXTRA='--model=other -mother -m=other -cmodel=older --config=model=older --search'
  rm -f "$AGENT_LOG"
  assert_wt_ok "Codex later launch" run codex-model -r "$r"
  assert_eq "Codex later launch kept the task model" "$(printf '%s\n' -m gpt-5.3-codex --search -- 'codex brief')" "$(cat "$AGENT_LOG")"
  WT_EXTRA=''

  assert_wt_ok "Claude Vertex model ID" new vertex --no-workspace -r "$r" -a claude -m 'claude-sonnet-4-5@20250514'
  assert_meta "$r" vertex model 'claude-sonnet-4-5@20250514'
  assert_wt_ok "Claude Bedrock model ID" new bedrock --no-workspace -r "$r" -a claude -m 'us.anthropic.claude-sonnet-4-5-v1:0'
  assert_meta "$r" bedrock model 'us.anthropic.claude-sonnet-4-5-v1:0'
  assert_wt_ok "Codex colon model ID" new oss --no-workspace -r "$r" -a codex -m 'gpt-oss:20b'
  assert_meta "$r" oss model 'gpt-oss:20b'

  assert_wt_ok "same-agent attach" attach chosen -r "$r" -a claude
  assert_meta "$r" chosen model 'opus[1m]'
  assert_wt_ok "change agent" attach chosen -r "$r" -a codex
  assert_meta "$r" chosen model ""
  assert_absent "$r/.git/wt" chosen.started
  rm -f "$AGENT_LOG"
  assert_wt_ok "changed agent starts from brief" run chosen -r "$r"
  assert_eq "Codex receives no stale Claude model" "$(printf '%s\n' -- 'the brief')" "$(cat "$AGENT_LOG")"

  assert_wt_ok "shell-only task" new shell-only --no-workspace -r "$r" -a none
  jq '.model="bad model"' "$r/.git/wt/shell-only.json" >"$TEST_ROOT/shell-only.json"
  mv "$TEST_ROOT/shell-only.json" "$r/.git/wt/shell-only.json"
  assert_wt_ok "shell-only ignores model metadata" run shell-only -r "$r"
  assert_has "shell-only run opens the shell" "$WT_OUT" 'this is your shell'
  jq '.model="bad model"' "$sidecar" >"$TEST_ROOT/chosen.json"
  mv "$TEST_ROOT/chosen.json" "$sidecar"
  assert_wt_fails 1 "$sidecar" run chosen -r "$r"

  assert_wt_fails 1 "invalid model" new bad-space --no-workspace -r "$r" -m 'two words'
  assert_absent "$r/.worktrees" bad-space
  assert_wt_fails 1 "invalid model" new bad-shell --no-workspace -r "$r" -m 'opus;touch'
  assert_absent "$r/.worktrees" bad-shell
  assert_wt_fails 1 "invalid model" new bad-empty --no-workspace -r "$r" -m ''
  assert_absent "$r/.worktrees" bad-empty
  assert_wt_fails 1 "needs an agent" new bad-none --no-workspace -r "$r" -a none -m fable
  assert_absent "$r/.worktrees" bad-none
  assert_wt_fails 1 "for Claude" new bad-codex --no-workspace -r "$r" -a codex -m 'opus[1m]'
  assert_absent "$r/.worktrees" bad-codex
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
  assert_eq "a base with a '|' keeps wt list's columns straight" "b-pipe wt/b-pipe feat|x 0 0 yes 0" "$(wt_line b-pipe)"
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
  assert_eq "the columns" "NAME BRANCH BASE AHEAD BEHIND MERGED DIRTY LAST" \
            "$(printf '%s\n' "$WT_OUT" | awk '$1 == "NAME" { $1 = $1; print; exit }')"
  assert_eq "the row" "a1 wt/a1 main 0 0 yes 0" "$(wt_line a1)"
  assert_eq "one repo means one repo" "1" \
            "$(printf '%s\n' "$WT_OUT" | grep -c '^[^ ].*  (' || true)"

  assert_wt_ok "wt list --all" list --all
  assert_eq "--all walks both repos on the search path" "2" \
            "$(printf '%s\n' "$WT_OUT" | grep -c '^[^ ].*  (' || true)"
  assert_eq "…the first repo's task" "a1 wt/a1 main 0 0 yes 0" "$(wt_line a1)"
  assert_eq "…and the second repo's" "b1 wt/b1 main 0 0 yes 0" "$(wt_line b1)"

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
  assert_has "…and says why the branch is not merged" "$WT_OUT" "merged:  no (merging wt/det into main would still change 1 path(s))"
  assert_wt_ok "wt list" list -r "$ra"
  assert_eq "wt list agrees" "det wt/det (HEAD detached) main 1 0" "$(wt_line det)"
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
  # A VM receives only cmux's delivery result, never the Mac hook's launch result.
  WT_RELAY_ENV=(CMUX_SSH_ATTEMPT_ID=test CMUX_SOCKET_PATH=127.0.0.1:12345 WT_HOST=fakevm TMUX=)
  stub_cmux alive
  assert_wt_ok "VM wt open sends a request" open a1 -r "$ra"
  assert_has "…reports a request, not a launched window" "$WT_OUT" "requested VS Code on the Mac: fakevm:$ra/.worktrees/a1"
  assert_has "…labels the manual command as conditional" "$WT_OUT" "if no window appears, run on the Mac: wt -H fakevm open -r $ra a1"
  assert_lacks "…does not claim a window opened" "$WT_OUT" "opened in VS Code"
  assert_grep "…sent the notification" "$CMUX_LOG" "notify --title wt-open"
  stub_cmux dead
  assert_wt_fails 1 "VS Code request to the Mac failed" open a1 -r "$ra"
  assert_has "…gives the manual command on relay failure" "$WT_OUT" "Run on the Mac: wt -H fakevm open -r $ra a1"
  assert_lacks "…does not report a successful request" "$WT_OUT" "requested VS Code on the Mac:"
  WT_RELAY_ENV=()
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

# 6b. The reason scenario 6 could not provoke the other way round: a branch whose work has landed on the
# base without any of its commits becoming an ancestor of it. GitHub's "squash and merge" — the default on
# most repos — lands a PR as one new commit and deletes the head branch, after which every commit on
# wt/<name> is unmerged by ancestry and gone from the remote, and `wt rm` used to leave --force as the only
# way out, which waives the dirty-tree and .wt-include checks too. branch_landed asks git whether merging
# the branch into the base would change anything; these cases are the shapes that answer yes and no.
# Each squash happens on a second clone, the "editor", and the repo under test has not fetched: its
# origin/main is from before the merge, as it is when the next thing typed after merging a PR is `wt rm`.
scenario_squash_merge() {
  begin_scenario "6b. wt rm after a squash merge: work that landed is not a reason, work that did not still is"
  local r e stale fresh dry n verdict want shim hunks=no
  r="$(new_repo squash)"
  stub_cmux dead
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' >"$r/lines.txt"   # for the cases about a later edit
  fixture_git "$r" add lines.txt
  fixture_git "$r" commit -q -m lines
  e="$(add_origin "$r")"
  # whether the real git merges hunk by hunk, judged by bin/wt's own function, lifted out of it
  if "$WT_BASH" -c "$(sed -n '/^git_merges_trees()/,/^}/p' "$WT"); git_merges_trees" 2>/dev/null; then hunks=yes; fi

  # every worktree first: `wt new` fetches its base, so all of the landing below has to come after the last
  # of them for origin/main to be stale when wt is asked, which is the shape this scenario is about
  for n in sq sq2 past picked stack rev conf hunk zero; do
    assert_wt_ok "wt new $n" new "$n" --no-workspace -r "$r"
  done
  # a) two commits, pushed, squash-merged, head branch deleted: the case this scenario exists for
  fixture_commit "$r/.worktrees/sq" one.txt 'one'
  fixture_commit "$r/.worktrees/sq" two.txt 'two'
  fixture_git "$r/.worktrees/sq" push -q -u origin wt/sq
  land_squash "$e" wt/sq 'sq (#1)'
  # b) the same, with the stale origin/wt/sq2 gone as well (a fetch with fetch.prune): git's own `branch -d`
  # then has nothing to call the branch merged into, and it is wt's finding that has to delete it
  fixture_commit "$r/.worktrees/sq2" three.txt 'three'
  fixture_git "$r/.worktrees/sq2" push -q -u origin wt/sq2
  land_squash "$e" wt/sq2 'sq2 (#2)'
  fixture_git "$r" update-ref -d refs/remotes/origin/wt/sq2
  # c) a commit made after the squash: in no base, on no remote
  fixture_commit "$r/.worktrees/past" four.txt 'four'
  fixture_git "$r/.worktrees/past" push -q -u origin wt/past
  land_squash "$e" wt/past 'past (#3)'
  fixture_commit "$r/.worktrees/past" five.txt 'five'
  # d) a stack: picked's one commit was cherry-picked into stack, stack was squash-merged, picked never pushed
  fixture_commit "$r/.worktrees/picked" six.txt 'six'
  fixture_commit "$r/.worktrees/stack" seven.txt 'seven'
  fixture_git "$r/.worktrees/stack" cherry-pick wt/picked >/dev/null
  fixture_git "$r/.worktrees/stack" push -q -u origin wt/stack
  land_squash "$e" wt/stack 'stack (#4)'
  # e) a squash the base then partially reverted: merging the branch again would put nine.txt back
  fixture_commit "$r/.worktrees/rev" eight.txt 'eight'
  fixture_commit "$r/.worktrees/rev" nine.txt 'nine'
  fixture_git "$r/.worktrees/rev" push -q -u origin wt/rev
  land_squash "$e" wt/rev 'rev (#5)'
  editor_commit "$e" nine.txt ''
  # f) a squash whose lines the base edited again: the merge conflicts
  set_line "$r/.worktrees/conf/lines.txt" 5 'l5 by conf'
  fixture_git "$r/.worktrees/conf" commit -q -am conf
  fixture_git "$r/.worktrees/conf" push -q -u origin wt/conf
  land_squash "$e" wt/conf 'conf (#6)'
  set_line "$e/lines.txt" 5 'l5 by the editor'
  fixture_git "$e" commit -q -am 'editor: line 5 again'
  fixture_git "$e" push -q origin main
  # g) a squash after which the base edited ANOTHER line of the same file: landed to a hunk-level merge
  # (git 2.38+), not to the file-level fallback older git gets
  set_line "$r/.worktrees/hunk/lines.txt" 1 'l1 by hunk'
  fixture_git "$r/.worktrees/hunk" commit -q -am hunk
  fixture_git "$r/.worktrees/hunk" push -q -u origin wt/hunk
  land_squash "$e" wt/hunk 'hunk (#7)'
  set_line "$e/lines.txt" 10 'l10 by the editor'
  fixture_git "$e" commit -q -am 'editor: line 10'
  fixture_git "$e" push -q origin main
  # h) two commits that cancel out: merging changes nothing, which proves nothing, so it is refused as ever
  fixture_commit "$r/.worktrees/zero" ten.txt 'ten'
  fixture_git "$r/.worktrees/zero" rm -q ten.txt
  fixture_git "$r/.worktrees/zero" commit -q -m 'undo ten'

  # `wt list` never fetches, so against the stale base the squash reads as unmerged work — for now
  assert_wt_ok "wt list before anything fetched" list -r "$r"
  assert_eq "sq against a stale origin/main" no "$(merged_of sq)"

  # prune --dry-run first: every verdict at once, with the base refreshed once for all of them — the offline
  # check comes first, and once the fetch has happened nothing is left to go online for
  stale="$(fixture_git "$r" rev-parse origin/main)"
  assert_wt_ok "wt prune --dry-run" prune --dry-run -r "$r"
  dry="$WT_OUT"
  fresh="$(fixture_git "$r" rev-parse origin/main)"
  assert_eq "origin/main is the editor's main after the run" "$(fixture_git "$e" rev-parse main)" "$fresh"
  if [[ "$stale" == "$fresh" ]]; then fail "origin/main was already fresh before wt ran, so the fetch was not tested"; else pass; fi
  assert_eq "the base is fetched once, not once per worktree" 1 "$(printf '%s\n' "$dry" | grep -c 'fetching origin/main')"
  for n in sq sq2 past picked stack rev conf hunk zero; do
    verdict=keep
    case "$n" in sq|sq2|picked|stack) verdict=would-remove ;; hunk) [[ $hunks == yes ]] && verdict=would-remove ;; esac
    if [[ "$verdict" == keep ]]; then want="keep $n ("; else want="would remove $n ("; fi
    assert_has "prune's verdict on $n" "$dry" "$want"
  done
  # …and the reasons say what was checked, not just that it failed
  assert_has "past: a commit past the squash" "$dry" \
    "keep past (2 commit(s) on wt/past not merged into origin/main and not on a remote (merging wt/past into origin/main would still change 1 path(s)))"
  assert_has "rev: a partial revert" "$dry" \
    "keep rev (2 commit(s) on wt/rev not merged into origin/main and not on a remote (merging wt/rev into origin/main would still change 1 path(s)))"
  assert_has "conf: the base edited the same lines" "$dry" "not on a remote (merging wt/conf into origin/main would"
  assert_has "zero: nothing to show" "$dry" "(the net change of wt/zero since"

  # with the base refreshed, list and show say what rm is about to do, in rm's own words
  assert_wt_ok "wt list after the fetch" list -r "$r"
  for n in sq sq2 picked stack; do assert_eq "list's MERGED for $n" squash "$(merged_of "$n")"; done
  for n in past rev conf zero; do assert_eq "list's MERGED for $n" no "$(merged_of "$n")"; done
  if [[ $hunks == yes ]]; then assert_eq "list's MERGED for hunk" squash "$(merged_of hunk)"
  else assert_eq "list's MERGED for hunk" no "$(merged_of hunk)"; fi
  assert_wt_ok "wt show sq" show sq -r "$r"
  assert_has "show: squash, and what that rests on" "$WT_OUT" "merged:  squash (every change on wt/sq is in origin/main, though no commit is)"
  assert_wt_ok "wt show past" show past -r "$r"
  assert_has "show: no, and why" "$WT_OUT" "merged:  no (merging wt/past into origin/main would still change 1 path(s))"

  # the real prune removes exactly the landed ones, branches included
  assert_wt_ok "wt prune" prune -r "$r"
  for n in sq sq2 picked stack; do
    assert_gone "prune removed $n" "$r/.worktrees/$n"
    assert_branch "$r" "wt/$n" no
  done
  if [[ $hunks == yes ]]; then assert_gone "prune removed hunk (hunk-level merge)" "$r/.worktrees/hunk"
  else assert_dir "prune kept hunk (file-level merge)" "$r/.worktrees/hunk"; fi
  for n in past rev conf zero; do assert_dir "prune kept $n" "$r/.worktrees/$n"; done

  # --discard-commits waives the commit reason and nothing else: a dirty tree still refuses, without a word
  # about commits, and once the tree is clean the worktree and the branch go
  printf 'unsaved\n' >"$r/.worktrees/past/scratch.txt"
  assert_wt_fails 3 "1 uncommitted change(s)" rm past -r "$r" --discard-commits
  assert_lacks "…and the waived reason is not among them" "$WT_OUT" "commit(s) on wt/past"
  assert_dir "…and the worktree stays" "$r/.worktrees/past"
  guard_scratch_root "$r/.worktrees/past"; rm -f "$r/.worktrees/past/scratch.txt"
  assert_wt_ok "wt rm past --discard-commits" rm past -r "$r" --discard-commits
  assert_gone "…removed the worktree" "$r/.worktrees/past"
  assert_branch "$r" wt/past no
  # the plain refusal carries the same check, and its hint names the narrower flag
  refuses "$r" rev "2 commit(s) on wt/rev not merged into origin/main and not on a remote (merging wt/rev into origin/main would still change 1 path(s))"
  assert_has "…and the hint names --discard-commits" "$WT_OUT" "--discard-commits waives only the commit reason"
  forced "$r" rev
  refuses "$r" zero "is empty, which proves nothing"
  forced "$r" zero
  refuses "$r" conf "(merging wt/conf into origin/main would"
  forced "$r" conf

  # older git: a `git` that says it is 2.34 and hands everything else to the real one drives the file-level
  # fallback, which lands a plain squash and refuses one whose file the base edited again, hunks or not
  shim="$TEST_ROOT/oldgit"; mkdir -p "$shim"
  # shellcheck disable=SC2016   # the $1 and $@ are for the shim's own sh to expand
  printf '#!/bin/sh\nif [ "$1" = version ]; then echo "git version 2.34.1"; exit 0; fi\nexec %s "$@"\n' \
         "$(command -v git)" >"$shim/git"
  chmod +x "$shim/git"
  assert_wt_ok "wt new old1" new old1 --no-workspace -r "$r"
  assert_wt_ok "wt new old2" new old2 --no-workspace -r "$r"
  fixture_commit "$r/.worktrees/old1" eleven.txt 'eleven'
  fixture_git "$r/.worktrees/old1" push -q -u origin wt/old1
  land_squash "$e" wt/old1 'old1 (#8)'
  set_line "$r/.worktrees/old2/lines.txt" 2 'l2 by old2'
  fixture_git "$r/.worktrees/old2" commit -q -am old2
  fixture_git "$r/.worktrees/old2" push -q -u origin wt/old2
  land_squash "$e" wt/old2 'old2 (#9)'
  set_line "$e/lines.txt" 9 'l9 by the editor'
  fixture_git "$e" commit -q -am 'editor: line 9'
  fixture_git "$e" push -q origin main
  WT_PATH_PREFIX="$shim"
  assert_wt_ok "wt rm old1 under git 2.34" rm old1 -r "$r"
  assert_gone "…removed the worktree" "$r/.worktrees/old1"
  assert_branch "$r" wt/old1 no
  refuses "$r" old2 "(merging wt/old2 into origin/main would touch a file origin/main changed since (git 2.34.1 compares whole files; 2.38 compares hunks))"
  WT_PATH_PREFIX=""
  if [[ $hunks == yes ]]; then    # the real git, hunk by hunk, sees old2's line 2 in the base
    assert_wt_ok "wt rm old2 under the real git" rm old2 -r "$r"
    assert_gone "…removed the worktree" "$r/.worktrees/old2"
  else forced "$r" old2; fi

  # a remote that cannot be reached: the offline verdict stands, and the refusal says the base is as last fetched
  assert_wt_ok "wt new off" new off --no-workspace -r "$r"
  fixture_commit "$r/.worktrees/off" twelve.txt 'twelve'
  fixture_git "$r" remote set-url origin "$TEST_ROOT/no-such-origin.git"
  refuses "$r" off "(merging wt/off into origin/main would still change 1 path(s); origin/main could not be refreshed from its remote)"
  fixture_git "$r" remote set-url origin "$TEST_ROOT/origins/$(basename "$r").git"
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

# A VM agent removing its own task must leave row and session cleanup to the Mac hook. Its refusal still
# leaves both alone, and all paths here are scratch fixtures despite the simulated relay environment.
scenario_self_rm_vm() {
  begin_scenario "7b. a VM task can remove itself after changing to its main checkout"
  local r fake session
  r="$(new_repo self-rm)"
  stub_cmux dead
  assert_wt_ok "wt new self" new self --no-workspace -r "$r"
  session="wt-$(basename "$r")-self"
  fake="$TEST_ROOT/self-tmux-bin"; mkdir -p "$fake"
  cat >"$fake/tmux" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$SELF_TMUX_LOG"
case "$1" in display-message) printf '%s\n' "$SELF_TMUX_SESSION" ;; esac
STUB
  chmod +x "$fake/tmux"
  stub_cmux alive
  WT_PATH_PREFIX="$fake" WT_CWD="$r"
  WT_RELAY_ENV=("WT_HOST=test-vm" "CMUX_SOCKET_PATH=127.0.0.1:23456" "CMUX_WORKSPACE_ID=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
                "TMUX=/tmp/fake,1,0" "SELF_TMUX_SESSION=$session" "SELF_TMUX_LOG=$TEST_ROOT/self-tmux.log"
                "WT_CLOSE_WAIT_SECONDS=0")
  printf 'unsaved\n' >"$r/.worktrees/self/scratch.txt"
  assert_wt_fails 3 "1 uncommitted change(s)" rm self -r "$r"
  assert_dir "refusal kept the worktree" "$r/.worktrees/self"
  assert_lacks "refusal sent no row-close request" "$(cat "$CMUX_LOG")" "--title wt-close"
  guard_scratch_root "$r/.worktrees/self"; rm -f "$r/.worktrees/self/scratch.txt"
  WT_RELAY_ENV[0]="WT_HOST="
  printf 'unsaved again\n' >"$r/.worktrees/self/scratch.txt"
  assert_wt_fails 3 "1 uncommitted change(s)" rm self -r "$r"
  assert_dir "dirty refusal takes precedence over missing host" "$r/.worktrees/self"
  guard_scratch_root "$r/.worktrees/self"; rm -f "$r/.worktrees/self/scratch.txt"
  assert_wt_fails 1 "WT_HOST is not set" rm self -r "$r"
  assert_dir "missing host left the worktree intact" "$r/.worktrees/self"
  WT_RELAY_ENV[0]="WT_HOST=test-vm"
  assert_wt_ok "VM self-removal" rm self -r "$r"
  assert_gone "self-removal removed the worktree" "$r/.worktrees/self"
  assert_branch "$r" wt/self no
  assert_has "self-removal asked the Mac to close the row" "$(cat "$CMUX_LOG")" "--title wt-close"
  assert_has "an unanswered request warns about incomplete cleanup" "$WT_OUT" "Mac row or tmux session is still open"
  assert_lacks "VM did not kill its own tmux session first" "$(cat "$TEST_ROOT/self-tmux.log")" "kill-session"
  WT_RELAY_ENV=() WT_PATH_PREFIX="" WT_CWD=""
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

  # The sidecar holds the row title. Save it before removing that sidecar, or a renamed row stays open.
  stub_cmux alive
  assert_wt_ok "wt new custom" new custom --no-workspace -r "$r"
  jq --arg t "$id:renamed" '.title = $t' "$r/.git/wt/custom.json" >"$r/.git/wt/custom.json.tmp"
  mv "$r/.git/wt/custom.json.tmp" "$r/.git/wt/custom.json"
  cat >"$WT_ROWS" <<ROWS
{"workspaces":[{"id":"custom-row","title":"$id:renamed","description":"@local","current_directory":"$r"}]}
ROWS
  assert_wt_ok "wt rm uses the saved title" rm custom -r "$r"
  assert_has "…and closes the renamed row" "$(cat "$CMUX_LOG")" "workspace close custom-row"

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

# 10. A fake SSH server runs the relay check in a scratch HOME. Its ss, ps and kill shims prove that
# attach signals only the process owning the suspended row's port, and only when that process's SSH session
# comes from an address other than the fake SSH_CONNECTION's, then asks cmux to reconnect that row. Its tmux
# shim answers the VM probe that must agree with a shell prompt on the row's screen before anything is typed.

# Scenario 10's row state, and what its fakes logged since the logs were last emptied.
set_row_state() {   # <state>: remote-row's .remote.state in $WT_ROWS
  jq --arg s "$1" '(.workspaces[] | select(.id == "remote-row") | .remote.state) = $s' "$WT_ROWS" >"$WT_ROWS.tmp" \
    && mv "$WT_ROWS.tmp" "$WT_ROWS"
}
screen_reads() { grep -c '^read-screen --workspace remote-row$' "$CMUX_LOG" || true; }
tmux_sends() { grep -c '^send --workspace remote-row ' "$CMUX_LOG" || true; }
vm_probes() { grep -c '^tmux has-session ' "$TEST_ROOT/remote-log" || true; }

scenario_suspended_attach() {
  begin_scenario "10. wt -H attach recovers only a suspended row's user-owned sshd relay"
  local fake="$TEST_ROOT/remote-bin" slot=ssh-014753cc-049e-487f-a41a-355d5bb50708 uid screen shape
  mkdir -p "$fake" "$SCRATCH_HOME/.local/bin" "$SCRATCH_HOME/.cmux/relay"
  uid=$(id -u)
  cat >"$fake/ssh" <<'STUB'
#!/bin/bash
shift 5  # -o BatchMode=yes -o ConnectTimeout=5 <host>; the command is left
printf 'ssh %s\n' "${1%%$'\n'*}" >>"$REMOTE_LOG"
# A drop can come between the VM's show and the relay check, so only the relay call can be made to fail.
case "$1" in 'bash -s -- '*) if [ -f "$REMOTE_SSH_DROP" ]; then echo 'ssh: connect to host fakevm port 22: Network is unreachable' >&2; exit 255; fi ;; esac
if [ -f "$REMOTE_SSH_NOISE" ]; then cat "$REMOTE_SSH_NOISE"; fi   # what a VM's login files may print
SSH_CONNECTION='203.0.113.9 50000 10.0.0.4 22'   # the Mac's current address, as sshd would export it
if [ -f "$REMOTE_SSH_CONN" ]; then SSH_CONNECTION=$(cat "$REMOTE_SSH_CONN"); fi
export SSH_CONNECTION
bash -c "$1"
STUB
  cat >"$SCRATCH_HOME/.local/bin/wt" <<'STUB'
#!/bin/sh
printf 'show %s\n' "$*" >>"$REMOTE_LOG"
printf '  repo: /vm/repos/project\n  session: %s (%s)\n' "$REMOTE_WT_SESSION" "$(cat "$REMOTE_WT_STATE")"
STUB
  # Each has-session is one probe, answered attached, detached or missing: from the queue while it lasts,
  # then from the fixture. list-clients reports the answer that probe drew.
  cat >"$fake/tmux" <<'STUB'
#!/bin/sh
printf 'tmux %s\n' "$*" >>"$REMOTE_LOG"
case "$1" in
  has-session)
    if [ -s "$REMOTE_TMUX_QUEUE" ]; then
      answer=$(head -1 "$REMOTE_TMUX_QUEUE")
      tail -n +2 "$REMOTE_TMUX_QUEUE" >"$REMOTE_TMUX_QUEUE.tmp" && mv "$REMOTE_TMUX_QUEUE.tmp" "$REMOTE_TMUX_QUEUE"
    else
      answer=$(cat "$REMOTE_TMUX")
    fi
    printf '%s\n' "$answer" >"$REMOTE_TMUX.drawn"
    [ "$answer" != missing ] ;;
  list-clients)
    case "$*" in
      *'-F #{client_pid} #{client_tty}'*) if [ "$(cat "$REMOTE_TMUX")" = attached ]; then echo '4242 /dev/pts/3'; fi ;;
      *) if [ "$(cat "$REMOTE_TMUX.drawn")" = attached ]; then echo '/dev/pts/3: wt-project-task [200x50 xterm-256color] (utf8)'; fi ;;
    esac ;;
  display-message)
    for arg do nonce=$arg; done
    printf '%s\n' "$nonce" >"$CMUX_STUB_NONCE" ;;
  detach-client) [ ! -f "$REMOTE_TMUX_DETACH_FAIL" ] ;;
  *) exit 1 ;;
esac
STUB
  cat >"$fake/ss" <<'STUB'
#!/bin/sh
printf 'ss %s\n' "$*" >>"$REMOTE_LOG"
case "$*" in   # the *_USER files, when present, are what an unprivileged ss sees
  *established*) if [ -f "$REMOTE_SS_EST_USER" ]; then cat "$REMOTE_SS_EST_USER"; else cat "$REMOTE_SS_EST"; fi ;;
  *) if [ -f "$REMOTE_SS_USER" ]; then cat "$REMOTE_SS_USER"; else cat "$REMOTE_SS"; fi ;;
esac
STUB
  cat >"$fake/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$REMOTE_LOG"
case "$*" in *established*) cat "$REMOTE_SS_EST" ;; *) cat "$REMOTE_SS" ;; esac
STUB
  cat >"$fake/ps" <<'STUB'
#!/bin/sh
value=$(cat "$REMOTE_PS")
case "$2" in comm=) echo "${value%%:*}" ;; uid=) echo "${value#*:}" ;; esac
STUB
  cat >"$fake/kill" <<'STUB'
#!/bin/sh
printf 'kill %s\n' "$*" >>"$REMOTE_LOG"
: >"$REMOTE_SS"
rm -f "$REMOTE_SS_USER"
STUB
  chmod +x "$fake"/* "$SCRATCH_HOME/.local/bin/wt"
  WT_PATH_PREFIX="$fake"
  printf '%s\n' "$slot" >"$SCRATCH_HOME/.cmux/relay/65353.slot"
  printf '%s\n' 'other-row' >"$SCRATCH_HOME/.cmux/relay/65000.slot"
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  # `state established` has no State column. 4242's session came from the Mac's old address; 5000 is this call.
  printf '%s\n' '0 0 10.0.0.4:22 198.51.100.7:40000 users:(("sshd",pid=4242,fd=4),("sshd",pid=4200,fd=4))' \
    '0 0 10.0.0.4:22 203.0.113.9:50000 users:(("sshd",pid=5000,fd=4))' >"$TEST_ROOT/remote-ss-est"
  printf 'sshd:%s\n' "$uid" >"$TEST_ROOT/remote-ps"
  printf 'agent still running\n' >"$TEST_ROOT/remote-screen"
  printf 'agent running\n' >"$TEST_ROOT/remote-wt-state"
  printf 'attached\n' >"$TEST_ROOT/remote-tmux"   # the pre-suspension client a network switch leaves listed
  : >"$TEST_ROOT/remote-tmux-queue"
  mkdir -p "$TEST_ROOT/remote-screen-queue"
  : >"$TEST_ROOT/remote-log"
  stub_cmux alive
  cat >"$WT_ROWS" <<ROWS
{"workspaces":[{"id":"remote-row","title":"project:task","description":"@fakevm",
  "remote":{"enabled":true,"destination":"fakevm","state":"suspended","persistent_daemon_slot":"$slot"}}]}
ROWS
  assert_wt_ok "a suspended row reconnects" -H fakevm attach task -r /vm/repos/project
  assert_has "the matching slot yielded port 65353" "$(cat "$TEST_ROOT/remote-log")" 'sport = :65353'
  assert_lacks "another row's port was not checked" "$(cat "$TEST_ROOT/remote-log")" 'sport = :65000'
  assert_has "only that sshd was stopped" "$(cat "$TEST_ROOT/remote-log")" 'kill -TERM 4242'
  assert_has "the row-specific reconnect was called" "$(cat "$CMUX_LOG")" 'rpc workspace.remote.reconnect {"workspace_id":"remote-row"}'
  assert_has "reconnect reached connected" "$WT_OUT" 'connected after reconnect'
  assert_eq "a recovered agent screen is checked before client replacement" 7 "$(screen_reads)"
  assert_eq "a screen with no prompt never asked the VM's tmux" 0 "$(vm_probes)"
  assert_lacks "an attached agent was not typed into" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_has "a recovered attached client was replaced" "$(cat "$TEST_ROOT/remote-log")" 'tmux detach-client -t /dev/pts/3 -E '
  assert_has "replacement keeps the attach recovery line" "$WT_OUT" 'if the replacement attach fails, the row returns to its shell prompt'
  assert_has "uncertain recovery always names the manual step" "$WT_OUT" 'attach --reattach -r /vm/repos/project task'

  # The pre-reconnect show can say detached even when the restored client is attached now.
  set_row_state suspended
  printf 'agent running, detached\n' >"$TEST_ROOT/remote-wt-state"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery uses the fresh client state" -H fakevm attach task -r /vm/repos/project
  assert_has "a client that attached during recovery was replaced" "$(cat "$TEST_ROOT/remote-log")" 'tmux detach-client -t /dev/pts/3 -E '
  printf 'agent running\n' >"$TEST_ROOT/remote-wt-state"

  # A connected row leaves the relay untouched, even when ss would name an sshd.
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "an already connected row is selected" -H fakevm attach task -r /vm/repos/project
  assert_lacks "connected row made no ss check" "$(cat "$TEST_ROOT/remote-log")" 'ss '
  assert_lacks "connected row made no reconnect call" "$(cat "$CMUX_LOG")" 'workspace.remote.reconnect'
  assert_has "a connected attached client was replaced" "$(cat "$TEST_ROOT/remote-log")" 'tmux detach-client -t /dev/pts/3 -E '
  assert_lacks "client replacement never typed into the row" "$(cat "$CMUX_LOG")" 'send --workspace'
  local expected_line
  eval "$(sed -n '/^tmux_cmd()/,/^}/p' "$REPO/bin/wt")"
  expected_line=$(tmux_cmd wt-project-task)
  assert_has "replacement uses tmux_cmd's exact attach line" "$(cat "$TEST_ROOT/remote-log")" "tmux detach-client -t /dev/pts/3 -E $expected_line"

  # The old client can still exist while cmux has opened a fresh shell but shows a cached agent screen.
  : >"$TEST_ROOT/remote-tmux-nonce-stale"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "a stale agent screen does not prove the active client" -H fakevm attach task -r /vm/repos/project
  assert_lacks "stale screen never replaced the abandoned pty" "$(cat "$TEST_ROOT/remote-log")" 'detach-client'
  rm "$TEST_ROOT/remote-tmux-nonce-stale"

  : >"$TEST_ROOT/remote-tmux-detach-fail"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "a failed client replacement leaves the task running" -H fakevm attach task -r /vm/repos/project
  assert_has "replacement failure is reported" "$WT_OUT" 'could not replace wt-project-task'
  assert_lacks "replacement failure never sent keys" "$(cat "$CMUX_LOG")" 'send --workspace'
  rm "$TEST_ROOT/remote-tmux-detach-fail"

  # A connected row can be a fresh shell while the old tmux client remains on another pty.
  printf 'azureuser@fakevm:~$ \n' >"$TEST_ROOT/remote-screen"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "a bare-shell row does not replace its stale client" -H fakevm attach task -r /vm/repos/project
  assert_lacks "bare-shell row left its old client alone" "$(cat "$TEST_ROOT/remote-log")" 'detach-client'
  printf 'agent still running\n' >"$TEST_ROOT/remote-screen"

  # An outdated show result is not enough to replace a client that has since detached.
  printf 'detached\n' >"$TEST_ROOT/remote-tmux"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "a session with no client is left alone" -H fakevm attach task -r /vm/repos/project
  assert_lacks "no-client session had no replacement" "$(cat "$TEST_ROOT/remote-log")" 'detach-client'
  printf 'attached\n' >"$TEST_ROOT/remote-tmux"

  # A task attach cannot target the names used by shared VM and repo shell sessions.
  local shared
  for shared in main shell-project; do
    REMOTE_WT_SESSION="$shared"
    : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
    assert_wt_fails 1 'unexpected output from fakevm' -H fakevm attach task -r /vm/repos/project
    assert_lacks "shared $shared session was not replaced" "$(cat "$TEST_ROOT/remote-log")" 'detach-client'
  done
  REMOTE_WT_SESSION=""

  # A non-sshd listener and a foreign-owned sshd both fail closed before the RPC.
  jq '(.workspaces[] | select(.id == "remote-row") | .remote.state) = "suspended"' "$WT_ROWS" >"$WT_ROWS.tmp" && mv "$WT_ROWS.tmp" "$WT_ROWS"
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  sed 's/"sshd"/"other"/' "$TEST_ROOT/remote-ss" >"$TEST_ROOT/remote-ss.tmp" && mv "$TEST_ROOT/remote-ss.tmp" "$TEST_ROOT/remote-ss"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 'manual fallback:' -H fakevm attach task -r /vm/repos/project
  assert_lacks "other listener was not killed" "$(cat "$TEST_ROOT/remote-log")" 'kill '
  assert_lacks "failed check did not reconnect" "$(cat "$CMUX_LOG")" 'workspace.remote.reconnect'
  assert_has "the relay script's own reason reached wt's output" "$WT_OUT" "could not clear remote-row's stale relay on fakevm: listener on 65353 is not sshd"
  assert_has "the fallback names a step that can work" "$WT_OUT" 'press Reconnect on the row or re-run: wt -H fakevm attach -r /vm/repos/project task'
  sed 's/"other"/"sshd"/' "$TEST_ROOT/remote-ss" >"$TEST_ROOT/remote-ss.tmp" && mv "$TEST_ROOT/remote-ss.tmp" "$TEST_ROOT/remote-ss"
  printf 'sshd:%s\n' "$((uid + 1))" >"$TEST_ROOT/remote-ps"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 'manual fallback:' -H fakevm attach task -r /vm/repos/project
  assert_lacks "foreign-owned sshd was not killed" "$(cat "$TEST_ROOT/remote-log")" 'kill '
  assert_lacks "foreign-owned sshd did not reconnect" "$(cat "$CMUX_LOG")" 'workspace.remote.reconnect'
  assert_has "foreign-owned sshd names its reason" "$WT_OUT" 'listener on 65353 is not a user-owned sshd'

  # OpenSSH 9.8+ names the session sshd-session, and one of them may hold the port on IPv6 and IPv4.
  printf 'sshd-session:%s\n' "$uid" >"$TEST_ROOT/remote-ps"
  printf '%s\n' 'LISTEN 0 128 [::1]:65353 [::]:* users:(("sshd-session",pid=4242,fd=9))' \
    'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd-session",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "an sshd-session relay on IPv6 and IPv4 is recovered" -H fakevm attach task -r /vm/repos/project
  assert_has "the sshd-session was stopped" "$(cat "$TEST_ROOT/remote-log")" 'kill -TERM 4242'
  assert_has "one PID on two addresses is one listener" "$WT_OUT" 'relay: stopped stale user sshd 4242 on fakevm port 65353'
  assert_lacks "an IPv6 listener is not reported free" "$WT_OUT" 'was free'

  # A wildcard listener counts too, and a login banner ahead of the script's result is ignored.
  jq '(.workspaces[] | select(.id == "remote-row") | .remote.state) = "suspended"' "$WT_ROWS" >"$WT_ROWS.tmp" && mv "$WT_ROWS.tmp" "$WT_ROWS"
  printf 'sshd:%s\n' "$uid" >"$TEST_ROOT/remote-ps"
  printf '%s\n' 'LISTEN 0 128 0.0.0.0:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf 'Last login: Tue Sep 29 09:00:00 2026 from 198.51.100.7\n' >"$TEST_ROOT/remote-ssh-noise"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "a wildcard listener behind a login banner is recovered" -H fakevm attach task -r /vm/repos/project
  assert_has "the wildcard listener was stopped" "$(cat "$TEST_ROOT/remote-log")" 'kill -TERM 4242'
  assert_has "the result line was found behind the banner" "$WT_OUT" 'relay: stopped stale user sshd 4242 on fakevm port 65353'
  assert_lacks "the banner was not taken for the result" "$WT_OUT" 'unexpected relay check'
  rm -f "$TEST_ROOT/remote-ssh-noise"

  # Two processes on the port's two addresses are not one stale forward.
  jq '(.workspaces[] | select(.id == "remote-row") | .remote.state) = "suspended"' "$WT_ROWS" >"$WT_ROWS.tmp" && mv "$WT_ROWS.tmp" "$WT_ROWS"
  printf '%s\n' 'LISTEN 0 128 [::1]:65353 [::]:* users:(("sshd",pid=4343,fd=9))' \
    'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 'multiple listeners on 65353' -H fakevm attach task -r /vm/repos/project
  assert_lacks "two listening PIDs were not killed" "$(cat "$TEST_ROOT/remote-log")" 'kill '

  # A session from the Mac's current address may be live: an IPv4-mapped peer is still that address.
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf '%s\n' '0 0 [::ffff:10.0.0.4]:22 [::ffff:203.0.113.9]:51000 users:(("sshd",pid=4242,fd=4))' \
    '0 0 10.0.0.4:22 203.0.113.9:50000 users:(("sshd",pid=5000,fd=4))' >"$TEST_ROOT/remote-ss-est"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 "sshd 4242 holding relay port 65353 is connected from this Mac's current address (203.0.113.9); it may still be live" \
    -H fakevm attach task -r /vm/repos/project
  assert_lacks "a possibly live session was not killed" "$(cat "$TEST_ROOT/remote-log")" 'kill '
  assert_lacks "a possibly live session did not reconnect" "$(cat "$CMUX_LOG")" 'workspace.remote.reconnect'

  # No connection for that PID, even through sudo, proves nothing about staleness.
  printf '%s\n' '0 0 10.0.0.4:22 203.0.113.9:50000 users:(("sshd",pid=5000,fd=4))' >"$TEST_ROOT/remote-ss-est"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 "cannot find sshd 4242's SSH connection on port 22" -H fakevm attach task -r /vm/repos/project
  assert_has "the missing connection was looked for with sudo" "$(cat "$TEST_ROOT/remote-log")" 'sudo -n ss -H -tnp state established ( sport = :22 )'
  assert_lacks "an unproven session was not killed" "$(cat "$TEST_ROOT/remote-log")" 'kill '

  # Without SSH_CONNECTION there is no current address to compare with.
  printf '%s\n' '0 0 10.0.0.4:22 198.51.100.7:40000 users:(("sshd",pid=4242,fd=4),("sshd",pid=4200,fd=4))' \
    '0 0 10.0.0.4:22 203.0.113.9:50000 users:(("sshd",pid=5000,fd=4))' >"$TEST_ROOT/remote-ss-est"
  : >"$TEST_ROOT/remote-ssh-conn"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 'SSH_CONNECTION is empty' -H fakevm attach task -r /vm/repos/project
  assert_lacks "no SSH_CONNECTION, no kill" "$(cat "$TEST_ROOT/remote-log")" 'kill '
  rm -f "$TEST_ROOT/remote-ssh-conn"

  # ssh's own 255 on the relay call is a dropped VM, not a refusal by the script.
  : >"$TEST_ROOT/remote-ssh-drop"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 'host unreachable: is the VM running? (ssh fakevm)' -H fakevm attach task -r /vm/repos/project
  assert_lacks "a transport failure is not misreported as a relay refusal" "$WT_OUT" 'manual fallback:'
  assert_lacks "a transport failure made no kill" "$(cat "$TEST_ROOT/remote-log")" 'kill '
  assert_lacks "a transport failure did not reconnect" "$(cat "$CMUX_LOG")" 'workspace.remote.reconnect'
  rm -f "$TEST_ROOT/remote-ssh-drop"

  # cmux may still say suspended just after the RPC; connecting then suspended again is it giving up.
  printf 'suspended\nconnecting\nsuspended\n' >"$TEST_ROOT/reconnect-states"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 'went back to suspended after cmux tried to reconnect it' -H fakevm attach task -r /vm/repos/project
  assert_has "the give-up names the last state" "$WT_OUT" 'last state: suspended'
  assert_has "the give-up carries cmux's reconnect reply" "$WT_OUT" '"stub":"reconnect requested"'
  assert_eq "polling stopped at the second suspended" 3 "$(awk '/^rpc workspace.remote.reconnect / { on = 1; next } on && /^workspace list/' "$CMUX_LOG" | grep -c . || true)"
  assert_has "the give-up names a step that can work" "$WT_OUT" 'press Reconnect on the row or re-run: wt -H fakevm attach -r /vm/repos/project task'
  rm -f "$TEST_ROOT/reconnect-states" "$TEST_ROOT/state-queue"

  # The show before the reconnect still lists the abandoned client; only the VM probe made after it can say
  # detached. This proves recovery does not rely on its pre-reconnect snapshot.
  printf 'sshd:%s\n' "$uid" >"$TEST_ROOT/remote-ps"
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:*' >"$TEST_ROOT/remote-ss-user"
  printf '%s\n' '0 0 10.0.0.4:22 198.51.100.7:40000' '0 0 10.0.0.4:22 203.0.113.9:50000' >"$TEST_ROOT/remote-ss-est-user"
  printf 'agent running\n' >"$TEST_ROOT/remote-wt-state"
  printf 'detached\n' >"$TEST_ROOT/remote-tmux"
  printf 'azureuser@fakevm:~$ \n' >"$TEST_ROOT/remote-screen"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery reattaches a proven bare shell" -H fakevm attach task -r /vm/repos/project
  assert_has "hidden PID was inspected with sudo" "$(cat "$TEST_ROOT/remote-log")" 'sudo -n ss -H -ltnp sport = :65353'
  assert_has "hidden connection PID was inspected with sudo" "$(cat "$TEST_ROOT/remote-log")" 'sudo -n ss -H -tnp state established ( sport = :22 )'
  assert_eq "the VM's wt show ran once, before the reconnect, not per tick" 1 "$(grep -c '^show show task -r /vm/repos/project$' "$TEST_ROOT/remote-log" || true)"
  assert_eq "the VM's tmux was asked once, after the relay was cleared" 1 "$(awk '/^kill / { k = 1 } k && /^tmux has-session /' "$TEST_ROOT/remote-log" | grep -c . || true)"
  assert_has "the probe lists that one session's clients" "$(cat "$TEST_ROOT/remote-log")" 'tmux list-clients -t =wt-project-task'
  assert_eq "the proven row got one tmux command" 1 "$(tmux_sends)"
  assert_eq "the proven row got one return" 1 "$(grep -c '^send-key --workspace remote-row enter$' "$CMUX_LOG" || true)"
  assert_has "the recovered row was re-attached" "$WT_OUT" '(re-attached)'
  rm -f "$TEST_ROOT/remote-ss-est-user"

  # The row may become connected before the login shell paints its prompt. The fourth tick sees it, and only
  # that tick asks the VM: the screen, a local read, comes first.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  for n in 1 2 3; do printf 'connecting\n' >"$TEST_ROOT/remote-screen-queue/$n"; done
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery waits for a late shell prompt" -H fakevm attach task -r /vm/repos/project
  assert_eq "the late prompt got three waits and was sent on the fourth read" 4 "$(screen_reads)"
  assert_eq "only the tick that showed a prompt asked the VM" 1 "$(vm_probes)"
  assert_eq "the late shell got one tmux command" 1 "$(tmux_sends)"
  assert_eq "the late shell got one return" 1 "$(grep -c '^send-key --workspace remote-row enter$' "$CMUX_LOG" || true)"
  assert_has "the late shell was re-attached" "$WT_OUT" '(re-attached)'

  # A prompt that appears after the polling deadline still gets a useful manual command.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  for n in 1 2 3 4 5; do printf 'connecting\n' >"$TEST_ROOT/remote-screen-queue/$n"; done
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery reaches its prompt deadline" -H fakevm attach task -r /vm/repos/project
  assert_eq "prompt polling plus the replacement guard were bounded" 6 "$(screen_reads)"
  assert_eq "ticks with no prompt asked the VM nothing" 0 "$(vm_probes)"
  assert_lacks "late-after-deadline prompt got no send" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_has "deadline prints explicit re-attach command" "$WT_OUT" 'attach --reattach -r /vm/repos/project task'

  # A TUI footer ending in % names no user@host; it must never cause a probe or a send.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf 'Context 100%%\n' >"$TEST_ROOT/remote-screen"
  for n in 1 2 3 4 5; do rm -f "$TEST_ROOT/remote-screen-queue/$n"; done
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery selects a row with a percent footer" -H fakevm attach task -r /vm/repos/project
  assert_eq "the percent footer never asked the VM" 0 "$(vm_probes)"
  assert_lacks "the percent footer did not trigger a send" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_has "the percent footer row was selected" "$WT_OUT" '(selected)'
  assert_has "the percent footer gets a manual command" "$WT_OUT" 'attach --reattach -r /vm/repos/project task'

  # Even a shell prompt is insufficient while the VM lists a tmux client on the session, or has no such session.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf 'attached\n' >"$TEST_ROOT/remote-tmux"
  printf 'missing\n' >"$TEST_ROOT/remote-tmux-queue"
  printf 'azureuser@fakevm:~$ \n' >"$TEST_ROOT/remote-screen"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery respects an attached tmux client" -H fakevm attach task -r /vm/repos/project
  assert_eq "every prompt tick asked the VM again" 5 "$(vm_probes)"
  assert_lacks "an attached tmux client got no send" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_has "attached-state uncertainty gets a manual command" "$WT_OUT" 'attach --reattach -r /vm/repos/project task'

  # A client can re-attach on the VM after the prompt was read, and the screen then shows the agent. The probe
  # just before the send is what sees it; the later footer ticks ask nothing.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf 'azureuser@fakevm:~$ \n' >"$TEST_ROOT/remote-screen-queue/1"
  printf 'Context 100%%\n' >"$TEST_ROOT/remote-screen"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery rechecks the VM just before sending" -H fakevm attach task -r /vm/repos/project
  assert_eq "only the prompt tick asked the VM" 1 "$(vm_probes)"
  assert_lacks "a changed screen got no send" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_has "changed-screen uncertainty gets a manual command" "$WT_OUT" 'attach --reattach -r /vm/repos/project task'
  rm -f "$TEST_ROOT/remote-screen-queue/1"

  # Each prompt tick asks the VM afresh: a client listed at the first probe and gone by the second gets one
  # send, on the second tick.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf 'azureuser@fakevm:~$ \n' >"$TEST_ROOT/remote-screen"
  printf 'detached\n' >"$TEST_ROOT/remote-tmux"
  printf 'attached\n' >"$TEST_ROOT/remote-tmux-queue"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery asks the VM again on the next tick" -H fakevm attach task -r /vm/repos/project
  assert_eq "two prompt ticks made two probes" 2 "$(vm_probes)"
  assert_eq "the send came on the second read" 2 "$(screen_reads)"
  assert_eq "the client that left got one tmux command" 1 "$(tmux_sends)"

  # A second dropout while the prompt is up stops the probe and the send: the row must still be connected
  # before the VM is asked.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf '1 suspended\n' >"$TEST_ROOT/remote-state-at-read"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery rechecks connected state before sending" -H fakevm attach task -r /vm/repos/project
  assert_eq "a suspended row's prompt ticks asked the VM nothing" 0 "$(vm_probes)"
  assert_lacks "a second dropout got no send" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_has "second-dropout uncertainty gets a manual command" "$WT_OUT" 'attach --reattach -r /vm/repos/project task'

  # …and when cmux connects it again within the ticks, the first connected tick asks the VM and sends.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf '1 suspended\n3 connected\n' >"$TEST_ROOT/remote-state-at-read"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "recovery re-attaches once the row is connected again" -H fakevm attach task -r /vm/repos/project
  assert_eq "two suspended ticks made no probe and the connected one made one" 1 "$(vm_probes)"
  assert_eq "the send came on the third read" 3 "$(screen_reads)"
  assert_eq "the row connected again got one tmux command" 1 "$(tmux_sends)"
  assert_has "the row connected again was re-attached" "$WT_OUT" '(re-attached)'
  rm -f "$TEST_ROOT/remote-state-at-read"

  # Automatic recovery knows the same prompt shapes as --reattach: the repo's two-line zsh theme, whose
  # second line is its % alone, and RHEL's bracketed one.
  for screen in $'azureuser@fakevm [12:00:00] [~/repo] git:(main)\n% ' '[azureuser@fakevm ~]$ '; do
    shape=$(printf '%s' "$screen" | tr '\n' '|')
    set_row_state suspended
    printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
    printf '%s\n' "$screen" >"$TEST_ROOT/remote-screen"
    rm -f "$TEST_ROOT/remote-screen-count"
    : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
    assert_wt_ok "recovery re-attaches at '$shape'" -H fakevm attach task -r /vm/repos/project
    assert_eq "recovery at '$shape' typed one tmux command" 1 "$(tmux_sends)"
    assert_has "recovery at '$shape' says re-attached" "$WT_OUT" '(re-attached)'
  done

  # --reattach on a suspended row is the user's word about a screen seen before the reconnect: it waits for
  # the new shell's prompt, and still needs the row connected and the VM's session detached.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  for n in 1 2; do printf 'Context 100%%\n' >"$TEST_ROOT/remote-screen-queue/$n"; done   # the pre-suspension screen
  printf 'azureuser@fakevm:~$ \n' >"$TEST_ROOT/remote-screen"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "--reattach on a suspended row waits for its new shell" -H fakevm attach task -r /vm/repos/project --reattach
  assert_has "--reattach reconnected that row first" "$(cat "$CMUX_LOG")" 'rpc workspace.remote.reconnect {"workspace_id":"remote-row"}'
  assert_eq "--reattach sent nothing until the third read showed a prompt" 3 "$(screen_reads)"
  assert_eq "--reattach asked the VM once, on that tick" 1 "$(vm_probes)"
  assert_eq "--reattach after recovery typed one tmux command" 1 "$(tmux_sends)"
  assert_has "--reattach after recovery says re-attached" "$WT_OUT" '(re-attached)'
  for n in 1 2; do rm -f "$TEST_ROOT/remote-screen-queue/$n"; done

  # …and while the VM still lists a client it sends nothing, leaves the row selected and says how to re-run.
  set_row_state suspended
  printf '%s\n' 'LISTEN 0 128 127.0.0.1:65353 0.0.0.0:* users:(("sshd",pid=4242,fd=8))' >"$TEST_ROOT/remote-ss"
  printf 'attached\n' >"$TEST_ROOT/remote-tmux"
  rm -f "$TEST_ROOT/remote-screen-count"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_fails 1 'reconnected, but its shell prompt and a detached VM session were not both confirmed' \
    -H fakevm attach task -r /vm/repos/project --reattach
  assert_lacks "--reattach on an attached VM session typed nothing" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_eq "--reattach asked the VM on each of its five ticks" 5 "$(vm_probes)"
  assert_has "--reattach selected the row to look at" "$(cat "$CMUX_LOG")" 'workspace select remote-row'
  assert_has "--reattach names the re-run" "$WT_OUT" 're-run: wt -H fakevm attach --reattach -r /vm/repos/project task'

  # A row that never dropped, whose VM reports its session detached, gets the tmux line through the same
  # helper and no probe. A send that fails there names the line to type by hand.
  set_row_state connected
  printf 'agent running, detached\n' >"$TEST_ROOT/remote-wt-state"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "a connected row with a detached session is re-attached" -H fakevm attach task -r /vm/repos/project
  assert_eq "the detached session got one tmux command" 1 "$(tmux_sends)"
  assert_lacks "a detached session was not replaced" "$(cat "$TEST_ROOT/remote-log")" 'detach-client'
  assert_eq "the detached session got one return" 1 "$(grep -c '^send-key --workspace remote-row enter$' "$CMUX_LOG" || true)"
  assert_lacks "the VM's own detached report needed no probe" "$(cat "$TEST_ROOT/remote-log")" 'tmux has-session'
  : >"$TEST_ROOT/cmux-send-fail"
  assert_wt_fails 1 "cmux send failed for remote-row; type this in the row instead: tmux attach -d -t '=wt-project-task'" \
    -H fakevm attach task -r /vm/repos/project
  rm -f "$TEST_ROOT/cmux-send-fail"
  printf 'agent running\n' >"$TEST_ROOT/remote-wt-state"

  # Explicit --reattach on a row that did not drop takes the user's word about the VM, which still lists the
  # abandoned client the flag exists for, so the screen is its only check, and every common prompt passes it.
  printf 'azureuser@fakevm:~$ \n' >"$TEST_ROOT/remote-screen"
  : >"$TEST_ROOT/remote-log"; : >"$CMUX_LOG"
  assert_wt_ok "explicit --reattach still sends tmux" -H fakevm attach task -r /vm/repos/project --reattach
  assert_has "explicit re-attach selected the row" "$(cat "$CMUX_LOG")" 'workspace select remote-row'
  assert_eq "explicit re-attach sent one tmux command" 1 "$(tmux_sends)"
  for screen in 'azureuser@fakevm:~/repo$ ' '(base) azureuser@fakevm:~$ ' '[azureuser@fakevm ~]$ ' 'root@fakevm:/# ' \
      $'azureuser@fakevm [12:00:00] [~/repo] git:(main)\n% '; do
    shape=$(printf '%s' "$screen" | tr '\n' '|')
    printf '%s\n' "$screen" >"$TEST_ROOT/remote-screen"
    : >"$CMUX_LOG"
    assert_wt_ok "explicit --reattach accepts '$shape'" -H fakevm attach task -r /vm/repos/project --reattach
    assert_eq "explicit --reattach at '$shape' typed one tmux command" 1 "$(tmux_sends)"
  done
  assert_lacks "explicit --reattach on a connected row never asked the VM" "$(cat "$TEST_ROOT/remote-log")" 'tmux has-session'
  printf 'agent still running\n' >"$TEST_ROOT/remote-screen"
  : >"$CMUX_LOG"
  assert_wt_fails 1 'does not end at a shell prompt' -H fakevm attach task -r /vm/repos/project --reattach
  assert_lacks "the screen guard prevented typing" "$(cat "$CMUX_LOG")" 'send --workspace'
  printf 'Context 100%%\n' >"$TEST_ROOT/remote-screen"
  : >"$CMUX_LOG"
  assert_wt_fails 1 'does not end at a shell prompt' -H fakevm attach task -r /vm/repos/project --reattach
  assert_lacks "the explicit percent-footer guard prevented typing" "$(cat "$CMUX_LOG")" 'send --workspace'
  # A prompt character alone is a prompt only under a line that names user@host.
  printf 'build finished\n%% \n' >"$TEST_ROOT/remote-screen"
  : >"$CMUX_LOG"
  assert_wt_fails 1 'does not end at a shell prompt' -H fakevm attach task -r /vm/repos/project --reattach
  assert_lacks "a lone % under plain output prevented typing" "$(cat "$CMUX_LOG")" 'send --workspace'
  assert_has "the refusal says what a prompt must name" "$WT_OUT" 'naming user@host'
  WT_PATH_PREFIX=""
  end_scenario
}

# 11. The invariants two files promise each other in comments and nothing enforced: bin/cmux-hook's copy
# of tmux_cmd must match bin/wt's line for line (the command is the one bin/cmux-hook's own comment gives), and
# the two must merge the per-window row lists identically. First, though, the promise bin/wt's own shebang
# makes: it must PARSE under /bin/bash, which on a Mac is 3.2.57 and once choked on a case pattern inside a
# heredoc inside $(…) that every newer bash accepted — a whole-suite run under WT_BASH=/bin/bash catches
# that too, but only when someone remembers to make one. This check is made on every run, whatever runs it.
scenario_shared_tmux_cmd() {
  begin_scenario "11. bin/wt parses under /bin/bash, and agrees with bin/cmux-hook on tmux_cmd and the row list"
  local a b sys=/bin/bash out=""
  out=$("$sys" -n "$REPO/bin/wt" 2>&1) || out="${out:-syntax error} (exit $?)"
  # shellcheck disable=SC2016   # $BASH_VERSION is for THAT bash to expand, not this one
  assert_eq "bin/wt parses under $sys $("$sys" -c 'echo "$BASH_VERSION"')" "" "$out"
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
  begin_scenario "12. lib_cleanup refuses a scratch root it must not remove"
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
FIXED_ASSERTIONS=584
# The assertions that only a Mac can make, counted apart so the total is right on both platforms.
# is_remote() (bin/wt:~88) is true on any machine that is not a Darwin one, and bin/wt has no FORCE_OS to
# lie to it with — install.sh has one, but adding the equivalent here would be a change to the code under
# test. So on Linux: scenario 8 is skipped whole (there, `wt new` without --no-workspace asks the Mac for a
# row over the relay and never consults cmux, and check_identity asks tmux instead of the row list, so
# neither the "row belongs to another repo" refusal nor cmux_row_field's local-row preference is reachable),
# and scenario 4 does not assert that `wt show` prints no session: line, because there it prints one, nor
# run `wt open`, which there asks the Mac over the relay instead of running `code`.
DARWIN_ASSERTIONS=31

# shellcheck disable=SC2016   # $BASH_VERSION below is for the OTHER bash to expand, not this one
main() {
  echo "wt smoke test: repo $REPO, scratch root $TEST_ROOT"
  echo "  this suite under bash ${BASH_VERSION}; bin/wt under $WT_BASH" \
       "($("$WT_BASH" -c 'echo "$BASH_VERSION"'))"
  scenario_guard
  scenario_new_and_sidecar
  scenario_task_model
  scenario_base_resolution
  scenario_names_and_collisions
  scenario_list_show_path
  scenario_include_and_setup
  scenario_rm_refusals
  scenario_squash_merge
  scenario_prune_agrees
  scenario_self_rm_vm
  scenario_cmux
  scenario_host_args
  scenario_suspended_attach
  scenario_shared_tmux_cmd
  scenario_cleanup_guard
  lib_summary "$(expected_assertions)"
}

main "$@"
