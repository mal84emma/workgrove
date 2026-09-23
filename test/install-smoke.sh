#!/usr/bin/env bash
#
# test/install-smoke.sh: run install.sh against throwaway HOMEs and assert what it did.
#   bash test/install-smoke.sh          (KEEP=1 leaves the scratch homes behind for inspection)
#   INSTALL_BASH=/bin/bash bash test/install-smoke.sh    (which bash runs install.sh — see below)
#
# Two interpreters, and they are not the same question. This file is run by whatever bash invoked it;
# install.sh is run by $INSTALL_BASH, printed in the header line. They default to the same `bash` from PATH,
# which on the author's Mac is Homebrew's 5.x — but a fresh Mac has no bash but /bin/bash 3.2.57, and
# docs/new-mac.md tells the user to run `bash install.sh`, so 3.2 is the only interpreter install.sh ever
# gets there. Run this file both ways, or the one that matters goes untested under the one that matters.
#
# Why this file exists: install.sh's five opinionated files (~/.zshrc, ~/.gitconfig, ~/.tmux.conf,
# ~/.claude/keybindings.json, ~/.claude/statusline-command.sh) are opt-in, as are the UI keys of
# ~/.claude/settings.json behind --with-claude-ui, and every machine the author owns is fully opted in — so
# the no-flags path, the one every stranger gets, is the one path the author
# never runs and the one most likely to rot. These scenarios exercise it, the flags, the stickiness rule
# and idempotence, and above all they check that a default install leaves a stranger's own dotfiles alone.
# Beyond that they cover the things install.sh REFUSES to do — the ones that protect a machine it does not
# own: a dangling symlink it would otherwise write through, a file a dotfile manager owns, a setting the
# user already made, a link into a second checkout of this repo.
#
# The Linux-only steps — hook_bashrc above all, and ask_vm_host, record_repos_dir and copy_config's two
# platform filters — are unreachable on a Mac, which is where this suite is run. Scenario 16 drives them
# through install.sh's FORCE_OS variable, which exists for that and for nothing else. Everything else a
# green run does NOT exercise is the network: install_zsh_plugins' clone, which the fixtures pre-empt.
#
# The absolute rule: nothing here may touch anything under the real $HOME. Every scenario runs install.sh
# with HOME pointed into a fresh mktemp -d, guard_scratch_home refuses at the start of each one if that
# HOME resolves anywhere under the real home, and run_install pins XDG_CONFIG_HOME to the scratch HOME and
# unsets GIT_CONFIG_GLOBAL and ZSH_CUSTOM, the variables that would otherwise let a write escape it anyway.
# No scenario needs the network or sudo: the only network step install.sh has is the plugin clone, and the
# fixtures pre-create the plugin directories so it never fires.
#
# Assertions are silent when they hold and loud when they do not; the script prints one line per scenario
# and a pass/fail count, and exits non-zero if any assertion failed.
#
# The count itself is asserted, against expected_assertions below. A mutation once dropped it from 323 to 318
# without a single failure, because a scenario's loop skipped its assertions instead of failing them: a
# suite that can quietly stop checking things is not a suite. Every loop over a directory that install.sh
# was supposed to create therefore asserts rather than `continue`s.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"   # -P: install.sh records the physical path, so compare like for like
OS="$(uname -s)"
# The interpreter install.sh itself is run under; see the header. Resolved to an absolute path here, once,
# because scenario 14b hands install.sh a PATH with almost nothing on it and `env bash …` would then fail to
# find bash itself rather than testing what it meant to.
INSTALL_BASH="${INSTALL_BASH:-bash}"
INSTALL_BASH_ABS="$(command -v "$INSTALL_BASH" 2>/dev/null || true)"
if [[ -z "$INSTALL_BASH_ABS" ]]; then
  echo "ABORT: INSTALL_BASH='$INSTALL_BASH' is not on PATH" >&2
  exit 1
fi
INSTALL_BASH="$INSTALL_BASH_ABS"
# Resolved before anything else runs, and while HOME is still the real one: everything below compares
# against this, so it must be captured before any scenario can have changed HOME.
REAL_HOME="$(cd "$HOME" && pwd -P)"
VM_HOST=smoke-vm                     # ask_vm_host refuses on Linux without this; ignored on a Mac

PASS=0
FAIL=0
SCENARIO="(startup)"
SCENARIO_FAILS=0

# ---------------------------------------------------------------------------- scratch home safety

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/install-smoke.XXXXXX")"
TEST_ROOT_REAL="$(cd "$TEST_ROOT" && pwd -P)"

case "$TEST_ROOT_REAL/" in
  "$REAL_HOME"/*)
    echo "ABORT: mktemp put the test root inside the real home ($TEST_ROOT_REAL); set TMPDIR elsewhere" >&2
    exit 1 ;;
esac

cleanup() {
  if [[ -n "${KEEP:-}" || $FAIL -gt 0 ]]; then
    echo "scratch homes kept in $TEST_ROOT"
    return 0
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# guard_scratch_home <dir>: the check this whole file is built around. install.sh writes dotfiles, runs
# `git config --global` and moves whatever is in the way into ~/.workstation-backup, so a HOME that
# resolved under the real one would rewrite the author's machine. Called at the start of every scenario
# and again from run_install rather than once at the top, so a future edit that builds a home some other
# way still trips it. Aborts the run outright — this is not a countable assertion failure.
guard_scratch_home() {
  local h="$1" resolved
  if [[ ! -d "$h" ]]; then
    echo "ABORT: scratch HOME '$h' is not a directory" >&2
    exit 1
  fi
  resolved="$(cd "$h" && pwd -P)"
  case "$resolved/" in
    "$REAL_HOME"/*)
      echo "ABORT: scratch HOME $resolved is inside the real home $REAL_HOME" >&2
      exit 1 ;;
  esac
  case "$resolved/" in
    "$TEST_ROOT_REAL"/*) : ;;
    *)
      echo "ABORT: scratch HOME $resolved is outside this run's test root $TEST_ROOT_REAL" >&2
      exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------- assertions

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

# assert_link <home> <home-relative dst> <repo-relative src>: ~/dst is a symlink to <repo>/src.
assert_link() {
  local p="$1/$2" want="$REPO/$3" got
  if [[ ! -L "$p" ]]; then
    fail "at ~/$2: expected a symlink -> $want, found $(describe "$p")"
    return 0
  fi
  got="$(readlink "$p")"
  if [[ "$got" != "$want" ]]; then
    fail "at ~/$2: expected a symlink -> $want, found a symlink -> $got"
    return 0
  fi
  pass
}

# assert_absent <home> <rel>: nothing there at all, not even a dangling link.
assert_absent() {
  local p="$1/$2"
  if [[ -e "$p" || -L "$p" ]]; then
    fail "at ~/$2: expected nothing, found $(describe "$p")"
    return 0
  fi
  pass
}

# assert_regular <home> <rel>: a real file, not a symlink — the shape a stranger's own dotfile must keep.
assert_regular() {
  local p="$1/$2"
  if [[ -L "$p" || ! -f "$p" ]]; then
    fail "at ~/$2: expected a regular file, found $(describe "$p")"
    return 0
  fi
  pass
}

# assert_not_link <home> <rel>: weaker than assert_absent, for a path a fallback legitimately creates.
assert_not_link() {
  local p="$1/$2"
  if [[ -L "$p" ]]; then
    fail "at ~/$2: expected not a symlink, found $(describe "$p")"
    return 0
  fi
  pass
}

# assert_not_link_into_repo <home> <rel>: whatever is there, it is not a link into THIS repo. Weaker than
# assert_absent on purpose: what matters for a destination install.sh must not take over is only that it did
# not take it over, not which of "untouched" or "stashed as a retired link" it ended up as.
assert_not_link_into_repo() {
  local p="$1/$2" t=""
  if [[ -L "$p" ]]; then
    t="$(readlink "$p")"
  fi
  case "$t" in
    "$REPO"/*)
      fail "at ~/$2: expected NOT a link into $REPO, found a symlink -> $t"
      return 0 ;;
  esac
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

# count_matches <file> <fixed string>: grep -c exits 1 on no match, which set -e would take badly.
count_matches() {
  grep -cF -- "$2" "$1" 2>/dev/null || true
}

# line_count <file>: lines, not newlines. wc -l counts newlines, so a file whose last line has none reads
# one short — and that is exactly the file append_line's guard exists for, so counting it wrong is how a
# suite claims to check the append and does not.
line_count() {
  local n
  n="$(wc -l <"$1")"
  n=$((n))
  if [[ -s "$1" && -n "$(tail -c 1 "$1")" ]]; then
    n=$((n + 1))
  fi
  echo "$n"
}

# assert_mode <home> <rel> <mode>: the permission bits of a file install.sh created. The idempotence
# manifest cannot do this job — it only ever compares run 1 of an install against run 2 of the same
# install, so a chmod regression is identical in both and passes.
assert_mode() {
  local p="$1/$2"
  if [[ ! -f "$p" ]]; then
    fail "at ~/$2: expected a regular file with mode $3, found $(describe "$p")"
    return 0
  fi
  assert_eq "the mode of ~/$2" "$3" "$(file_mode "$p")"
}

# assert_same_bytes <what> <file a> <file b>: two paths with identical contents. Used for the copies that
# are installed with a plain `cp`: asserting only that they EXIST passes on a zero-byte file, and on a Mac
# — the author's own machine — the cp branch is the one both Codex files take.
assert_same_bytes() {
  local a b
  if [[ ! -f "$2" || ! -f "$3" ]]; then
    fail "$1: expected two regular files, found $(describe "$2") and $(describe "$3")"
    return 0
  fi
  a="$(cksum <"$2")"
  b="$(cksum <"$3")"
  if [[ "$a" != "$b" ]]; then
    fail "$1: $2 and $3 differ"
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

# ---------------------------------------------------------------------------- fixtures

# new_home: a fresh scratch HOME carrying only what install.sh refuses to run without — a git identity in
# ~/.gitconfig.local, which require_git_identity reads directly. Everything else a scenario needs it seeds.
# The guard comes before the first write, not after: seeding a fixture is already a write into whatever
# directory this returns, so an edit that changed how the home is made would otherwise put a file in the
# real home before any caller got the chance to check.
new_home() {
  local h
  h="$(mktemp -d "$TEST_ROOT/home.XXXXXX")"
  guard_scratch_home "$h"
  printf '[user]\n\tname = Smoke Test\n\temail = smoke@example.invalid\n' >"$h/.gitconfig.local"
  printf '%s\n' "$h"
}

# seed_oh_my_zsh <home>: require_oh_my_zsh wants the oh-my-zsh.sh FILE, not just the directory, and
# install_zsh_plugins clones the two plugins over the network unless their directories already exist.
# Any scenario that opts ~/.zshrc in needs both, and pre-creating the plugin dirs is what keeps this
# whole suite offline.
seed_oh_my_zsh() {
  local h="$1" p
  guard_scratch_home "$h"
  mkdir -p "$h/.oh-my-zsh/custom/themes"
  printf '# smoke fixture\n' >"$h/.oh-my-zsh/oh-my-zsh.sh"
  for p in zsh-autosuggestions zsh-syntax-highlighting; do
    mkdir -p "$h/.oh-my-zsh/custom/plugins/$p"
  done
}

# seed_opinionated_originals <home>: one distinctive regular file at each of the five opt-in destinations,
# so a run that installs them has something to stash and the backup can be checked for it.
seed_opinionated_originals() {
  local h="$1"
  guard_scratch_home "$h"
  mkdir -p "$h/.claude"
  printf '%s\n' '# STRANGER ZSHRC' 'alias notmine=true' >"$h/.zshrc"
  printf '%s\n' '[user]' '	name = Stranger' '	email = stranger@example.invalid' \
                '[alias]' '	lg = log --oneline' >"$h/.gitconfig"
  # Deliberately no final newline: a hand-edited ~/.tmux.conf routinely ends that way, and it is the only
  # shape that exercises append_line's guard. Without the guard the appended line is glued onto this one —
  # `set -g prefix C-aset -ag update-environment …` — which destroys the user's binding AND is unparseable,
  # and `grep -c` still reports exactly one update-environment line, so the obvious assertion cannot see it.
  printf '%s\n%s' '# STRANGER TMUX' 'set -g prefix C-a' >"$h/.tmux.conf"
  printf '%s\n' '{ "stranger": true }' >"$h/.claude/keybindings.json"
  printf '%s\n' '#!/bin/sh' 'echo STRANGER STATUSLINE' >"$h/.claude/statusline-command.sh"
}

# other_checkout: a SECOND clone of this repo the user deliberately keeps — the live link into it is, in
# install.sh's own words, "the one link this script must never touch". Only the paths matter, so it is a
# skeleton rather than a copy, and it lives inside TEST_ROOT: guard_scratch_home constrains $HOME, not where
# a symlink under it points, so anything a scenario tempts install.sh into writing must be in here too.
OTHER_CHECKOUT="$TEST_ROOT/other-checkout"
seed_other_checkout() {
  mkdir -p "$OTHER_CHECKOUT/home"
  printf '%s\n' '# THE OTHER CHECKOUT ZSHRC' >"$OTHER_CHECKOUT/home/.zshrc"
}

# seed_manager <home>: a dotfiles repo of the user's own, with a file at each of the three paths install.sh
# appends to or edits. One per scenario, inside that scenario's HOME the way ~/dotfiles usually is, so a
# scenario that provoked a write into it cannot be masked by another scenario's fixture.
seed_manager() {
  local h="$1"
  guard_scratch_home "$h"
  mkdir -p "$h/dotfiles"
  printf '%s\n' '# THE MANAGER TMUX CONF' 'set -g mouse on' >"$h/dotfiles/tmux.conf"
  printf '[core]\n\tpager = delta\n' >"$h/dotfiles/gitconfig"      # a real tab: git has to read this one
  printf '%s\n' '# THE MANAGER BASHRC' >"$h/dotfiles/bashrc"
}

# nojq_path: a PATH carrying everything install.sh shells out to EXCEPT jq, built once. require_jq's refusal
# is otherwise untestable — and with it neutered, copy_config runs jq that is not there and the run dies
# mid-install instead of before it.
NOJQ_BIN="$TEST_ROOT/nojq-bin"
nojq_path() {
  local c t
  if [[ ! -d "$NOJQ_BIN" ]]; then
    mkdir -p "$NOJQ_BIN"
    for c in awk basename cat chmod cp date dirname find git grep head ln mkdir mktemp mv readlink rm stat tail uname; do
      t="$(command -v "$c" 2>/dev/null || true)"
      if [[ -n "$t" ]]; then
        ln -s "$t" "$NOJQ_BIN/$c"
      fi
    done
  fi
  printf '%s\n' "$NOJQ_BIN"
}

# backup_dir <home>: this run's ~/.workstation-backup/<stamp>-<pid>, or "" if nothing needed backing up.
# install.sh creates it only when it is used, and never more than one per run.
backup_dir() {
  local d
  for d in "$1"/.workstation-backup/*/; do
    if [[ -d "$d" ]]; then
      printf '%s\n' "${d%/}"
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------- running install.sh

# run_install <home> <logfile> [args…]: the only place install.sh is ever invoked.
# HOME is the scratch dir; XDG_CONFIG_HOME goes with it because `git config --global` prefers
# $XDG_CONFIG_HOME/git/config when that file exists, and an inherited XDG_CONFIG_HOME would point back at
# the real home. GIT_CONFIG_GLOBAL/SYSTEM/COUNT are unset for the same reason — any of them would override
# HOME for every `git config` install.sh runs. ZSH_CUSTOM is unset because install_zsh_plugins honours it
# and an inherited one would make the plugin check look outside the scratch HOME.
# stdin is /dev/null so ask_vm_host can never block on a read.
# RUN_EXTRA_ENV adds `env` arguments — an assignment, or a -u — for ONE call, and run_install empties it
# again, so a scenario that sets it cannot leak a ZSH_CUSTOM or a FORCE_OS into the next one by forgetting.
# It is spelled ${a[@]+"${a[@]}"} throughout: an empty array under `set -u` is an error in bash 3.2, and
# 3.2 is an interpreter this suite has to run clean under.
RUN_EXTRA_ENV=()
run_install() {
  local h="$1" log="$2" rc=0 extra
  shift 2
  guard_scratch_home "$h"
  extra=(${RUN_EXTRA_ENV[@]+"${RUN_EXTRA_ENV[@]}"})
  RUN_EXTRA_ENV=()
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT -u ZSH_CUSTOM \
      HOME="$h" XDG_CONFIG_HOME="$h/.config" WT_HOST="$VM_HOST" \
      ${extra[@]+"${extra[@]}"} \
      "$INSTALL_BASH" "$REPO/install.sh" "$@" >"$log" 2>&1 </dev/null || rc=$?
  return "$rc"
}

# assert_install_fails <home> <log> <expected rc> <fixed string> [args…]: the other half of assert_install_ok.
# Every refusal install.sh makes is supposed to be made BEFORE anything moves, so each caller also asserts
# that the HOME is untouched; that is the part a mutation removing require_plain_file would otherwise pass.
assert_install_fails() {
  local h="$1" log="$2" want="$3" msg="$4" rc=0
  shift 4
  run_install "$h" "$log" "$@" || rc=$?
  assert_eq "install.sh $* exit status" "$want" "$rc"
  assert_grep "install.sh said why it refused" "$log" "$msg"
}

# scratch_git <home> <git args…>: read back what install.sh wrote with `git config --global`, through the
# same scratch HOME, so the assertion cannot accidentally read the author's own config.
scratch_git() {
  local h="$1"
  shift
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT \
      HOME="$h" XDG_CONFIG_HOME="$h/.config" git "$@" 2>/dev/null || true
}

# assert_install_ok <home> <log> [args…]: run it and fail loudly, with the output, if it did not exit 0.
assert_install_ok() {
  local h="$1" log="$2" rc=0
  shift 2
  run_install "$h" "$log" "$@" || rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "install.sh $* exited $rc, expected 0; output follows:"
    sed 's/^/      | /' "$log" >&2
    return 1
  fi
  pass
}

# ---------------------------------------------------------------------------- shared expectations

# The five opinionated destinations, as three parallel arrays because bash 3.2 has no associative arrays.
FIVE_FLAG=(--with-zshrc --with-gitconfig --with-tmux-conf --with-keybindings --with-statusline)
FIVE_DST=(.zshrc .gitconfig .tmux.conf .claude/keybindings.json .claude/statusline-command.sh)
FIVE_SRC=(home/.zshrc home/.gitconfig home/.tmux.conf home/.claude/keybindings.json home/.claude/statusline-command.sh)
UI_FLAG=--with-claude-ui             # the sixth flag: keys inside a copied file, so it has no FIVE_DST entry
THEME_DST=.oh-my-zsh/custom/themes/workstation.zsh-theme
THEME_SRC=home/.oh-my-zsh/custom/themes/workstation.zsh-theme
TMUX_LINE='set -ag update-environment'                                   # enough to count occurrences
TMUX_FULL_LINE='set -ag update-environment " CMUX_SOCKET_PATH CMUX_WORKSPACE_ID"'   # the whole line, for -x

# assert_machinery <home>: everything a default install owes every user, opinionated or not. Derived from
# the repo rather than hard-coded, so a new bin/ script or skill that install.sh forgot to link fails here.
assert_machinery() {
  local h="$1" b n d
  assert_link "$h" .zshenv home/.zshenv
  assert_link "$h" .gitignore_global home/.gitignore_global
  assert_link "$h" .claude/AGENTS.md home/.claude/AGENTS.md
  assert_link "$h" .claude/CLAUDE.md home/.claude/CLAUDE.md
  assert_link "$h" .codex/AGENTS.md home/.claude/AGENTS.md
  for d in "$REPO"/bin/*; do
    b="$(basename "$d")"
    assert_link "$h" ".local/bin/$b" "bin/$b"
  done
  for d in "$REPO"/home/.agents/skills/*/; do
    n="$(basename "$d")"
    assert_link "$h" ".agents/skills/$n" "home/.agents/skills/$n"
    assert_link "$h" ".claude/skills/$n" "home/.agents/skills/$n"
  done
  # The three machine-local copies: real files, never links, so the apps can write their state into them,
  # and mode 600, because they hold local state and copy_config chmods them.
  assert_regular "$h" .claude/settings.json
  assert_regular "$h" .codex/config.toml
  assert_regular "$h" .codex/hooks.json
  assert_mode "$h" .claude/settings.json 600
  assert_mode "$h" .codex/config.toml 600
  assert_mode "$h" .codex/hooks.json 600
  # …and they have to CONTAIN the .base file. Asserting only that the two Codex copies exist passes on a
  # zero-byte file, and on a Mac both take copy_config's plain `cp` branch, so neither was ever checked.
  # shellcheck disable=SC2088   # the ~ is the label a failure prints, not a path to expand
  assert_same_bytes "~/.codex/hooks.json is its .base file" \
    "$h/.codex/hooks.json" "$REPO/home/.codex/hooks.base.json"
  if [[ $OS == Darwin ]]; then
    # shellcheck disable=SC2088
    assert_same_bytes "~/.codex/config.toml is its .base file" \
      "$h/.codex/config.toml" "$REPO/home/.codex/config.base.toml"   # off a Mac it is filtered, not copied
  fi
  if [[ $OS == Darwin ]]; then
    assert_link "$h" .config/cmux/cmux.json home/.config/cmux/cmux.json
  fi
}

# assert_status_line <home> <yes|no>: settings.json may only name the statusline script when that script
# was actually installed — a statusLine command pointing at a file that is not there breaks Claude's UI.
assert_status_line() {
  local h="$1" want="$2" got=no
  if jq -e 'has("statusLine")' "$h/.claude/settings.json" >/dev/null 2>&1; then
    got=yes
  fi
  assert_eq "the ~/.claude/settings.json statusLine key present" "$want" "$got"
}

# assert_settings_key <home> <key> <yes|no>: one top-level key of the ~/.claude/settings.json copy, read the
# same way assert_status_line reads its own — jq rather than grep, so a key mentioned inside a string or a
# nested object is never mistaken for the top-level one this is about.
assert_settings_key() {
  local h="$1" key="$2" want="$3" got=no
  if jq -e --arg k "$key" 'has($k)' "$h/.claude/settings.json" >/dev/null 2>&1; then
    got=yes
  fi
  assert_eq "the ~/.claude/settings.json $key key present" "$want" "$got"
}

# assert_claude_ui <home> <yes|no>: the whole settings.json contract in one call. .tui and .theme follow
# --with-claude-ui exactly. .voice has TWO independent reasons to be absent — the flag, and a machine with no
# microphone — so off a Mac it is gone even when the flag was given, which is what checks that the two strips
# compose rather than replace one another. .model and .effortLevel are gone from the repo altogether, so no
# path may produce them. And .hooks and .permissions are machinery: they are what makes installing this file
# unconditional in the first place, so they must survive every combination, or the gating has overreached.
assert_claude_ui() {
  local h="$1" want="$2" voice="$2"
  if [[ $OS != Darwin ]]; then
    voice=no
  fi
  assert_settings_key "$h" tui "$want"
  assert_settings_key "$h" theme "$want"
  assert_settings_key "$h" voice "$voice"
  assert_settings_key "$h" model no
  assert_settings_key "$h" effortLevel no
  assert_settings_key "$h" hooks yes
  assert_settings_key "$h" permissions yes
  # .env holds one key, CLAUDE_CODE_DISABLE_MOUSE_CLICKS, and it is UI taste in exactly the way .tui is: it
  # turns mouse clicks off in the Claude Code TUI. It used to be installed unconditionally, so a default
  # install disabled a stranger's mouse with nothing in the output naming the key. Both halves are asserted:
  # the key follows the flag, and the object it lived in does not survive it as an empty `{}`.
  assert_settings_key "$h" env "$want"
  assert_mouse_key "$h" "$want"
}

# assert_mouse_key <home> <yes|no>: the one key inside .env, read as a path rather than by name so a key of
# the same name at the top level could not stand in for it.
assert_mouse_key() {
  local h="$1" want="$2" got=no
  if jq -e '.env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS' "$h/.claude/settings.json" >/dev/null 2>&1; then
    got=yes
  fi
  assert_eq "the ~/.claude/settings.json env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS key present" "$want" "$got"
}

# assert_only_linked <home> <index>: exactly one of the five is a link into the repo, the other four are
# not links at all — assert_not_link rather than assert_absent, because the gitconfig and tmux.conf
# fallbacks legitimately leave a regular file at two of those paths.
assert_only_linked() {
  local h="$1" want="$2" i
  for i in 0 1 2 3 4; do
    if [[ $i -eq $want ]]; then
      assert_link "$h" "${FIVE_DST[$i]}" "${FIVE_SRC[$i]}"
    else
      assert_not_link "$h" "${FIVE_DST[$i]}"
    fi
  done
}

# ---------------------------------------------------------------------------- manifest (idempotence)

# manifest <home>: every path under a scratch HOME with its type, its symlink target, and, for regular
# files, a checksum of the contents and the permission mode — copy_config chmods its output to 600, and
# without the mode a regression there would pass unnoticed. Symlinks are recorded by target and never
# followed, so the manifest stops at the repo boundary instead of checksumming the repo itself.
#
# Nothing is excluded, and that is deliberate. The manifest records type, target and content only — no
# mtimes, inodes, uids or pids — so the things that genuinely differ run to run never enter it. The one
# volatile-looking name, ~/.workstation-backup/<timestamp>-<pid>, is created by the FIRST run, so keeping
# it in makes the comparison strictly stronger: a second run that stashed anything would have to invent a
# second directory beside it, and the diff would say so. If a future change adds something truly volatile
# (a cache, a log, a lockfile) it belongs on an exclusion list here, with the reason written down.
# file_mode <path>: -c is GNU, -f is BSD, the same pair install.sh itself reaches for.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo "?"
}

manifest() {
  local h="$1" e rel
  find "$h" -mindepth 1 | LC_ALL=C sort | while IFS= read -r e; do
    rel="${e#"$h"/}"
    if [[ -L "$e" ]]; then
      printf 'l %s -> %s\n' "$rel" "$(readlink "$e")"   # a symlink's own mode means nothing
    elif [[ -d "$e" ]]; then
      printf 'd %s %s\n' "$rel" "$(file_mode "$e")"
    elif [[ -f "$e" ]]; then
      printf 'f %s %s %s\n' "$rel" "$(file_mode "$e")" "$(cksum <"$e")"
    else
      printf '? %s\n' "$rel"
    fi
  done
}

# assert_unchanged <what> <before-file> <after-file>
assert_unchanged() {
  if ! diff -u "$2" "$3" >"$TEST_ROOT/manifest.diff" 2>&1; then
    fail "$1: the second run changed the HOME; diff of the manifests:"
    sed 's/^/      | /' "$TEST_ROOT/manifest.diff" >&2
    return 0
  fi
  pass
}

# ---------------------------------------------------------------------------- scenarios

# 1. The default path: no flags, an otherwise empty HOME. This is what every stranger gets and what the
#    author never runs.
scenario_default_empty() {
  begin_scenario "1. default install into an empty HOME"
  local h log
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_machinery "$h"
    # None of the five taste files, and not the theme the linked .zshrc is the only thing naming.
    assert_absent "$h" .zshrc
    assert_absent "$h" .claude/keybindings.json
    assert_absent "$h" .claude/statusline-command.sh
    assert_absent "$h" "$THEME_DST"
    assert_regular "$h" .gitconfig           # configure_git makes a real file here; never a link
    assert_status_line "$h" no
    assert_claude_ui "$h" no                 # …and no UI taste in the settings.json copy either
    # The two settings that are machinery rather than taste have to arrive anyway, via configure_git.
    assert_eq "core.excludesFile in the scratch ~/.gitconfig" \
      "$h/.gitignore_global" "$(scratch_git "$h" config --global --get core.excludesFile)"
    assert_eq "include.path in the scratch ~/.gitconfig" \
      "$h/.gitconfig.local" "$(scratch_git "$h" config --global --get-all --type=path include.path)"
    # ... and so does tmux's update-environment line, appended rather than linked.
    assert_regular "$h" .tmux.conf
    assert_eq "update-environment lines in ~/.tmux.conf" 1 "$(count_matches "$h/.tmux.conf" "$TMUX_LINE")"
    # report_skipped has to name all six, or a user who wanted them never learns the flag exists.
    local f
    for f in "${FIVE_FLAG[@]}"; do
      assert_grep "install.sh output names $f as skipped" "$log" "$f"
    done
    assert_grep "install.sh output names $UI_FLAG as skipped" "$log" "$UI_FLAG"
  fi
  end_scenario
}

# 2. The regression that would actually hurt someone: a default install on top of a stranger's own
#    dotfiles must leave every one of them a regular file with its own content.
scenario_default_over_existing() {
  begin_scenario "2. default install over a stranger's existing dotfiles"
  local h log zsum_before gsum_before tmux_before
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_opinionated_originals "$h"
  zsum_before="$(cksum <"$h/.zshrc")"
  gsum_before="$(cksum <"$h/.gitconfig")"
  tmux_before="$(line_count "$h/.tmux.conf")"
  if assert_install_ok "$h" "$log"; then
    assert_machinery "$h"
    # ~/.zshrc is not touched at all: same bytes, still a real file, and no theme link beside it.
    assert_regular "$h" .zshrc
    assert_eq "the ~/.zshrc checksum" "$zsum_before" "$(cksum <"$h/.zshrc")"
    assert_absent "$h" "$THEME_DST"
    # ~/.gitconfig is edited in place by `git config`, so its checksum legitimately changes — but it stays
    # a real file and every section the user wrote survives.
    assert_regular "$h" .gitconfig
    assert_grep "the ~/.gitconfig keeps its [user] section" "$h/.gitconfig" "email = stranger@example.invalid"
    assert_grep "the ~/.gitconfig keeps its [alias] section" "$h/.gitconfig" "lg = log --oneline"
    assert_grep "the ~/.gitconfig keeps the [alias] header" "$h/.gitconfig" "[alias]"
    if [[ "$gsum_before" == "$(cksum <"$h/.gitconfig")" ]]; then
      fail "at ~/.gitconfig: expected git config to add core.excludesFile/include.path, file is byte-identical"
    else
      pass
    fi
    assert_eq "core.excludesFile added to the stranger's ~/.gitconfig" \
      "$h/.gitignore_global" "$(scratch_git "$h" config --global --get core.excludesFile)"
    # ~/.tmux.conf gains exactly one line and keeps the one it had — including the last one, which the
    # fixture deliberately leaves without a newline. `grep -cF` counts LINES, so the count below reads 1
    # whether the line was appended or glued onto the user's last one; the anchored count is what tells
    # the two apart, and it is the only assertion here that append_line's guard can fail.
    assert_regular "$h" .tmux.conf
    assert_grep "the ~/.tmux.conf keeps its own comment" "$h/.tmux.conf" "# STRANGER TMUX"
    assert_eq "the user's unterminated last line survived intact" 1 \
      "$(grep -cFx -- 'set -g prefix C-a' "$h/.tmux.conf" 2>/dev/null || true)"
    assert_eq "update-environment lines in ~/.tmux.conf" 1 "$(count_matches "$h/.tmux.conf" "$TMUX_LINE")"
    assert_eq "the appended update-environment line is a line of its own" 1 \
      "$(grep -cFx -- "$TMUX_FULL_LINE" "$h/.tmux.conf" 2>/dev/null || true)"
    assert_eq "the ~/.tmux.conf line count" "$((tmux_before + 1))" "$(line_count "$h/.tmux.conf")"
    # The two files install.sh never links by default and never rewrites either.
    assert_not_link "$h" .claude/keybindings.json
    assert_regular "$h" .claude/keybindings.json
    assert_grep "the ~/.claude/keybindings.json is still the stranger's" "$h/.claude/keybindings.json" '"stranger"'
    assert_regular "$h" .claude/statusline-command.sh
    assert_grep "the ~/.claude/statusline-command.sh is still the stranger's" \
      "$h/.claude/statusline-command.sh" "STRANGER STATUSLINE"
    assert_status_line "$h" no
    assert_claude_ui "$h" no
  fi
  end_scenario
}

# 3. --opinionated-config: all five linked, the theme too, and the five originals kept.
scenario_opinionated() {
  begin_scenario "3. --opinionated-config links all five and stashes the originals"
  local h log i bk d n
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  seed_opinionated_originals "$h"
  if assert_install_ok "$h" "$log" --opinionated-config; then
    assert_machinery "$h"
    for i in 0 1 2 3 4; do
      assert_link "$h" "${FIVE_DST[$i]}" "${FIVE_SRC[$i]}"
    done
    assert_link "$h" "$THEME_DST" "$THEME_SRC"
    assert_status_line "$h" yes
    assert_claude_ui "$h" yes                # --opinionated-config is all six, the UI keys included
    # Exactly one backup dir, holding all five originals with their own content.
    n=0
    bk=""
    for d in "$h"/.workstation-backup/*/; do
      [[ -d "$d" ]] || continue
      bk="$d"
      n=$((n + 1))
    done
    assert_eq "backup directories under ~/.workstation-backup" 1 "$n"
    # No loop and no `continue` guard around the five below. They used to sit inside the loop above, so a
    # run that stashed nothing at all skipped five assertions instead of failing them and the suite stayed
    # green on a smaller total. With $bk empty each of these now fails loudly, which is the point.
    assert_grep "stashed .zshrc" "$bk/.zshrc" "# STRANGER ZSHRC"
    assert_grep "stashed .gitconfig" "$bk/.gitconfig" "stranger@example.invalid"
    assert_grep "stashed .tmux.conf" "$bk/.tmux.conf" "# STRANGER TMUX"
    assert_grep "stashed .claude/keybindings.json" "$bk/.claude/keybindings.json" '"stranger"'
    assert_grep "stashed .claude/statusline-command.sh" "$bk/.claude/statusline-command.sh" \
      "STRANGER STATUSLINE"
    # Nothing was left to skip, so report_skipped must stay quiet.
    assert_eq "'left alone' lines in the output" 0 "$(count_matches "$log" "left alone")"
  fi
  end_scenario
}

# 4. Stickiness: `wt update` reruns install.sh bare, so a destination already linked into the repo counts
#    as opted in and must survive a run that cannot see the original flag. The inverse matters just as
#    much: a regular file there must NOT be taken as consent.
scenario_sticky_optin() {
  begin_scenario "4a. an existing link into the repo keeps its opt-in with no flags"
  local h log
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  ln -s "$REPO/home/.zshrc" "$h/.zshrc"
  if assert_install_ok "$h" "$log"; then
    assert_link "$h" .zshrc home/.zshrc
    # The theme comes with the .zshrc and nothing else names it, so its arrival with no flag given is the
    # proof that opted_in said yes on the strength of the existing link alone.
    assert_link "$h" "$THEME_DST" "$THEME_SRC"
    assert_eq "--with-zshrc listed as skipped" 0 "$(count_matches "$log" "--with-zshrc")"
  fi
  end_scenario

  begin_scenario "4b. an existing regular file is not an opt-in"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  printf '%s\n' '# STRANGER ZSHRC' >"$h/.zshrc"
  if assert_install_ok "$h" "$log"; then
    assert_regular "$h" .zshrc
    assert_grep "the ~/.zshrc is untouched" "$h/.zshrc" "# STRANGER ZSHRC"
    assert_absent "$h" "$THEME_DST"
    assert_grep "--with-zshrc listed as skipped" "$log" "--with-zshrc"
  fi
  end_scenario
}

# 5. Idempotence. install.sh promises a rerun is safe, and `wt update` reruns it constantly, so a second
#    run over an already-installed HOME must change nothing at all.
scenario_idempotent() {
  begin_scenario "5a. a second default run changes nothing"
  local h log before after
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  before="$h.manifest.1"
  after="$h.manifest.2"
  if assert_install_ok "$h" "$log"; then
    manifest "$h" >"$before"
    if assert_install_ok "$h" "$log.2"; then
      manifest "$h" >"$after"
      assert_unchanged "default install, second run" "$before" "$after"
    fi
  fi
  end_scenario

  begin_scenario "5b. a second --opinionated-config run changes nothing"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  before="$h.manifest.1"
  after="$h.manifest.2"
  seed_oh_my_zsh "$h"
  seed_opinionated_originals "$h"
  if assert_install_ok "$h" "$log" --opinionated-config; then
    manifest "$h" >"$before"
    if assert_install_ok "$h" "$log.2" --opinionated-config; then
      manifest "$h" >"$after"
      # The backup dir the first run created is in both manifests, so a second run that stashed anything
      # would show up here as a new directory beside it.
      assert_unchanged "--opinionated-config, second run" "$before" "$after"
    fi
  fi
  end_scenario
}

# 6. Each flag on its own installs its own file and nothing else's.
scenario_individual_flags() {
  local i h log
  for i in 0 1 2 3 4; do
    begin_scenario "6. ${FIVE_FLAG[$i]} alone installs only ${FIVE_DST[$i]}"
    h="$(new_home)"
    guard_scratch_home "$h"
    log="$h.log"
    seed_oh_my_zsh "$h"      # harmless for the other four, required by --with-zshrc
    if assert_install_ok "$h" "$log" "${FIVE_FLAG[$i]}"; then
      assert_only_linked "$h" "$i"
      # The theme rides with ~/.zshrc and with nothing else.
      if [[ $i -eq 0 ]]; then
        assert_link "$h" "$THEME_DST" "$THEME_SRC"
      else
        assert_absent "$h" "$THEME_DST"
      fi
      # statusLine in settings.json has to track --with-statusline exactly.
      if [[ $i -eq 4 ]]; then
        assert_status_line "$h" yes
      else
        assert_status_line "$h" no
      fi
      assert_claude_ui "$h" no      # none of the five carries the UI keys: only --with-claude-ui does
    fi
    end_scenario
  done
}

# 7. A usage error is exit 2 with the usage on stderr, and nothing installed.
scenario_unknown_flag() {
  begin_scenario "7. an unknown flag exits 2 with usage on stderr"
  local h out err rc=0
  h="$(new_home)"
  guard_scratch_home "$h"
  out="$h.out"
  err="$h.err"
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT -u ZSH_CUSTOM \
      HOME="$h" XDG_CONFIG_HOME="$h/.config" WT_HOST="$VM_HOST" \
      "$INSTALL_BASH" "$REPO/install.sh" --no-such-flag >"$out" 2>"$err" </dev/null || rc=$?
  assert_eq "exit status for an unknown flag" 2 "$rc"
  assert_grep "usage printed on stderr" "$err" "usage: install.sh"
  assert_eq "bytes written to stdout" 0 "$(wc -c <"$out" | tr -d ' ')"
  # parse_args runs before anything moves, so the HOME must be untouched.
  assert_absent "$h" .zshenv
  assert_absent "$h" .local/bin
  end_scenario
}

# 8. The sixth flag. It is unlike the other five in one way — it installs no file, it gates keys inside a
#    COPIED ~/.claude/settings.json — and like them in the way that matters: it is sticky, and its record is
#    the keys themselves. The second half is the one a refactor is most likely to get wrong, and the one
#    that decides whether `wt update --refresh-config`, which cannot forward the flag, keeps a machine's UI
#    settings or silently deletes them.
scenario_claude_ui() {
  begin_scenario "8a. --with-claude-ui keeps the UI keys and links no file"
  local h log i f
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log" "$UI_FLAG"; then
    assert_machinery "$h"
    for i in 0 1 2 3 4; do            # it gates keys, not files: none of the five may ride in with it
      assert_not_link "$h" "${FIVE_DST[$i]}"
    done
    assert_absent "$h" "$THEME_DST"
    assert_status_line "$h" no        # the statusline script is still its own flag's business
    assert_claude_ui "$h" yes
    # report_skipped still names the five it did not install, and no longer names this one.
    for f in "${FIVE_FLAG[@]}"; do
      assert_grep "install.sh output names $f as skipped" "$log" "$f"
    done
    assert_eq "$UI_FLAG listed as skipped" 0 "$(count_matches "$log" "$UI_FLAG")"
  fi
  end_scenario

  begin_scenario "8b. --with-claude-ui is sticky: the keys it wrote are the record of it"
  local h2
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_claude_ui "$h" no
    # A rerun WITH the flag keeps the existing settings.json, so nothing changes and nothing can: the flag
    # only ever reaches the file being written. install.sh has to say so rather than report plain success.
    if assert_install_ok "$h" "$log.2" "$UI_FLAG"; then
      assert_claude_ui "$h" no
      assert_grep "the kept-copy warning names $UI_FLAG" "$log.2" "$UI_FLAG changed nothing"
    fi
    # --refresh-config rewrites the copy, and only then do the keys arrive.
    if assert_install_ok "$h" "$log.3" "$UI_FLAG" --refresh-config; then
      assert_claude_ui "$h" yes
    fi
    # …and a LATER refresh with no flag keeps them. This is the stickiness rule of scenario 4a in the one
    # place it cannot be a symlink: the .tui key of the file about to be rewritten is the record of the
    # earlier flag. Without it, the one documented way to pick up a change to a .base file — which is what
    # `wt update --refresh-config` runs, and it cannot forward --with-claude-ui — would delete the UI keys
    # of every machine that has them, while report_skipped called it "left alone".
    if assert_install_ok "$h" "$log.4" --refresh-config; then
      assert_claude_ui "$h" yes
      assert_eq "$UI_FLAG listed as skipped once it is installed" 0 "$(count_matches "$log.4" "$UI_FLAG")"
    fi
  fi
  # The inverse, which is what makes it a record rather than a default: a copy written WITHOUT the keys
  # stays without them through a refresh, exactly as a regular file at ~/.zshrc is not an opt-in.
  h2="$(new_home)"
  guard_scratch_home "$h2"
  if assert_install_ok "$h2" "$h2.log"; then
    if assert_install_ok "$h2" "$h2.log.2" --refresh-config; then
      assert_claude_ui "$h2" no
      assert_grep "$UI_FLAG still listed as skipped" "$h2.log.2" "$UI_FLAG"
    fi
  fi
  end_scenario
}

# 9. The refusals. require_plain_file is what stands between `git config --global` / append_line's >> and a
#    dangling symlink pointing anywhere on disk, and every one of its callers was untested: neutering it left
#    the suite green. Each escape target below is inside TEST_ROOT on purpose — guard_scratch_home constrains
#    $HOME, not where a symlink under it aims — and each case also asserts that the refusal came BEFORE
#    anything moved, which is the whole reason the check_… twins exist.
scenario_refusals() {
  local h log

  begin_scenario "9a. a dangling ~/.gitconfig is refused, and nothing is written through it"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  ln -s "$TEST_ROOT/escaped-gitconfig" "$h/.gitconfig"
  assert_install_fails "$h" "$log" 1 "broken symlink at ~/.gitconfig"
  assert_absent "$TEST_ROOT" escaped-gitconfig      # git config --global would have created it out here
  assert_absent "$h" .zshenv                        # …and it refused before the first link was made
  assert_absent "$h" .local/bin
  end_scenario

  begin_scenario "9b. a dangling ~/.tmux.conf is refused, and the append does not escape"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  ln -s "$TEST_ROOT/escaped-tmux-conf" "$h/.tmux.conf"
  assert_install_fails "$h" "$log" 1 "broken symlink at ~/.tmux.conf"
  assert_absent "$TEST_ROOT" escaped-tmux-conf      # append_line's >> would have created it out here
  assert_absent "$h" .zshenv
  end_scenario

  begin_scenario "9c. a directory at ~/.tmux.conf is refused"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.tmux.conf"
  assert_install_fails "$h" "$log" 1 "not a regular file: ~/.tmux.conf"
  assert_absent "$h" .zshenv
  end_scenario

  begin_scenario "9d. a directory at git's OTHER global file is refused, in this script's voice"
  # `git config --global` writes ~/.config/git/config whenever that exists and ~/.gitconfig does not, so
  # that is the file check_gitconfig has to guard. Guarding ~/.gitconfig alone let git take the install
  # down mid-way instead — "fatal: unknown error occurred while reading the configuration files", exit 128,
  # after six steps had already moved things.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/git/config"
  assert_install_fails "$h" "$log" 1 "not a regular file: ~/.config/git/config"
  assert_absent "$h" .zshenv
  end_scenario
}

# 10. Who owns a symlink. our_link's own comment calls the live-link-landing-elsewhere rule "the one link
#     this script must never touch", and opted_in reads the answer as CONSENT — so a wrong yes hands a
#     stranger the author's shell prompt with nothing in the output saying so. None of it was tested.
scenario_link_ownership() {
  local h log

  begin_scenario "10a. a live link into a second checkout is never touched"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  ln -s "$OTHER_CHECKOUT/home/.zshrc" "$h/.zshrc"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the ~/.zshrc link still points at the other checkout" \
      "$OTHER_CHECKOUT/home/.zshrc" "$(readlink "$h/.zshrc")"
    assert_grep "the other checkout's own file is untouched" \
      "$OTHER_CHECKOUT/home/.zshrc" "# THE OTHER CHECKOUT ZSHRC"
    assert_absent "$h" "$THEME_DST"                 # the theme rides with an opt-in that never happened
    assert_grep "--with-zshrc still listed as skipped" "$log" "--with-zshrc"
  fi
  end_scenario

  begin_scenario "10b. a DANGLING foreign link is not consent either"
  # home/.zshrc is not a distinctive tail: it is what chezmoi, yadm, dotbot, homeshick and a `home` stow
  # package all produce. A machine whose dotfile links are momentarily dangling — bootstrap ran before the
  # dotfiles repo was cloned, the repo is on an unmounted volume — used to read as "already opted in" to a
  # run given no flags, and report_skipped then omitted the flag, so the one line that would have said so
  # was silent.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  ln -s "$h/not-cloned-yet/home/.zshrc" "$h/.zshrc"
  if assert_install_ok "$h" "$log"; then
    assert_not_link_into_repo "$h" .zshrc
    assert_absent "$h" "$THEME_DST"
    assert_grep "--with-zshrc listed as skipped" "$log" "--with-zshrc"
    assert_eq "install.sh did not report linking ~/.zshrc" 0 "$(count_matches "$log" "linked ~/.zshrc")"
  fi
  end_scenario

  begin_scenario "10c. a MOVED clone still heals itself"
  # The case the dangling-tail rule exists for, and the one that says the stricter opted_in did not simply
  # turn it off: ~/.zshenv is linked by every run and no dotfile manager owns one, so its own dangling
  # target names the clone this machine was installed from, and a sibling under that same old root is this
  # user's earlier answer.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  ln -s "$h/old-clone/home/.zshenv" "$h/.zshenv"
  ln -s "$h/old-clone/home/.zshrc" "$h/.zshrc"
  if assert_install_ok "$h" "$log"; then
    assert_link "$h" .zshenv home/.zshenv
    assert_link "$h" .zshrc home/.zshrc
    assert_link "$h" "$THEME_DST" "$THEME_SRC"
    assert_eq "--with-zshrc not listed as skipped" 0 "$(count_matches "$log" "--with-zshrc")"
  fi
  end_scenario

  begin_scenario "10d. …but only under the root ~/.zshenv itself names"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  ln -s "$h/old-clone/home/.zshenv" "$h/.zshenv"
  ln -s "$h/some-other-manager/home/.zshrc" "$h/.zshrc"
  if assert_install_ok "$h" "$log"; then
    assert_not_link_into_repo "$h" .zshrc
    assert_absent "$h" "$THEME_DST"
    assert_grep "--with-zshrc listed as skipped" "$log" "--with-zshrc"
  fi
  end_scenario
}

# 11. configure_git's two don't-clobber branches. Both silently destroy a stranger's configuration when they
#     regress, and both stayed green when deleted.
scenario_git_keeps_yours() {
  begin_scenario "11. configure_git keeps an excludesFile and an include.path you already had"
  local h log want got
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.mine"
  printf '%s\n' '*.swp' >"$h/.mine/ignore"
  # Written with a ~ on purpose: configure_git reads both values with --type=path precisely so that a
  # value spelled this way compares equal to the expanded one, and does not warn about itself forever.
  printf '[core]\n\texcludesFile = ~/.mine/ignore\n[include]\n\tpath = ~/.my-extra-config\n' >"$h/.gitconfig"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the user's core.excludesFile survives" "$h/.mine/ignore" \
      "$(scratch_git "$h" config --global --get --type=path core.excludesFile)"
    assert_grep "install.sh says it kept it" "$log" "kept core.excludesFile"
    assert_grep "…and says what that costs" "$log" "add the lines of ~/.gitignore_global"
    assert_grep "the user's own spelling is still in the file" "$h/.gitconfig" "excludesFile = ~/.mine/ignore"
    # include.path is multi-valued: a plain `git config include.path …` would overwrite the user's one
    # value, and refuse outright once there are two. Ours is --added after theirs.
    want="$(printf '%s\n%s' "$h/.my-extra-config" "$h/.gitconfig.local")"
    got="$(scratch_git "$h" config --global --get-all --type=path include.path)"
    assert_eq "include.path keeps the user's value and gains ours, in that order" "$want" "$got"
  fi
  end_scenario
}

# 12. "A dotfile manager owns it, skip and warn." Three branches, one per file, none of them tested: a
#     regression writes through somebody's dotfiles repo and reports success. Plus the one place that
#     deliberately does NOT skip, so the asymmetry is asserted rather than assumed.
scenario_manager_owned() {
  local h log sum

  begin_scenario "12a. a ~/.tmux.conf owned by a dotfile manager is left alone and named"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_manager "$h"
  ln -s "$h/dotfiles/tmux.conf" "$h/.tmux.conf"
  sum="$(cksum <"$h/dotfiles/tmux.conf")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the ~/.tmux.conf link is still the manager's" "$h/dotfiles/tmux.conf" "$(readlink "$h/.tmux.conf")"
    assert_eq "the file it points at is byte-identical" "$sum" "$(cksum <"$h/dotfiles/tmux.conf")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/.tmux.conf:"
    assert_grep "…and printed the line to add by hand" "$log" "$TMUX_FULL_LINE"
  fi
  end_scenario

  begin_scenario "12b. a ~/.gitconfig owned by a dotfile manager is left alone and named"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_manager "$h"
  ln -s "$h/dotfiles/gitconfig" "$h/.gitconfig"
  sum="$(cksum <"$h/dotfiles/gitconfig")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the ~/.gitconfig link is still the manager's" "$h/dotfiles/gitconfig" "$(readlink "$h/.gitconfig")"
    assert_eq "the file it points at is byte-identical" "$sum" "$(cksum <"$h/dotfiles/gitconfig")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/.gitconfig:"
    assert_eq "core.excludesFile was not written through the link" "" \
      "$(scratch_git "$h" config --global --get core.excludesFile)"
  fi
  end_scenario

  begin_scenario "12c. …and the same when git's global file is ~/.config/git/config"
  # No ~/.gitconfig at all, so `git config --global` writes the XDG file — through the manager's symlink,
  # which is the one thing configure_git promises not to do. It used to do exactly that, and then report
  # two settings added to a ~/.gitconfig that does not exist.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_manager "$h"
  mkdir -p "$h/.config/git"
  ln -s "$h/dotfiles/gitconfig" "$h/.config/git/config"
  sum="$(cksum <"$h/dotfiles/gitconfig")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the manager's file is byte-identical" "$sum" "$(cksum <"$h/dotfiles/gitconfig")"
    assert_grep "install.sh named the skip, and named the right file" "$log" "skipped ~/.config/git/config:"
    assert_absent "$h" .gitconfig
  fi
  end_scenario


  begin_scenario "12d. …but a managed ~/.claude/settings.json IS displaced, and the run says so"
  # copy_config is the one step that does not leave a dotfile manager's link alone, and deliberately: Claude
  # and Codex write their own state into these three files, so they have to be real files at the path the app
  # opens. Only the LINK moves — the file it pointed at is untouched — and the run has to name the
  # displacement rather than fold it into "installed ~/…".
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_manager "$h"
  printf '%s\n' '{ "manager": true }' >"$h/dotfiles/claude-settings.json"
  sum="$(cksum <"$h/dotfiles/claude-settings.json")"
  mkdir -p "$h/.claude"
  ln -s "$h/dotfiles/claude-settings.json" "$h/.claude/settings.json"
  if assert_install_ok "$h" "$log"; then
    assert_regular "$h" .claude/settings.json
    assert_eq "the manager's file is byte-identical" "$sum" "$(cksum <"$h/dotfiles/claude-settings.json")"
    assert_grep "the displacement is named" "$log" "replaced the symlink at ~/.claude/settings.json"
    assert_grep "…and the link itself was kept" \
      "$log" "the link itself is in the backup dir, its target untouched"
  fi
  end_scenario
}

# 13. remove_retired_links, and install_bins' ~/bin retirement. Both stayed green when neutered, and the
#     first exists because of a real incident: a renamed oh-my-zsh theme outlived its rename on every
#     machine, and `wt update` reruns this script constantly.
scenario_retired_links() {
  local h log bk

  begin_scenario "13a. links whose source the repo no longer has are retired, whatever named them"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.claude/skills" "$h/.agents/skills" "$h/.local/bin"
  ln -s "$REPO/home/.agents/skills/renamed-away" "$h/.claude/skills/renamed-away"   # made by THIS clone
  # The same links, made before the clone moved — and these three are the ones whose repo-relative source
  # is NOT their home-relative path, so inferring one from the other never matched and they were never
  # retired: ~/.local/bin/<b> comes from bin/<b>, ~/.claude/skills/<n> from home/.agents/skills/<n>.
  ln -s "$h/old-clone/home/.agents/skills/gone" "$h/.agents/skills/gone"
  ln -s "$h/old-clone/home/.agents/skills/gone" "$h/.claude/skills/gone"
  ln -s "$h/old-clone/bin/gone-script" "$h/.local/bin/gone-script"
  ln -s "$h/their-repo/their-skill" "$h/.claude/skills/theirs"                      # somebody else's
  if assert_install_ok "$h" "$log"; then
    assert_absent "$h" .claude/skills/renamed-away
    assert_absent "$h" .agents/skills/gone
    assert_absent "$h" .claude/skills/gone
    assert_absent "$h" .local/bin/gone-script
    assert_grep "the Claude-side skill retirement is named" "$log" "retired ~/.claude/skills/gone"
    assert_grep "the retired script is named" "$log" "retired ~/.local/bin/gone-script"
    # Nothing is ever deleted, here as everywhere else.
    bk="$(backup_dir "$h")"
    assert_eq "the retired skill link was stashed, not deleted" "$h/old-clone/home/.agents/skills/gone" \
      "$(readlink "$bk/.claude/skills/gone" 2>/dev/null || true)"
    # …and a dangling link that is not ours is left strictly alone.
    assert_eq "somebody else's dangling link is untouched" "$h/their-repo/their-skill" \
      "$(readlink "$h/.claude/skills/theirs" 2>/dev/null || true)"
  fi
  end_scenario

  begin_scenario "13b. a copy in ~/bin, which shadows ~/.local/bin on PATH, is retired"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/bin"
  printf '%s\n' '#!/bin/sh' 'echo OLD WT' >"$h/bin/wt"
  chmod +x "$h/bin/wt"
  if assert_install_ok "$h" "$log"; then
    assert_absent "$h" bin/wt
    assert_link "$h" .local/bin/wt bin/wt
    assert_grep "the shadowing copy is named" "$log" "retired ~/bin/wt"
    bk="$(backup_dir "$h")"
    assert_grep "…and kept, not deleted" "$bk/bin/wt" "echo OLD WT"
  fi
  end_scenario
}

# 14. The two prerequisites that stop the run before it starts. Both stayed green when neutered.
scenario_prerequisites() {
  local h log

  begin_scenario "14a. no git identity anywhere: refused before anything moves"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  rm -f "$h/.gitconfig.local"          # new_home's only fixture is the identity require_git_identity reads
  assert_install_fails "$h" "$log" 1 "set user.name/user.email in ~/.gitconfig.local"
  assert_absent "$h" .zshenv
  end_scenario

  begin_scenario "14b. no jq on PATH: refused before anything moves"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  RUN_EXTRA_ENV=(PATH="$(nojq_path)")
  assert_install_fails "$h" "$log" 1 "jq not found"
  assert_absent "$h" .zshenv
  assert_absent "$h" .claude/settings.json
  end_scenario
}

# 15. $ZSH_CUSTOM. oh-my-zsh looks for the theme ~/.zshrc names under $ZSH_CUSTOM/themes and nowhere else,
#     and install_zsh_plugins has always honoured the variable, so a theme linked into the hardcoded
#     ~/.oh-my-zsh/custom is a theme oh-my-zsh never finds: every shell start says so while every line of
#     the install says success. The author hit this for real.
scenario_zsh_custom() {
  local h log zc pl

  begin_scenario "15a. the theme follows ZSH_CUSTOM, because that is where oh-my-zsh looks"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  zc="$h/.config/omz-custom"
  mkdir -p "$zc/themes"
  for pl in zsh-autosuggestions zsh-syntax-highlighting; do
    mkdir -p "$zc/plugins/$pl"         # pre-created here too, or install_zsh_plugins would hit the network
  done
  RUN_EXTRA_ENV=(ZSH_CUSTOM="$zc")
  if assert_install_ok "$h" "$log" --with-zshrc; then
    assert_link "$h" .zshrc home/.zshrc
    assert_link "$h" .config/omz-custom/themes/workstation.zsh-theme "$THEME_SRC"
    assert_absent "$h" "$THEME_DST"    # the hardcoded path, where oh-my-zsh would never have looked
  fi
  end_scenario

  begin_scenario "15b. a ZSH_CUSTOM outside \$HOME is refused rather than half-installed"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_oh_my_zsh "$h"
  RUN_EXTRA_ENV=(ZSH_CUSTOM="$TEST_ROOT/omz-outside")
  assert_install_fails "$h" "$log" 1 "is outside \$HOME" --with-zshrc
  assert_absent "$h" .zshenv
  end_scenario
}

# shellcheck disable=SC2016   # the $HOME in the bashrc line and in the WT_REPOS_DIR line are literal: the
#                              lines install.sh writes carry the variable, they do not carry its value.
# 16. The Linux-only legs, driven from a Mac with FORCE_OS. hook_bashrc is the most intricate function in
#     install.sh and is unreachable on Darwin, as are ask_vm_host, record_repos_dir and the two platform
#     filters in copy_config; a green run on the author's machine exercised none of them. FORCE_OS exists
#     in install.sh for exactly this and nothing else.
scenario_linux_legs() {
  local h log sum
  local line='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

  begin_scenario "16a. FORCE_OS=Linux: the VM-only steps run"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  if assert_install_ok "$h" "$log" "$UI_FLAG"; then
    # hook_bashrc writes the file when there is none, and the line must be the FIRST one: Ubuntu's own
    # ~/.bashrc returns on its fourth line for a non-interactive shell, and `ssh <vm> '<cmd>'` — which is
    # how `wt -H <vm> …` works — is exactly that.
    assert_regular "$h" .bashrc
    assert_eq "the ~/.zshenv line is the first line of ~/.bashrc" 1 \
      "$(head -n 1 "$h/.bashrc" | grep -cF -- "$line" || true)"
    # ask_vm_host and record_repos_dir, the two lines a VM's ~/.zshenv.local gains.
    assert_grep "WT_HOST recorded" "$h/.zshenv.local" "export WT_HOST=$VM_HOST"
    assert_grep "WT_REPOS_DIR recorded" "$h/.zshenv.local" 'export WT_REPOS_DIR="$HOME"'
    # copy_config's two platform filters, both of them Linux-only.
    assert_settings_key "$h" tui yes            # --with-claude-ui was given…
    assert_settings_key "$h" voice no           # …and the voice keys go anyway: a VM has no microphone
    assert_eq "the Keychain line is filtered out of ~/.codex/config.toml" 0 \
      "$(count_matches "$h/.codex/config.toml" "cli_auth_credentials_store")"
    assert_absent "$h" .config/cmux/cmux.json   # cmux runs on the Mac only
  fi
  end_scenario

  begin_scenario "16b. FORCE_OS=Linux: a line an older run appended is moved to the top"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  printf '%s\n' '# the image bashrc' 'case $- in *i*) ;; *) return;; esac' "$line" 'alias ll="ls -l"' \
    >"$h/.bashrc"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  if assert_install_ok "$h" "$log"; then
    assert_eq "our line is now the first" 1 "$(head -n 1 "$h/.bashrc" | grep -cF -- "$line" || true)"
    assert_eq "and appears exactly once" 1 "$(count_matches "$h/.bashrc" "$line")"
    assert_grep "the user's own lines survive" "$h/.bashrc" 'alias ll="ls -l"'
    assert_grep "the early return survives" "$h/.bashrc" 'case $- in'
    assert_grep "install.sh says what it did" "$log" "moved the ~/.zshenv line to the top"
  fi
  end_scenario

  begin_scenario "16c. FORCE_OS=Linux: a 664 ~/.bashrc that is already hooked is not refused"
  # An image that ships a group-writable ~/.bashrc (umask 002, user-private groups) is ordinary on a Linux
  # VM. hook_bashrc returns before it ever reads the mode when our line is already first, so refusing there
  # failed the install — and therefore every `wt update` — forever, over a file nothing would have touched,
  # with wording describing a copy that would not happen.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  printf '%s\n' "$line" '# the image bashrc' >"$h/.bashrc"
  chmod 664 "$h/.bashrc"
  sum="$(cksum <"$h/.bashrc")"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  if assert_install_ok "$h" "$log" ; then
    assert_eq "the ~/.bashrc contents are byte-identical" "$sum" "$(cksum <"$h/.bashrc")"
    assert_mode "$h" .bashrc 664       # not rewritten, so not re-moded either
  fi
  end_scenario

  begin_scenario "16d. FORCE_OS=Linux: a 664 ~/.bashrc it WOULD rewrite is still refused"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  printf '%s\n' '# the image bashrc' >"$h/.bashrc"
  chmod 664 "$h/.bashrc"
  sum="$(cksum <"$h/.bashrc")"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  assert_install_fails "$h" "$log" 1 "refusing to copy mode 664"
  assert_eq "the ~/.bashrc contents are byte-identical" "$sum" "$(cksum <"$h/.bashrc")"
  assert_absent "$h" .zshenv
  end_scenario

  begin_scenario "16e. FORCE_OS=Linux: a ~/.bashrc a dotfile manager owns is left alone and named"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_manager "$h"
  ln -s "$h/dotfiles/bashrc" "$h/.bashrc"
  sum="$(cksum <"$h/dotfiles/bashrc")"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  if assert_install_ok "$h" "$log"; then
    assert_eq "the ~/.bashrc link is still the manager's" "$h/dotfiles/bashrc" "$(readlink "$h/.bashrc")"
    assert_eq "the file it points at is byte-identical" "$sum" "$(cksum <"$h/dotfiles/bashrc")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/.bashrc:"
  fi
  end_scenario
}


# ---------------------------------------------------------------------------- main

# expected_assertions: what a complete run makes. Asserting the TOTAL is what catches the failure mode a
# pass/fail count cannot see — a scenario that stops asserting rather than starts failing. One mutation
# quietly took the suite from 323 to 318 that way, with every scenario still green.
# It is a formula, not a number, because assert_machinery derives its assertions from the repo: add a bin/
# script or a skill and the count legitimately moves. Everything else is fixed, and a fixed number that
# needs editing whenever an assertion is added is the point.
expected_assertions() {
  local nbin=0 nskill=0 per d
  for d in "$REPO"/bin/*; do
    [[ -e "$d" ]] && nbin=$((nbin + 1))
  done
  for d in "$REPO"/home/.agents/skills/*/; do
    [[ -d "$d" ]] && nskill=$((nskill + 1))
  done
  # one assert_machinery call: 5 links + one per bin script + two per skill + 3 regular + 3 modes + the
  # hooks.json checksum, and on a Mac the cmux.json link and the config.toml checksum as well.
  per=$((5 + nbin + 2 * nskill + 3 + 3 + 1))
  if [[ $OS == Darwin ]]; then
    per=$((per + 2))
  fi
  # …called by scenarios 1, 2, 3 and 8a.
  echo "$((FIXED_ASSERTIONS + 4 * per))"
}

# Everything that is not assert_machinery. Bump it in the same commit as the assertion you added.
FIXED_ASSERTIONS=376

# shellcheck disable=SC2016   # $BASH_VERSION below is for the OTHER bash to expand, not this one
main() {
  local want
  echo "install.sh smoke test: repo $REPO, scratch root $TEST_ROOT"
  echo "  this suite under bash ${BASH_VERSION}; install.sh under $INSTALL_BASH" \
       "($("$INSTALL_BASH" -c 'echo "$BASH_VERSION"'))"
  scenario_default_empty
  scenario_default_over_existing
  scenario_opinionated
  scenario_sticky_optin
  scenario_idempotent
  scenario_individual_flags
  scenario_unknown_flag
  scenario_claude_ui
  scenario_refusals
  scenario_link_ownership
  scenario_git_keeps_yours
  scenario_manager_owned
  scenario_retired_links
  scenario_prerequisites
  scenario_zsh_custom
  scenario_linux_legs
  echo "$((PASS + FAIL)) assertions: $PASS passed, $FAIL failed"
  want="$(expected_assertions)"
  if [[ $((PASS + FAIL)) -ne $want ]]; then
    echo "FAIL: expected $want assertions, ran $((PASS + FAIL)) — a scenario skipped its assertions" \
         "instead of failing them, or one was added without updating FIXED_ASSERTIONS" >&2
    exit 1
  fi
  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}

seed_other_checkout
main "$@"
