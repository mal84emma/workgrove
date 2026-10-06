#!/usr/bin/env bash
#
# test/install-smoke.sh: run install.sh against throwaway HOMEs and assert what it did.
#   bash test/install-smoke.sh          (KEEP=1 keeps the scratch homes for inspection)
#   INSTALL_BASH=/bin/bash bash test/install-smoke.sh    (which bash runs install.sh; see below)
#
# Two interpreters are in use, and each one answers a different question. The bash that invokes this file
# runs it. $INSTALL_BASH runs install.sh, and the header line prints it. Both default to the same `bash` from
# PATH. On the author's Mac, that bash is Homebrew's 5.x. But a fresh Mac has no bash except /bin/bash 3.2.57,
# and docs/new-mac.md tells the user to run `bash install.sh`. So on a fresh Mac, 3.2 is the only interpreter
# that ever runs install.sh. Run this file both ways. Otherwise install.sh stays untested under 3.2.
#
# Why this file exists: install.sh's six opinionated files are opt-in. They are ~/.zshrc, ~/.gitconfig,
# ~/.tmux.conf, ~/.claude/keybindings.json, ~/.claude/statusline-command.sh and, on a Mac,
# ~/.config/cmux/cmux.json. The UI keys of ~/.claude/settings.json are opt-in too, behind --with-claude-ui.
# Every machine that the author owns is fully opted in. So the no-flags path, which every stranger gets, is
# the one path that the author never runs, and the one most likely to rot.
#
# These scenarios exercise that path, the flags, the stickiness rule and idempotence. Above all, they check
# that a default install leaves a stranger's own dotfiles alone. They also cover what install.sh REFUSES to
# do, to protect a machine that it does not own. Two of these cases are a dangling symlink that it would
# otherwise write through, and a file that a dotfile manager owns. The other two are a setting that the
# user already made, and a link into a second checkout of this repo.
#
# The Linux-only steps are unreachable on a Mac, and this suite runs on a Mac. These steps are hook_bashrc
# above all, and also ask_vm_host, record_repos_dir and copy_config's two platform filters. Scenario 16
# drives them through install.sh's FORCE_OS variable, which exists only for that purpose. The only other
# thing that a green run does NOT exercise is the network: install_zsh_plugins' clone, which the fixtures
# pre-empt.
#
# The absolute rule: nothing here may touch anything under the real $HOME. Every scenario runs install.sh
# with HOME set to a fresh mktemp -d. At the start of each scenario, guard_scratch_home refuses if that
# HOME resolves anywhere under the real home. run_install pins XDG_CONFIG_HOME to the scratch HOME and
# unsets GIT_CONFIG_GLOBAL and ZSH_CUSTOM, because these variables could otherwise let a write escape it.
# No scenario needs the network or sudo. The plugin clone is the only network step in install.sh, and the
# fixtures pre-create the plugin directories, so the clone never runs.
#
# An assertion is silent when it holds and loud when it fails. The script prints one line per scenario and
# a pass/fail count. It exits non-zero if any assertion failed.
#
# The suite also asserts the count itself, against expected_assertions below. A mutation once dropped the
# count from 323 to 318 without a single failure, because a scenario's loop skipped its assertions instead
# of failing them. A suite that can quietly stop checking things is not a suite. So every loop over a
# directory that install.sh was supposed to create asserts, and does not `continue`.
set -euo pipefail

# This file creates its fixtures with plain redirection, so their modes come from the ambient umask, unless
# a scenario sets one on purpose. Ubuntu with user-private groups defaults to 002, and macOS to 022. So the
# two platforms built DIFFERENT fixtures from the same line and tested different things. Because install.sh
# refuses to rewrite a group-writable dotfile, a ~/.bashrc scenario that meant to exercise the rewrite
# exercised the refusal instead, and only on Linux. Pin the umask. The scenarios that test the mode chmod it
# themselves.
umask 022

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"   # -P: install.sh records the physical path, so compare like for like
OS="$(uname -s)"
# The assertion vocabulary, the counters, the scenario lines and the summary are in test/lib.sh, because
# test/wt-smoke.sh uses the same vocabulary. LIB_BASE_LABEL sets how a <base> <rel> pair reads in a failed
# assertion. Every base that this file passes is a scratch HOME, so "~/.zshrc" is the correct form.
LIB_BASE_LABEL='~'
# shellcheck source=test/lib.sh
. "$REPO/test/lib.sh"
# The interpreter that runs install.sh itself; see the header. This block resolves it to an absolute path
# once, because scenario 14b gives install.sh a PATH with almost nothing on it. `env bash …` would then fail
# to find bash itself, and the scenario would not test what it meant to test.
INSTALL_BASH="${INSTALL_BASH:-bash}"
INSTALL_BASH_ABS="$(command -v "$INSTALL_BASH" 2>/dev/null || true)"
if [[ -z "$INSTALL_BASH_ABS" ]]; then
  echo "ABORT: INSTALL_BASH='$INSTALL_BASH' is not on PATH" >&2
  exit 1
fi
INSTALL_BASH="$INSTALL_BASH_ABS"
# Resolved before anything else runs, while HOME is still the real one. Everything below compares
# against this value, so it must be captured before any scenario can change HOME.
REAL_HOME="$(cd "$HOME" && pwd -P)"
VM_HOST=smoke-vm                     # ask_vm_host refuses on Linux without this; ignored on a Mac
KEEP_LABEL="scratch homes"           # lib_cleanup's name for what KEEP=1 keeps

# ---------------------------------------------------------------------------- scratch home safety

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/install-smoke.XXXXXX")"
TEST_ROOT_REAL="$(cd "$TEST_ROOT" && pwd -P)"

case "$TEST_ROOT_REAL/" in
  "$REAL_HOME"/*)
    echo "ABORT: mktemp put the test root inside the real home ($TEST_ROOT_REAL); set TMPDIR elsewhere" >&2
    exit 1 ;;
esac

trap lib_cleanup EXIT

# guard_scratch_home <dir>: the check that this whole file is built around. install.sh writes dotfiles, runs
# `git config --global` and moves whatever is in the way into ~/.workgrove-backup. So a HOME that resolved
# under the real one would rewrite the author's machine. Every scenario calls it at its start, and
# run_install calls it again, instead of one call at the top. So a future edit that builds a home some other
# way still trips it. It aborts the run outright. This is not a countable assertion failure.
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
# describe, pass, fail, assert_eq, assert_grep, assert_link, assert_absent, assert_regular and
# assert_not_link are in test/lib.sh, sourced above. Below are the functions that only this suite needs.

# assert_not_link_into_repo <home> <rel>: whatever is there is not a link into THIS repo. It is weaker than
# assert_absent on purpose. For a destination that install.sh must not take over, only one thing matters:
# install.sh did not take it over. It does not matter whether the end state is "untouched" or "stashed as a
# retired link".
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

# count_matches <file> <fixed string>: grep -c exits 1 on no match, and set -e would stop the script.
count_matches() {
  grep -cF -- "$2" "$1" 2>/dev/null || true
}

# line_count <file>: lines, not newlines. wc -l counts newlines, so it counts one line short for a file
# whose last line has no newline. append_line's guard exists for exactly that file. A suite that counts it
# wrong claims to check the append but does not.
line_count() {
  local n
  n="$(wc -l <"$1")"
  n=$((n))
  if [[ -s "$1" && -n "$(tail -c 1 "$1")" ]]; then
    n=$((n + 1))
  fi
  echo "$n"
}

# assert_mode <home> <rel> <mode>: the permission bits of a file that install.sh created. The idempotence
# manifest cannot do this job. It only compares run 1 of an install with run 2 of the same install. A
# chmod regression is identical in both runs, so it passes.
assert_mode() {
  local p="$1/$2"
  if [[ ! -f "$p" ]]; then
    fail "at ~/$2: expected a regular file with mode $3, found $(describe "$p")"
    return 0
  fi
  assert_eq "the mode of ~/$2" "$3" "$(file_mode "$p")"
}

# assert_same_bytes <what> <file a> <file b>: two paths with identical contents. It checks the copies that
# install.sh makes with a plain `cp`, because an assertion that they only EXIST passes on a zero-byte file.
# On a Mac, the author's own machine, both Codex files take the cp branch.
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

# ---------------------------------------------------------------------------- fixtures

# new_home: a fresh scratch HOME with only what install.sh refuses to run without: a git identity in
# ~/.gitconfig.local, which require_git_identity reads directly. A scenario seeds everything else it needs.
# The guard comes before the first write, not after, because seeding a fixture already writes into the
# directory that this function returns. If the guard came after, an edit to how the home is made would put
# a file in the real home before any caller checked.
new_home() {
  local h
  h="$(mktemp -d "$TEST_ROOT/home.XXXXXX")"
  guard_scratch_home "$h"
  printf '[user]\n\tname = Smoke Test\n\temail = smoke@example.invalid\n' >"$h/.gitconfig.local"
  printf '%s\n' "$h"
}

# seed_oh_my_zsh <home>: require_oh_my_zsh needs the oh-my-zsh.sh FILE, not only the directory.
# install_zsh_plugins clones the two plugins over the network unless their directories already exist.
# Each scenario that opts ~/.zshrc in needs both. The pre-created plugin dirs keep this whole suite
# offline.
seed_oh_my_zsh() {
  local h="$1" p
  guard_scratch_home "$h"
  mkdir -p "$h/.oh-my-zsh/custom/themes"
  printf '# smoke fixture\n' >"$h/.oh-my-zsh/oh-my-zsh.sh"
  for p in zsh-autosuggestions zsh-syntax-highlighting; do
    mkdir -p "$h/.oh-my-zsh/custom/plugins/$p"
  done
}

# seed_opinionated_originals <home>: one distinctive regular file at each of the five opt-in destinations.
# A run that installs them then has something to stash, and the test can check the backup for it.
seed_opinionated_originals() {
  local h="$1"
  guard_scratch_home "$h"
  mkdir -p "$h/.claude"
  printf '%s\n' '# STRANGER ZSHRC' 'alias notmine=true' >"$h/.zshrc"
  printf '%s\n' '[user]' '	name = Stranger' '	email = stranger@example.invalid' \
                '[alias]' '	lg = log --oneline' >"$h/.gitconfig"
  # No final newline, on purpose: a hand-edited ~/.tmux.conf often ends that way, and only this shape
  # exercises append_line's guard. Without the guard, the appended line is glued onto this one:
  # `set -g prefix C-aset -ag update-environment …`. That destroys the user's binding AND cannot be parsed.
  # And `grep -c` still reports exactly one update-environment line, so the obvious assertion cannot see it.
  printf '%s\n%s' '# STRANGER TMUX' 'set -g prefix C-a' >"$h/.tmux.conf"
  printf '%s\n' '{ "stranger": true }' >"$h/.claude/keybindings.json"
  printf '%s\n' '#!/bin/sh' 'echo STRANGER STATUSLINE' >"$h/.claude/statusline-command.sh"
}

# other_checkout: a SECOND clone of this repo that the user keeps on purpose. The live link into it is, in
# install.sh's own words, "the one link this script must never touch". Only the paths matter, so it is a
# skeleton, not a copy. It is inside TEST_ROOT because guard_scratch_home constrains $HOME, not the target
# of a symlink under it. So anything that a scenario tempts install.sh to write into must be in here too.
OTHER_CHECKOUT="$TEST_ROOT/other-checkout"
seed_other_checkout() {
  mkdir -p "$OTHER_CHECKOUT/home"
  printf '%s\n' '# THE OTHER CHECKOUT ZSHRC' >"$OTHER_CHECKOUT/home/.zshrc"
}

# seed_manager <home>: the user's own dotfiles repo, with a file at each of the three paths that install.sh
# appends to or edits. Each scenario gets its own, inside its HOME, where ~/dotfiles usually is. So another
# scenario's fixture cannot mask a write into this repo that this scenario provoked.
seed_manager() {
  local h="$1"
  guard_scratch_home "$h"
  mkdir -p "$h/dotfiles"
  printf '%s\n' '# THE MANAGER TMUX CONF' 'set -g mouse on' >"$h/dotfiles/tmux.conf"
  printf '[core]\n\tpager = delta\n' >"$h/dotfiles/gitconfig"      # a real tab: git has to read this one
  printf '%s\n' '# THE MANAGER BASHRC' >"$h/dotfiles/bashrc"
}

# nojq_path: a PATH with everything that install.sh shells out to EXCEPT jq, built once. Without it,
# require_jq's refusal cannot be tested. If require_jq is neutered, copy_config runs a jq that is not there,
# and the run dies mid-install instead of before it.
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

# backup_dir <home>: this run's ~/.workgrove-backup/<stamp>-<pid>, or "" if nothing needed a backup.
# install.sh creates it only when it uses it, and never more than one per run.
backup_dir() {
  local d
  for d in "$1"/.workgrove-backup/*/; do
    if [[ -d "$d" ]]; then
      printf '%s\n' "${d%/}"
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------- running install.sh

# run_install <home> <logfile> [args…]: the only place that invokes install.sh.
# HOME is the scratch dir. XDG_CONFIG_HOME goes with it, because `git config --global` prefers
# $XDG_CONFIG_HOME/git/config when that file exists, and an inherited XDG_CONFIG_HOME would point back at
# the real home. GIT_CONFIG_GLOBAL/SYSTEM/COUNT are unset for the same reason: any of them would override
# HOME for every `git config` that install.sh runs. ZSH_CUSTOM is unset because install_zsh_plugins honors
# it, and an inherited one would make the plugin check look outside the scratch HOME.
# stdin is /dev/null, so ask_vm_host can never block on a read.
# RUN_EXTRA_ENV adds `env` arguments (an assignment, or a -u) for ONE call, and run_install empties it
# again. So a scenario that sets it and forgets to clear it cannot leak a ZSH_CUSTOM or a FORCE_OS into the
# next one. This suite must run clean under bash 3.2, and in 3.2 an empty array under `set -u` is an error.
# So run_install spells these array expansions ${a[@]+"${a[@]}"} throughout.
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
# install.sh must make every refusal BEFORE anything moves, so each caller also asserts that the HOME is
# untouched. Without that check, a mutation that removes require_plain_file would pass.
assert_install_fails() {
  local h="$1" log="$2" want="$3" msg="$4" rc=0
  shift 4
  run_install "$h" "$log" "$@" || rc=$?
  assert_eq "install.sh $* exit status" "$want" "$rc"
  assert_grep "install.sh said why it refused" "$log" "$msg"
}

# scratch_git <home> <git args…>: read back what install.sh wrote with `git config --global`. It reads
# through the same scratch HOME, so the assertion cannot read the author's own config by accident.
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
UI_FLAG=--with-claude-ui             # the seventh flag: keys inside a copied file, so it has no FIVE_DST entry
# The sixth FILE flag. It cannot join the three arrays above, because they are platform-neutral. Every loop
# over them runs `for i in 0 1 2 3 4` on both platforms, but ~/.config/cmux/cmux.json exists only on a Mac.
# Scenario 17 covers it alone, instead of four conditional loops.
CMUX_FLAG=--with-cmux-config
CMUX_DST=.config/cmux/cmux.json
CMUX_SRC=home/.config/cmux/cmux.json
CMUX_HOOK_ID=wt                                    # the id install.sh keys its merge on
# shellcheck disable=SC2088   # the ~ is literal: cmux expands it, and the JSON that this compares with has it too
CMUX_HOOK_CMD='~/.local/bin/cmux-hook'             # …the command that makes an entry with that id OURS
CMUX_FRAGMENT='"command": "~/.local/bin/cmux-hook",'   # the paste-me line every refusal has to print
THEME_DST=.oh-my-zsh/custom/themes/workgrove.zsh-theme
THEME_SRC=home/.oh-my-zsh/custom/themes/workgrove.zsh-theme
TMUX_LINE='set -ag update-environment'                                   # enough to count occurrences
TMUX_FULL_LINE='set -ag update-environment " CMUX_SOCKET_PATH CMUX_WORKSPACE_ID"'   # the whole line, for -x

# assert_machinery <home> [cmux-linked yes|no]: everything that a default install owes every user, opinionated
# or not. The list comes from the repo and is not hard-coded, so a new bin/ script or skill that install.sh
# forgot to link fails here. The second argument, default "no", is for ~/.config/cmux/cmux.json. That file
# was once linked on every Mac and is now the sixth opt-in file. So only a caller that gave
# --with-cmux-config (or --opinionated-config) may expect the link. Either way it is exactly ONE assertion,
# so the count is the same.
assert_machinery() {
  local h="$1" cmux="${2:-no}" b n d
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
  # The three machine-local copies are real files, never links, so the apps can write their state into them.
  # Their mode is 600, because they hold local state and copy_config chmods them.
  assert_regular "$h" .claude/settings.json
  assert_regular "$h" .codex/config.toml
  assert_regular "$h" .codex/hooks.json
  assert_mode "$h" .claude/settings.json 600
  assert_mode "$h" .codex/config.toml 600
  assert_mode "$h" .codex/hooks.json 600
  # …and they must CONTAIN the .base file. An assertion that the two Codex copies only exist passes on a
  # zero-byte file. On a Mac, both take copy_config's plain `cp` branch, so neither was ever checked.
  # shellcheck disable=SC2088   # the ~ is the label a failure prints, not a path to expand
  assert_same_bytes "~/.codex/hooks.json is its .base file" \
    "$h/.codex/hooks.json" "$REPO/home/.codex/hooks.base.json"
  if [[ $OS == Darwin ]]; then
    # shellcheck disable=SC2088
    assert_same_bytes "~/.codex/config.toml is its .base file" \
      "$h/.codex/config.toml" "$REPO/home/.codex/config.base.toml"   # off a Mac it is filtered, not copied
  fi
  if [[ $OS == Darwin ]]; then
    if [[ $cmux == yes ]]; then
      assert_link "$h" "$CMUX_DST" "$CMUX_SRC"
    else
      # Not a link, but not absent either. hook_cmux_config merges the one machinery entry into the user's
      # own file, or writes a minimal one. So a default install on a Mac always leaves a real file here.
      assert_not_link "$h" "$CMUX_DST"
    fi
  fi
}

# assert_status_line <home> <yes|no>: settings.json may name the statusline script only when that script
# was installed. A statusLine command that points at a file that is not there breaks Claude's UI.
assert_status_line() {
  local h="$1" want="$2" got=no
  if jq -e 'has("statusLine")' "$h/.claude/settings.json" >/dev/null 2>&1; then
    got=yes
  fi
  assert_eq "the ~/.claude/settings.json statusLine key present" "$want" "$got"
}

# assert_settings_key <home> <key> <yes|no>: one top-level key of the ~/.claude/settings.json copy. It reads
# the key the same way as assert_status_line: with jq, not grep. So a key inside a string or a nested object
# is never mistaken for the top-level key.
assert_settings_key() {
  local h="$1" key="$2" want="$3" got=no
  if jq -e --arg k "$key" 'has($k)' "$h/.claude/settings.json" >/dev/null 2>&1; then
    got=yes
  fi
  assert_eq "the ~/.claude/settings.json $key key present" "$want" "$got"
}

# assert_claude_ui <home> <yes|no>: the whole settings.json contract in one call. .tui and .theme follow
# --with-claude-ui exactly. .voice has TWO independent reasons to be absent: the flag, and a machine with no
# microphone. So off a Mac it is absent even when the flag was given. This off-Mac case checks that the two
# strips compose and do not replace one another. .model and .effortLevel are gone from the repo, so no path
# may produce them. .hooks and .permissions are machinery: they are the reason that this file is installed
# unconditionally. So they must survive every combination, or the gating has gone too far.
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
  # .env holds one key, CLAUDE_CODE_DISABLE_MOUSE_CLICKS. It is UI taste in exactly the way .tui is: it
  # turns mouse clicks off in the Claude Code TUI. It was once installed unconditionally. So a default
  # install disabled a stranger's mouse, and nothing in the output named the key. The checks assert both
  # halves: the key follows the flag, and the object that held it does not remain as an empty `{}`.
  assert_settings_key "$h" env "$want"
  assert_mouse_key "$h" "$want"
}

# assert_mouse_key <home> <yes|no>: the one key inside .env. It reads the key as a path, not by name. So a
# top-level key of the same name cannot stand in for it.
assert_mouse_key() {
  local h="$1" want="$2" got=no
  if jq -e '.env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS' "$h/.claude/settings.json" >/dev/null 2>&1; then
    got=yes
  fi
  assert_eq "the ~/.claude/settings.json env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS key present" "$want" "$got"
}

# assert_only_linked <home> <index>: exactly one of the five is a link into the repo, and the other four are
# not links at all. It uses assert_not_link, not assert_absent, because the gitconfig and tmux.conf
# fallbacks correctly leave a regular file at two of those paths.
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

# manifest <home>: every path under a scratch HOME with its type and its symlink target. For a regular file,
# it also records a checksum of the contents and the permission mode. copy_config chmods its output to 600,
# and without the mode a regression there would pass unnoticed. The manifest records a symlink by its target
# and never follows it. So it stops at the repo boundary and does not checksum the repo itself.
#
# Nothing is excluded, on purpose. The manifest records only type, target and content: no mtimes, inodes,
# uids or pids. So the things that do differ from run to run never enter it. The FIRST run creates the
# one volatile-looking name, ~/.workgrove-backup/<timestamp>-<pid>. So keeping it makes the comparison
# strictly stronger. A second run that stashed anything would have to make a second directory beside it,
# and the diff would show that. If a future change adds something truly volatile (a cache, a log, a
# lockfile), put it on an exclusion list here, and write down the reason.
# file_mode <path>: -c is GNU, -f is BSD, the same pair that install.sh itself uses.
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

# 1. The default path: no flags, an otherwise empty HOME. Every stranger gets this path, and the author
#    never runs it.
scenario_default_empty() {
  begin_scenario "1. default install into an empty HOME"
  local h log
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_machinery "$h"
    # None of the five taste files, and not the theme, which only the linked .zshrc names.
    assert_absent "$h" .zshrc
    assert_absent "$h" .claude/keybindings.json
    assert_absent "$h" .claude/statusline-command.sh
    assert_absent "$h" "$THEME_DST"
    assert_regular "$h" .gitconfig           # configure_git makes a real file here; never a link
    assert_status_line "$h" no
    assert_claude_ui "$h" no                 # …and no UI taste in the settings.json copy either
    if [[ $OS == Darwin ]]; then
      assert_settings_key "$h" prefersReducedMotion no
      assert_eq "Mac Codex keeps its default animations" 0 \
        "$(count_matches "$h/.codex/config.toml" 'animations = false')"
    else
      assert_eq "VM Claude reduces terminal motion" true \
        "$(jq -r '.prefersReducedMotion' "$h/.claude/settings.json")"
      # install.sh appends a bare [tui] table, which becomes a duplicate-table TOML error once the base has one.
      assert_eq "VM Codex disables animations in its only [tui] table" "1 1" \
        "$(count_matches "$h/.codex/config.toml" '[tui]') $(count_matches "$h/.codex/config.toml" 'animations = false')"
    fi
    # The two settings that are machinery, not taste, must arrive anyway, through configure_git.
    assert_eq "core.excludesFile in the scratch ~/.gitconfig" \
      "$h/.gitignore_global" "$(scratch_git "$h" config --global --get core.excludesFile)"
    assert_eq "include.path in the scratch ~/.gitconfig" \
      "$h/.gitconfig.local" "$(scratch_git "$h" config --global --get-all --type=path include.path)"
    # ... and so must tmux's update-environment line, appended, not linked.
    assert_regular "$h" .tmux.conf
    assert_eq "update-environment lines in ~/.tmux.conf" 1 "$(count_matches "$h/.tmux.conf" "$TMUX_LINE")"
    # report_skipped must name each flag that the run did not get, or a user who wanted one never learns that
    # the flag exists. Scenario 17a checks the Mac-only --with-cmux-config.
    local f
    for f in "${FIVE_FLAG[@]}"; do
      assert_grep "install.sh output names $f as skipped" "$log" "$f"
    done
    assert_grep "install.sh output names $UI_FLAG as skipped" "$log" "$UI_FLAG"
  fi
  end_scenario
}

# 2. The regression that would hurt someone. A default install on top of a stranger's own
#    dotfiles must leave each of them a regular file with its own content.
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
    # `git config` edits ~/.gitconfig in place, so its checksum correctly changes. But it stays a real file,
    # and every section that the user wrote survives.
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
    # ~/.tmux.conf gains exactly one line and keeps the lines it had, including the last one, which the
    # fixture leaves without a newline on purpose. `grep -cF` counts LINES, so the count below reads 1 if
    # the line was appended and also if it was glued onto the user's last line. The anchored count tells
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
    assert_machinery "$h" yes        # --opinionated-config is all seven: the cmux.json link included
    for i in 0 1 2 3 4; do
      assert_link "$h" "${FIVE_DST[$i]}" "${FIVE_SRC[$i]}"
    done
    assert_link "$h" "$THEME_DST" "$THEME_SRC"
    assert_status_line "$h" yes
    assert_claude_ui "$h" yes                # --opinionated-config includes --with-claude-ui
    # Exactly one backup dir, holding all five originals with their own content.
    n=0
    bk=""
    for d in "$h"/.workgrove-backup/*/; do
      [[ -d "$d" ]] || continue
      bk="$d"
      n=$((n + 1))
    done
    assert_eq "backup directories under ~/.workgrove-backup" 1 "$n"
    # No loop and no `continue` guard around the five below. They were once inside the loop above, so a
    # run that stashed nothing at all skipped five assertions instead of failing them. The suite then stayed
    # green on a smaller total. With $bk empty, each of these now fails loudly, and that is the purpose.
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

# 4. Stickiness: `wt update` reruns install.sh bare. So a destination that is already linked into the repo
#    counts as opted in. It must survive a run that cannot see the original flag. The inverse matters
#    as much: a regular file there must NOT count as consent.
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
    # The theme comes with the .zshrc, and nothing else names it. So if the theme arrives with no flag,
    # that proves that opted_in said yes because of the existing link alone.
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

# 5. Idempotence. install.sh promises that a rerun is safe, and `wt update` reruns it constantly. So a
#    second run over an already-installed HOME must change nothing at all.
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
      # The backup dir from the first run is in both manifests. So if a second run stashed anything, its
      # stash would show up here as a new directory beside that dir.
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
      # The theme comes with ~/.zshrc and with nothing else.
      if [[ $i -eq 0 ]]; then
        assert_link "$h" "$THEME_DST" "$THEME_SRC"
      else
        assert_absent "$h" "$THEME_DST"
      fi
      # statusLine in settings.json must track --with-statusline exactly.
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

# 7. A usage error exits 2 with the usage on stderr, and installs nothing.
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

# 8. --with-claude-ui. It differs from the other --with-… flags in one way: it installs no file; it gates
#    keys inside a COPIED ~/.claude/settings.json. It is like them in the way that matters: it is sticky, and
#    its record is the keys themselves. A refactor is most likely to get this second part wrong. This part
#    also decides whether `wt update --refresh-config`, which cannot forward the flag, keeps a machine's UI
#    settings or silently deletes them.
scenario_claude_ui() {
  begin_scenario "8a. --with-claude-ui keeps the UI keys and links no file"
  local h log i f
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log" "$UI_FLAG"; then
    assert_machinery "$h"
    for i in 0 1 2 3 4; do            # it gates keys, not files: none of the five may come in with it
      assert_not_link "$h" "${FIVE_DST[$i]}"
    done
    assert_absent "$h" "$THEME_DST"
    assert_status_line "$h" no        # the statusline script is still its own flag's business
    assert_claude_ui "$h" yes
    # report_skipped still names the five that it did not install, and no longer names this one.
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
    # A rerun WITH the flag keeps the existing settings.json. So nothing changes, and nothing can: the flag
    # only reaches the file that install.sh writes. install.sh must say so, not report plain success.
    if assert_install_ok "$h" "$log.2" "$UI_FLAG"; then
      assert_claude_ui "$h" no
      assert_grep "the kept-copy warning names $UI_FLAG" "$log.2" "$UI_FLAG changed nothing"
    fi
    # --refresh-config rewrites the copy, and only then do the keys arrive.
    if assert_install_ok "$h" "$log.3" "$UI_FLAG" --refresh-config; then
      assert_claude_ui "$h" yes
    fi
    # …and a LATER refresh with no flag keeps them. This is the stickiness rule of scenario 4a, in the one
    # place where the record cannot be a symlink. Here, the .tui key of the file about to be rewritten is
    # the record of the earlier flag. The one documented way to pick up a change to a .base file is
    # --refresh-config. `wt update --refresh-config` runs it, but `wt update` cannot forward
    # --with-claude-ui.
    # Without the record, that refresh would delete the UI keys of every machine that has them, while
    # report_skipped called it "left alone".
    if assert_install_ok "$h" "$log.4" --refresh-config; then
      assert_claude_ui "$h" yes
      assert_eq "$UI_FLAG listed as skipped once it is installed" 0 "$(count_matches "$log.4" "$UI_FLAG")"
    fi
  fi
  # The inverse makes the .tui key a record and not a default. A copy written WITHOUT the keys stays
  # without them through a refresh. In the same way, a regular file at ~/.zshrc is not an opt-in.
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

# 9. The refusals. require_plain_file stops `git config --global` and append_line's >> from writing through
#    a dangling symlink that points anywhere on disk. None of its callers was tested: a change that neutered
#    it left the suite green. Each escape target below is inside TEST_ROOT on purpose, because
#    guard_scratch_home constrains $HOME, not the target of a symlink under it. Each case also asserts that
#    the refusal came BEFORE anything moved. That is the whole reason that the check_… twins exist.
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
  # `git config --global` writes ~/.config/git/config whenever that exists and ~/.gitconfig does not. So
  # check_gitconfig must guard that file. When it guarded ~/.gitconfig alone, git took the install down
  # mid-way instead, after six steps had already moved things. git exited 128 and printed
  # "fatal: unknown error occurred while reading the configuration files".
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/git/config"
  assert_install_fails "$h" "$log" 1 "not a regular file: ~/.config/git/config"
  assert_absent "$h" .zshenv
  end_scenario
}

# 10. Who owns a symlink. our_link's own comment calls a live link that lands elsewhere "the one link
#     this script must never touch", and opted_in reads the answer as CONSENT. So a wrong yes gives a
#     stranger the author's shell prompt, and nothing in the output says so. None of this was tested.
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
    assert_absent "$h" "$THEME_DST"                 # the theme comes with an opt-in that never happened
    assert_grep "--with-zshrc still listed as skipped" "$log" "--with-zshrc"
  fi
  end_scenario

  begin_scenario "10b. a DANGLING foreign link is not consent either"
  # home/.zshrc is not a distinctive tail: chezmoi, yadm, dotbot, homeshick and a `home` stow package all
  # produce it. A machine's dotfile links can be dangling for a short time. For example, bootstrap ran
  # before the dotfiles repo was cloned, or the repo is on an unmounted volume. Such a machine once read
  # as "already opted in" to a run given no flags. report_skipped then omitted the flag, so the one line
  # that would have said so was silent.
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
  # The case that the dangling-tail rule exists for. It also shows that the stricter opted_in did not turn
  # the rule off. Every run links ~/.zshenv, and no dotfile manager owns one. So its own dangling target
  # names the clone that this machine was installed from. A sibling under that same old root is this
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

# 11. configure_git's two don't-clobber branches. Each one silently destroys a stranger's configuration if it
#     regresses, and the suite stayed green when either one was deleted.
scenario_git_keeps_yours() {
  begin_scenario "11. configure_git keeps an excludesFile and an include.path you already had"
  local h log want got
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.mine"
  printf '%s\n' '*.swp' >"$h/.mine/ignore"
  # Written with a ~ on purpose. configure_git reads both values with --type=path so that a value in this
  # form compares equal to the expanded one. Then configure_git does not warn about itself forever.
  printf '[core]\n\texcludesFile = ~/.mine/ignore\n[include]\n\tpath = ~/.my-extra-config\n' >"$h/.gitconfig"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the user's core.excludesFile survives" "$h/.mine/ignore" \
      "$(scratch_git "$h" config --global --get --type=path core.excludesFile)"
    assert_grep "install.sh says it kept it" "$log" "kept core.excludesFile"
    assert_grep "…and says what that costs" "$log" "add the lines of ~/.gitignore_global"
    assert_grep "the user's own spelling is still in the file" "$h/.gitconfig" "excludesFile = ~/.mine/ignore"
    # include.path is multi-valued: a plain `git config include.path …` would overwrite the user's one
    # value, and would refuse outright when there are two. Ours is added with --add, after theirs.
    want="$(printf '%s\n%s' "$h/.my-extra-config" "$h/.gitconfig.local")"
    got="$(scratch_git "$h" config --global --get-all --type=path include.path)"
    assert_eq "include.path keeps the user's value and gains ours, in that order" "$want" "$got"
  fi
  end_scenario
}

# 12. "A dotfile manager owns it, skip and warn." There are three branches, one per file, and none of them
#     was tested: a regression writes through somebody's dotfiles repo and reports success. This scenario
#     also covers the one place that does NOT skip, by design, so the asymmetry is asserted, not assumed.
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
  # No ~/.gitconfig at all, so `git config --global` writes the XDG file, through the manager's symlink.
  # That is the one thing that configure_git promises not to do. It once did exactly that, and then
  # reported two settings added to a ~/.gitconfig that does not exist.
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
  # copy_config is the one step that does not leave a dotfile manager's link alone, on purpose. Claude and
  # Codex write their own state into these three files, so they must be real files at the path that the app
  # opens. Only the LINK moves, and the file that it pointed at is untouched. The run must name the
  # displacement, and not fold it into "installed ~/…".
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

# 13. remove_retired_links, and install_bins' ~/bin retirement. The suite stayed green when either one was
#     neutered. The first exists because of a real incident: a renamed oh-my-zsh theme outlived its rename
#     on every machine, and `wt update` reruns this script constantly.
scenario_retired_links() {
  local h log bk

  begin_scenario "13a. links whose source the repo no longer has are retired, whatever named them"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.claude/skills" "$h/.agents/skills" "$h/.local/bin"
  ln -s "$REPO/home/.agents/skills/renamed-away" "$h/.claude/skills/renamed-away"   # made by THIS clone
  # The same links, made before the clone moved. For these three, the repo-relative source is NOT the
  # home-relative path. So a source inferred from the path never matched, and they were never retired:
  # ~/.local/bin/<b> comes from bin/<b>, and ~/.claude/skills/<n> from home/.agents/skills/<n>.
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

# 14. The two prerequisites that stop the run before it starts. The suite stayed green when either
#     was neutered.
scenario_prerequisites() {
  local h log

  begin_scenario "14a. no git identity anywhere: refused before anything moves"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  rm -f "$h/.gitconfig.local"          # new_home's only fixture: the identity that require_git_identity reads
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

# 15. $ZSH_CUSTOM. oh-my-zsh looks for the theme that ~/.zshrc names under $ZSH_CUSTOM/themes and nowhere
#     else, and install_zsh_plugins has always honored the variable. So oh-my-zsh never finds a theme that is
#     linked into the hardcoded ~/.oh-my-zsh/custom. Every shell start says so, while every line of the
#     install says success. This happened to the author.
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
    assert_link "$h" .config/omz-custom/themes/workgrove.zsh-theme "$THEME_SRC"
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

# shellcheck disable=SC2016   # the $HOME in the bashrc line and in the WT_REPOS_DIR line is literal: the
#                              lines that install.sh writes carry the variable, not its value.
# 16. The Linux-only legs, driven from a Mac with FORCE_OS. hook_bashrc is the most intricate function in
#     install.sh. It is unreachable on Darwin, and so are ask_vm_host, record_repos_dir and the two platform
#     filters in copy_config. A green run on the author's machine exercised none of them. FORCE_OS exists
#     in install.sh only for this purpose.
scenario_linux_legs() {
  local h log sum
  local line='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

  begin_scenario "16a. FORCE_OS=Linux: the VM-only steps run"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  if assert_install_ok "$h" "$log" "$UI_FLAG"; then
    # hook_bashrc writes the file when there is none, and the line must be the FIRST one. Ubuntu's own
    # ~/.bashrc returns on its fourth line for a non-interactive shell. `wt -H <vm> …` works through
    # `ssh <vm> '<cmd>'`, which is exactly that kind of shell.
    assert_regular "$h" .bashrc
    assert_eq "the ~/.zshenv line is the first line of ~/.bashrc" 1 \
      "$(head -n 1 "$h/.bashrc" | grep -cF -- "$line" || true)"
    # ask_vm_host and record_repos_dir, the two lines that a VM's ~/.zshenv.local gains.
    assert_grep "WT_HOST recorded" "$h/.zshenv.local" "export WT_HOST=$VM_HOST"
    assert_grep "WT_REPOS_DIR recorded" "$h/.zshenv.local" 'export WT_REPOS_DIR="$HOME"'
    # copy_config's two platform filters, both of them Linux-only.
    assert_settings_key "$h" tui yes            # --with-claude-ui was given…
    assert_settings_key "$h" voice no           # …and the voice keys go anyway: a VM has no microphone
    assert_eq "VM Claude reduces terminal motion with UI enabled" true \
      "$(jq -r '.prefersReducedMotion' "$h/.claude/settings.json")"
    assert_eq "VM Codex disables animations in its only [tui] table with UI enabled" "1 1" \
      "$(count_matches "$h/.codex/config.toml" '[tui]') $(count_matches "$h/.codex/config.toml" 'animations = false')"
    assert_eq "the Keychain line is filtered out of ~/.codex/config.toml" 0 \
      "$(count_matches "$h/.codex/config.toml" "cli_auth_credentials_store")"
    assert_absent "$h" .config/cmux/cmux.json   # cmux runs on the Mac only
  fi
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  if assert_install_ok "$h" "$log"; then
    assert_settings_key "$h" tui no
    assert_eq "VM Claude reduces terminal motion without UI opt-in" true \
      "$(jq -r '.prefersReducedMotion' "$h/.claude/settings.json")"
    assert_eq "VM Codex disables animations in its only [tui] table without UI opt-in" "1 1" \
      "$(count_matches "$h/.codex/config.toml" '[tui]') $(count_matches "$h/.codex/config.toml" 'animations = false')"
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
  # VM. When our line is already first, hook_bashrc returns before it reads the mode. So a refusal there
  # failed the install, and with it every `wt update`, forever. It failed over a file that nothing would
  # have touched, with words that described a copy that would not happen.
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


# cmux_ids <home>: the ids of ~/.config/cmux/cmux.json's hooks, in file order, space-separated. The order is
# the whole point. cmux composes hooks in the order that it reads them. An entry that is prepended, not
# appended, runs before a user's hook that suppresses the notification, and the suppression never applies.
# `jq -j` prints a trailing space and no newline, so bash 3.2's $( ) does not have to strip one.
cmux_ids() {
  jq -j '(.notifications.hooks // [])[] | .id, " "' "$1/$CMUX_DST" 2>/dev/null || true
}

# cmux_cmd <home>: the command of the hook whose id is "wt", which is the entry that install.sh merges in.
cmux_cmd() {
  jq -r --arg id "$CMUX_HOOK_ID" \
    'first((.notifications.hooks // [])[] | select(.id == $id)) | .command // ""' \
    "$1/$CMUX_DST" 2>/dev/null || true
}

# 17. The sixth opt-in FILE, and the merge that stands in for it. ~/.config/cmux/cmux.json was once linked on
#     every Mac, unconditionally. 275 of its 279 lines are a palette, sound overrides, a sidebar layout and
#     three hotkeys. The other four are the notifications hook that runs ~/.local/bin/cmux-hook. That hook is
#     how a `wt` row on a VM learns which row fired. So it is the one part of the file that is machinery.
#     For that reason, the file is now opt-in like the other five. Without the flag, install.sh merges that
#     ONE entry into whatever the user already has. All the risk is in that merge: jq rewrites the whole of
#     a file that this repo does not own. The file format is JSONC, which jq cannot always read. Every case
#     that the merge can meet is below. Each case that install.sh declines also asserts that the file is
#     byte-identical afterwards. Otherwise, a refusal that still rewrote the file would pass on the message
#     alone.
#     All of it is Darwin-only: cmux is a Mac application, and install.sh does nothing with the file on any
#     other platform. Scenario 16a asserts that from the other side.
# shellcheck disable=SC2088   # every ~ below is literal: these are the strings inside a cmux.json, not paths
scenario_cmux_config() {
  if [[ $OS != Darwin ]]; then
    return 0
  fi
  local h log sum before after

  begin_scenario "17a. no cmux.json at all: a default install writes a minimal one"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_machinery "$h"
    assert_regular "$h" "$CMUX_DST"
    assert_eq "the hooks of the created ~/$CMUX_DST" "$CMUX_HOOK_ID " "$(cmux_ids "$h")"
    assert_eq "the merged hook's command" "$CMUX_HOOK_CMD" "$(cmux_cmd "$h")"
    assert_eq "the schemaVersion of the created file" 1 \
      "$(jq -r '.schemaVersion' "$h/$CMUX_DST" 2>/dev/null || true)"
    # A running cmux does not reread the file. If the run says nothing about that, the user believes that
    # the hook is live when it is not.
    assert_grep "the run says a running cmux has to be told" "$log" "cmux reload-config"
    assert_grep "report_skipped names the new flag" "$log" "$CMUX_FLAG"
  fi
  end_scenario

  begin_scenario "17b. a stranger's strict-JSON cmux.json keeps everything and gains one entry"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{' '  "schemaVersion": 3,' '  "paneBorderColor": "#ff00ff",' \
                '  "theme": { "accent": "#123456" }' '}' >"$h/$CMUX_DST"
  if assert_install_ok "$h" "$log"; then
    assert_not_link "$h" "$CMUX_DST"
    assert_grep "the stranger's palette survives" "$h/$CMUX_DST" '#ff00ff'
    assert_grep "…and their theme object with it" "$h/$CMUX_DST" '#123456'
    # install.sh leaves schemaVersion exactly as it was, whatever its value: it has no opinion about it.
    assert_eq "the stranger's schemaVersion is untouched" 3 \
      "$(jq -r '.schemaVersion' "$h/$CMUX_DST" 2>/dev/null || true)"
    assert_eq "the hooks after the merge" "$CMUX_HOOK_ID " "$(cmux_ids "$h")"
    assert_eq "the merged hook's command" "$CMUX_HOOK_CMD" "$(cmux_cmd "$h")"
    assert_grep "install.sh says it merged" "$log" "merged the cmux-hook entry"
    # Nothing is deleted here either: the file that install.sh rewrote is in the backup dir, unchanged.
    assert_grep "the original is in the backup dir" "$(backup_dir "$h")/$CMUX_DST" '#ff00ff'
  fi
  end_scenario

  begin_scenario "17c. an existing hooks array keeps its order, and ours is appended LAST"
  # Not a detail: cmux runs the hooks in file order, and this repo's own file puts quiet-when-focused
  # before wt on purpose. So an entry that arrived first would run before the suppression decision.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{' '  "schemaVersion": 1,' '  "notifications": {' '    "sound": "Pop",' \
                '    "hooks": [' \
                '      { "command": "~/bin/mine", "id": "quiet-when-focused", "timeoutSeconds": 5 }' \
                '    ]' '  }' '}' >"$h/$CMUX_DST"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the hook order after the merge" "quiet-when-focused $CMUX_HOOK_ID " "$(cmux_ids "$h")"
    assert_eq "the user's own hook is untouched" "~/bin/mine" \
      "$(jq -r 'first(.notifications.hooks[] | select(.id == "quiet-when-focused")) | .command' \
         "$h/$CMUX_DST" 2>/dev/null || true)"
    assert_eq "the rest of .notifications survives" "Pop" \
      "$(jq -r '.notifications.sound' "$h/$CMUX_DST" 2>/dev/null || true)"
  fi
  end_scenario

  begin_scenario "17d. a cmux.json with // comments is refused, untouched, and the fragment is printed"
  # cmux documents JSONC, and `cmux config check` accepts it, but jq cannot parse it at all. Because no
  # rewrite is safe, install.sh leaves the file exactly as it is. It tells the user what to paste and what
  # stays broken.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{' '  // my own cmux settings' '  "schemaVersion": 1,' '  "paneBorderColor": "#ff0000"' '}' \
    >"$h/$CMUX_DST"
  sum="$(cksum <"$h/$CMUX_DST")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the JSONC file is byte-identical afterwards" "$sum" "$(cksum <"$h/$CMUX_DST")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/$CMUX_DST:"
    assert_grep "…and said it is the comments" "$log" "JSONC"
    assert_grep "…and printed the entry to paste" "$log" "$CMUX_FRAGMENT"
    assert_grep "…and said what stays broken" "$log" "never attaches or opens"
  fi
  end_scenario

  begin_scenario "17e. a cmux.json that is not valid JSON at all is refused and untouched"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{ "schemaVersion": 1, "paneBorderColor":' >"$h/$CMUX_DST"
  sum="$(cksum <"$h/$CMUX_DST")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the broken file is byte-identical afterwards" "$sum" "$(cksum <"$h/$CMUX_DST")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/$CMUX_DST:"
    assert_grep "…and said jq cannot parse it" "$log" "jq cannot parse it"
    assert_grep "…and printed the entry to paste" "$log" "$CMUX_FRAGMENT"
  fi
  end_scenario

  begin_scenario "17f. a notifications key of a shape this merge does not know is refused"
  # Valid JSON, and jq would happily overwrite it. That is the point: .notifications of the wrong type is
  # still somebody's configuration, and the merge filter cannot keep what is there.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{ "schemaVersion": 1, "notifications": "loud" }' >"$h/$CMUX_DST"
  sum="$(cksum <"$h/$CMUX_DST")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the file is byte-identical afterwards" "$sum" "$(cksum <"$h/$CMUX_DST")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/$CMUX_DST:"
    assert_grep "…and said what it could not merge into" "$log" "not a shape this script can merge into"
  fi
  end_scenario

  begin_scenario "17g. a hook of the user's already using the id \"wt\" is named, not overwritten"
  # The one case with no safe answer. An overwrite loses their hook. A quiet skip leaves the relay dead
  # while every line of the run says success.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{' '  "notifications": { "hooks": [' \
                '    { "command": "~/bin/my-own-wt-hook", "id": "wt", "timeoutSeconds": 3 }' '  ] }' '}' \
    >"$h/$CMUX_DST"
  sum="$(cksum <"$h/$CMUX_DST")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the file is byte-identical afterwards" "$sum" "$(cksum <"$h/$CMUX_DST")"
    assert_eq "their hook still has the id" "~/bin/my-own-wt-hook" "$(cmux_cmd "$h")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/$CMUX_DST:"
    assert_grep "…and named the command it found" "$log" "~/bin/my-own-wt-hook"
    assert_grep "…and said overwriting would lose it" "$log" "would lose your hook"
  fi
  end_scenario

  begin_scenario "17h. a cmux.json a dotfile manager owns is left alone and named"
  # The one thing this family of functions must never do: write through somebody's dotfiles link.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_manager "$h"
  printf '%s\n' '{ "schemaVersion": 1, "paneBorderColor": "#00ff00" }' >"$h/dotfiles/cmux.json"
  mkdir -p "$h/.config/cmux"
  ln -s "$h/dotfiles/cmux.json" "$h/$CMUX_DST"
  sum="$(cksum <"$h/dotfiles/cmux.json")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the link is still the manager's" "$h/dotfiles/cmux.json" "$(readlink "$h/$CMUX_DST")"
    assert_eq "the file it points at is byte-identical" "$sum" "$(cksum <"$h/dotfiles/cmux.json")"
    assert_grep "install.sh named the skip" "$log" "skipped ~/$CMUX_DST:"
    assert_grep "…and printed the entry to paste" "$log" "$CMUX_FRAGMENT"
  fi
  end_scenario

  begin_scenario "17i. a dangling cmux.json is refused before anything moves"
  # check_cmux_config's job: a whole-file rewrite through a dangling link would land wherever the link points.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  ln -s "$TEST_ROOT/escaped-cmux-json" "$h/$CMUX_DST"
  assert_install_fails "$h" "$log" 1 "broken symlink at ~/$CMUX_DST"
  assert_absent "$TEST_ROOT" escaped-cmux-json
  assert_absent "$h" .zshenv
  end_scenario

  begin_scenario "17j. $CMUX_FLAG links the whole file and stashes what was there"
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{ "schemaVersion": 1, "paneBorderColor": "#00ff00" }' >"$h/$CMUX_DST"
  if assert_install_ok "$h" "$log" "$CMUX_FLAG"; then
    assert_machinery "$h" yes
    assert_link "$h" "$CMUX_DST" "$CMUX_SRC"
    assert_grep "the stranger's own file was stashed" "$(backup_dir "$h")/$CMUX_DST" '#00ff00'
    assert_eq "$CMUX_FLAG listed as skipped" 0 "$(count_matches "$log" "$CMUX_FLAG")"
    # It gates one file and nothing else: none of the other five may come in with it.
    local i
    for i in 0 1 2 3 4; do
      assert_not_link "$h" "${FIVE_DST[$i]}"
    done
    assert_claude_ui "$h" no
  fi
  end_scenario

  begin_scenario "17k. sticky, and idempotent whichever way the file got there"
  # Two reruns, because there are two records to keep. The LINK is the flag's record, and consenting_link
  # reads it exactly as it reads the other five. The MERGED file's record is the entry itself, keyed on the
  # id, so a second run must not append a second copy.
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log" "$CMUX_FLAG"; then
    if assert_install_ok "$h" "$log.2"; then          # bare: `wt update` cannot forward the flag
      assert_link "$h" "$CMUX_DST" "$CMUX_SRC"
      assert_eq "$CMUX_FLAG listed as skipped after a bare rerun" 0 "$(count_matches "$log.2" "$CMUX_FLAG")"
    fi
  fi
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/cmux"
  printf '%s\n' '{ "schemaVersion": 1, "paneBorderColor": "#00ff00" }' >"$h/$CMUX_DST"
  before="$h.manifest.1"
  after="$h.manifest.2"
  if assert_install_ok "$h" "$log"; then
    manifest "$h" >"$before"
    if assert_install_ok "$h" "$log.2"; then
      manifest "$h" >"$after"
      assert_unchanged "a merged cmux.json, second run" "$before" "$after"
      assert_eq "the hooks after the second run" "$CMUX_HOOK_ID " "$(cmux_ids "$h")"
      assert_eq "nothing was merged a second time" 1 "$(count_matches "$h/$CMUX_DST" "$CMUX_HOOK_CMD")"
      assert_eq "the second run says nothing about cmux.json" 0 "$(count_matches "$log.2" "$CMUX_DST")"
    fi
  fi
  end_scenario
}

# ---------------------------------------------------------------------------- main

# expected_assertions: the number of assertions that a complete run makes. An assertion on the TOTAL catches
# the failure mode that a pass/fail count cannot see: a scenario that stops asserting, not one that starts
# failing. One mutation quietly took the suite from 323 to 318 that way, with every scenario still green.
# It is a formula, not a number, because assert_machinery derives its assertions from the repo. Add a bin/
# script or a skill, and the count correctly moves. Everything else is fixed. A fixed number that needs an
# edit whenever someone adds an assertion is the point.
expected_assertions() {
  local nbin=0 nskill=0 per d fixed=$FIXED_ASSERTIONS
  for d in "$REPO"/bin/*; do
    [[ -e "$d" ]] && nbin=$((nbin + 1))
  done
  for d in "$REPO"/home/.agents/skills/*/; do
    [[ -d "$d" ]] && nskill=$((nskill + 1))
  done
  # one assert_machinery call: 5 links + one per bin script + two per skill + 3 regular + 3 modes + the
  # hooks.json checksum. On a Mac, add one cmux.json assertion (link or not-link, one either way) and the
  # config.toml checksum.
  per=$((5 + nbin + 2 * nskill + 3 + 3 + 1))
  # …called by scenarios 1, 2, 3 and 8a everywhere, and by 17a and 17j on a Mac only. When those two were
  # counted unconditionally, the guard demanded 2 * per assertions that a Linux run had no scenarios to
  # make. So the suite could not pass on a VM, however correct the code was.
  local calls=4
  if [[ $OS == Darwin ]]; then
    per=$((per + 2))
    fixed=$((fixed + CMUX_ASSERTIONS))
    calls=6
  fi
  echo "$((fixed + calls * per))"
}

# Everything that is not assert_machinery. Bump it in the same commit as the assertion you added.
FIXED_ASSERTIONS=384
# Scenario 17's own assertions, counted apart because that whole group is Darwin-only. ~/.config/cmux/cmux.json
# is a Mac file, and install.sh does nothing with it on any other platform. A fixed total would be correct on
# one platform and wrong on the other. It would fail the suite on a VM, for a reason unrelated to the code.
CMUX_ASSERTIONS=78

# shellcheck disable=SC2016   # $BASH_VERSION below is for the OTHER bash to expand, not this one
main() {
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
  scenario_cmux_config
  lib_summary "$(expected_assertions)"
}

seed_other_checkout
main "$@"
