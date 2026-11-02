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
# The absolute rule: nothing here may touch anything under the real $HOME. Every install.sh scenario runs
# install.sh with HOME set to a fresh mktemp -d. Scenario 18 sources home/.zshenv with such a HOME instead.
# At the start of each scenario, guard_scratch_home refuses if that HOME resolves anywhere under the real
# home. run_install pins XDG_CONFIG_HOME to the scratch HOME and unsets GIT_CONFIG_GLOBAL and ZSH_CUSTOM,
# because these variables could otherwise let a write escape it. No scenario needs the network or sudo.
# The plugin clone is the only network step in install.sh, and the fixtures pre-create the plugin
# directories, so the clone never runs.
#
# An assertion is silent when it holds and loud when it fails. The script prints one line per scenario and
# a pass/fail count. It exits non-zero if any assertion failed.
#
# Each scenario must make an assertion. Each loop over an expected directory asserts instead of continuing.
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
  # Keep the final line unterminated to check that a default install preserves the user's file exactly.
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

# zshenv_paths <shell> <home> <os> [VAR=value ...]: source home/.zshenv with <shell> under set -eu, with a
# stub uname that prints <os>. Print the two cmux agent path variables, or "unset" for each one that is empty.
zshenv_paths() {
  local shell=$1 h=$2 os=$3
  mkdir -p "$h.stub"
  printf '#!/bin/sh\necho %s\n' "$os" >"$h.stub/uname"
  chmod +x "$h.stub/uname"
  # shellcheck disable=SC2016  # The child shell expands these.
  env -i HOME="$h" PATH="$h.stub:/usr/bin:/bin" "${@:4}" "$shell" -euc \
    '. "$1"; echo "${CMUX_CUSTOM_CODEX_PATH:-unset} ${CMUX_CUSTOM_CLAUDE_PATH:-unset}"' zshenv "$REPO/home/.zshenv"
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
# SF_MONO_SRC points install_sf_mono at SF_MONO_FIXTURE, so no run copies the real fonts. A RUN_EXTRA_ENV
# assignment comes later on the env line, so it overrides that default.
RUN_EXTRA_ENV=()
run_install() {
  local h="$1" log="$2" rc=0 extra
  shift 2
  guard_scratch_home "$h"
  extra=(${RUN_EXTRA_ENV[@]+"${RUN_EXTRA_ENV[@]}"})
  RUN_EXTRA_ENV=()
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT -u ZSH_CUSTOM \
      HOME="$h" XDG_CONFIG_HOME="$h/.config" WT_HOST="$VM_HOST" SF_MONO_SRC="$SF_MONO_FIXTURE" \
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
# The opinionated install checks the cmux configuration link on the Mac.
CMUX_FLAG=--with-cmux-config
CMUX_DST=.config/cmux/cmux.json
CMUX_SRC=home/.config/cmux/cmux.json
# The Ghostty config and its two themes come with cmux.json. Each one is its own link: ~/.config/ghostty stays
# a real directory, because the tools that edit it write .bak files into it.
GHOSTTY_FILES=(config themes/learning-dark themes/learning-light)
# The stand-in for Terminal.app's font folder: two SF Mono files, and one file that the pattern must skip.
SF_MONO_FIXTURE="$TEST_ROOT/sf-mono"
SF_MONO_FONTS=(SF-Mono-Regular.otf SF-Mono-Bold.otf)
mkdir -p "$SF_MONO_FIXTURE"
for f in "${SF_MONO_FONTS[@]}" SFMono-Terminal.ttf; do printf 'font %s\n' "$f" >"$SF_MONO_FIXTURE/$f"; done
THEME_DST=.oh-my-zsh/custom/themes/workgrove.zsh-theme
THEME_SRC=home/.oh-my-zsh/custom/themes/workgrove.zsh-theme
# assert_machinery <home> [cmux-linked yes|no]: everything that a default install owes every user, opinionated
# or not. The list comes from the repo and is not hard-coded, so a new bin/ script or skill that install.sh
# forgot to link fails here. The second argument, default "no", is for ~/.config/cmux/cmux.json. That file
# was once linked on every Mac and is now the sixth opt-in file. So only a caller that gave
# --with-cmux-config (or --opinionated-config) may expect the link, and the three Ghostty links with it.
# Either way the number of assertions is the same.
assert_machinery() {
  local h="$1" cmux="${2:-no}" b n d f
  assert_link "$h" .zshenv home/.zshenv
  assert_link "$h" .gitignore_global home/.gitignore_global
  assert_link "$h" .claude/AGENTS.md home/.claude/AGENTS.md
  assert_link "$h" .claude/TASKS.md home/.claude/TASKS.md
  assert_link "$h" .claude/CLAUDE.md home/.claude/CLAUDE.md
  assert_link "$h" .codex/AGENTS.md home/.claude/AGENTS.md
  assert_link "$h" .codex/TASKS.md home/.claude/TASKS.md
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
      for f in "${GHOSTTY_FILES[@]}"; do
        assert_link "$h" ".config/ghostty/$f" "home/.config/ghostty/$f"
      done
    else
      assert_not_link "$h" "$CMUX_DST"
      for f in "${GHOSTTY_FILES[@]}"; do
        assert_not_link "$h" ".config/ghostty/$f"
      done
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

# assert_claude_ui checks optional UI settings. Fullscreen is always enabled on VMs; the Mac retains its opt-in.
# Voice has two independent reasons to be absent: the flag, and a machine with no
# microphone. So off a Mac it is absent even when the flag was given. This off-Mac case checks that the two
# strips compose and do not replace one another. .model and .effortLevel are gone from the repo, so no path
# may produce them. .hooks and .permissions are machinery: they are the reason that this file is installed
# unconditionally. So they must survive every combination, or the gating has gone too far.
assert_claude_ui() {
  local h="$1" want="$2" voice="$2" tui="$2"
  if [[ $OS != Darwin ]]; then
    voice=no
    tui=yes
  fi
  assert_settings_key "$h" tui "$tui"
  if [[ $tui == yes ]]; then
    assert_eq "Claude uses fullscreen mode" fullscreen "$(jq -r '.tui' "$h/.claude/settings.json")"
  fi
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
# not links at all. assert_not_link also accepts a user-owned regular file at these paths.
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
  begin_scenario "1. default install into an empty HOME" || return 0
  local h log
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_machinery "$h"
    # The linked wt must find lib/ through its link. So run it from another folder, not from the repo.
    (cd "$TEST_ROOT" && env -i PATH="$PATH" HOME="$h" "$h/.local/bin/wt" help) >"$h.wt-help" 2>&1 || true
    assert_grep "the linked ~/.local/bin/wt prints its help" "$h.wt-help" 'wt new  [name]'
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
    assert_absent "$h" .tmux.conf
    # report_skipped must name each flag that the run did not get, or a user who wanted one never learns that
    # the flag exists.
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
  begin_scenario "2. default install over a stranger's existing dotfiles" || return 0
  local h log zsum_before gsum_before tmux_before
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_opinionated_originals "$h"
  zsum_before="$(cksum <"$h/.zshrc")"
  gsum_before="$(cksum <"$h/.gitconfig")"
  tmux_before="$(cksum <"$h/.tmux.conf")"
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
    assert_eq "the ~/.tmux.conf checksum" "$tmux_before" "$(cksum <"$h/.tmux.conf")"
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
  begin_scenario "3. --opinionated-config links all five and stashes the originals" || return 0
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
scenario_sticky_link() {
  begin_scenario "4a. an existing link into the repo keeps its opt-in with no flags" || return 0
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
}

scenario_regular_not_opted_in() {
  begin_scenario "4b. an existing regular file is not an opt-in" || return 0
  local h log
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
scenario_default_idempotent() {
  begin_scenario "5a. a second default run changes nothing" || return 0
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
}

scenario_opinionated_idempotent() {
  begin_scenario "5b. a second --opinionated-config run changes nothing" || return 0
  local h log before after
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
scenario_individual_flag() {
  local i=$1 h log
  begin_scenario "6. ${FIVE_FLAG[$i]} alone installs only ${FIVE_DST[$i]}" || return 0
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
}

scenario_individual_flags() {
  local i
  for i in 0 1 2 3 4; do scenario_individual_flag "$i"; done
}

# 7. A usage error exits 2 with the usage on stderr, and installs nothing.
scenario_unknown_flag() {
  begin_scenario "7. an unknown flag exits 2 with usage on stderr" || return 0
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
  assert_eq "usage retains its flags and line breaks" 'usage: install.sh [--refresh-config] [--opinionated-config]
                  [--with-zshrc] [--with-gitconfig] [--with-tmux-conf]
                  [--with-keybindings] [--with-statusline] [--with-claude-ui]
                  [--with-cmux-config]' "$(head -4 "$err")"
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
scenario_claude_ui_keys() {
  begin_scenario "8a. --with-claude-ui keeps the UI keys and links no file" || return 0
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
    assert_eq "$UI_FLAG listed as skipped" 0 \
      "$(sed -n '/^left alone /p; /^    Optional config was not selected:/p' "$log" | grep -cF -- "$UI_FLAG" || true)"
  fi
  end_scenario
}

scenario_claude_ui_sticky() {
  begin_scenario "8b. --with-claude-ui is sticky: the keys it wrote are the record of it" || return 0
  local h log command
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
      command=$(sed -n '/^Install summary:/,$p' "$log.2" | sed -n 's/^    Run: \(install.sh --with-claude-ui --refresh-config\)$/\1/p')
      assert_eq "the UI recovery command retains its opt-in" "install.sh $UI_FLAG --refresh-config" "$command"
      assert_eq "the summary lists the requested recovery once" 1 "$(sed -n '/^Install summary:/,$p' "$log.2" | grep -cxF -- '    Run: install.sh --with-claude-ui --refresh-config' || true)"
    fi
    # --refresh-config rewrites the copy, and only then do the keys arrive.
    # Execute the summary's command, including the required opt-in flag.
    local recovery_args=()
    read -r -a recovery_args <<<"$command"
    if assert_install_ok "$h" "$log.3" "${recovery_args[@]:1}"; then
      assert_claude_ui "$h" yes
    fi
    # …and a LATER refresh with no flag keeps them. This is the stickiness rule of scenario 4a, in the one
    # place where the record cannot be a symlink. The optional UI keys record the earlier flag.
    # The documented way to pick up a change to a .base file is
    # --refresh-config. `wt update --refresh-config` runs it, but `wt update` cannot forward
    # --with-claude-ui.
    # Without the record, that refresh would delete the UI keys of every machine that has them, while
    # report_skipped called it "left alone".
    if assert_install_ok "$h" "$log.4" --refresh-config; then
      assert_claude_ui "$h" yes
      assert_eq "$UI_FLAG listed as skipped once it is installed" 0 "$(count_matches "$log.4" "$UI_FLAG")"
    fi
  fi
  # A default copy keeps optional UI keys absent through a refresh. VM fullscreen does not select them.
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
scenario_dangling_gitconfig() {
  begin_scenario "9a. a dangling ~/.gitconfig is refused, and nothing is written through it" || return 0
  local h log

  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  ln -s "$TEST_ROOT/escaped-gitconfig" "$h/.gitconfig"
  assert_install_fails "$h" "$log" 1 "broken symlink at ~/.gitconfig"
  assert_absent "$TEST_ROOT" escaped-gitconfig      # git config --global would have created it out here
  assert_absent "$h" .zshenv                        # …and it refused before the first link was made
  assert_absent "$h" .local/bin
  end_scenario
}

scenario_gitconfig_directory() {
  begin_scenario "9d. a directory at git's OTHER global file is refused, in this script's voice" || return 0
  local h log

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
scenario_live_foreign_link() {
  begin_scenario "10a. a live link into a second checkout is never touched" || return 0
  local h log

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
}

scenario_dangling_foreign_link() {
  begin_scenario "10b. a DANGLING foreign link is not consent either" || return 0
  local h log

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
}

scenario_moved_checkout() {
  begin_scenario "10c. a MOVED clone still heals itself" || return 0
  local h log

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
}

scenario_moved_checkout_root() {
  begin_scenario "10d. …but only under the root ~/.zshenv itself names" || return 0
  local h log

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
  begin_scenario "11. configure_git keeps an excludesFile and an include.path you already had" || return 0
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
scenario_managed_tmux() {
  begin_scenario "12a. a ~/.tmux.conf owned by a dotfile manager is left alone" || return 0
  local h log sum

  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  seed_manager "$h"
  ln -s "$h/dotfiles/tmux.conf" "$h/.tmux.conf"
  sum="$(cksum <"$h/dotfiles/tmux.conf")"
  if assert_install_ok "$h" "$log"; then
    assert_eq "the ~/.tmux.conf link is still the manager's" "$h/dotfiles/tmux.conf" "$(readlink "$h/.tmux.conf")"
    assert_eq "the file it points at is byte-identical" "$sum" "$(cksum <"$h/dotfiles/tmux.conf")"
  fi
  end_scenario
}

scenario_managed_gitconfig() {
  begin_scenario "12b. a ~/.gitconfig owned by a dotfile manager is left alone and named" || return 0
  local h log sum

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
}

scenario_managed_xdg_gitconfig() {
  begin_scenario "12c. …and the same when git's global file is ~/.config/git/config" || return 0
  local h log sum

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
}

scenario_managed_claude_settings() {
  begin_scenario "12d. …but a managed ~/.claude/settings.json IS displaced, and the run says so" || return 0
  local h log sum

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
scenario_retired_sources() {
  begin_scenario "13a. links whose source the repo no longer has are retired, whatever named them" || return 0
  local h log bk

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
}

scenario_retired_bin_copy() {
  begin_scenario "13b. a copy in ~/bin, which shadows ~/.local/bin on PATH, is retired" || return 0
  local h log bk

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
scenario_missing_git_identity() {
  begin_scenario "14a. no git identity anywhere: refused before anything moves" || return 0
  local h log

  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  rm -f "$h/.gitconfig.local"          # new_home's only fixture: the identity that require_git_identity reads
  assert_install_fails "$h" "$log" 1 "set user.name/user.email in ~/.gitconfig.local"
  assert_absent "$h" .zshenv
  end_scenario
}

scenario_missing_jq() {
  begin_scenario "14b. no jq on PATH: refused before anything moves" || return 0
  local h log

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
scenario_custom_theme() {
  begin_scenario "15a. the theme follows ZSH_CUSTOM, because that is where oh-my-zsh looks" || return 0
  local h log zc pl relative
  for relative in .config/omz-custom 'custom|zsh'; do
    h="$(new_home)"
    guard_scratch_home "$h"
    log="$h.log"
    seed_oh_my_zsh "$h"
    zc="$h/$relative"
    mkdir -p "$zc/themes"
    for pl in zsh-autosuggestions zsh-syntax-highlighting; do
      mkdir -p "$zc/plugins/$pl"
    done
    RUN_EXTRA_ENV=(ZSH_CUSTOM="$zc")
    if assert_install_ok "$h" "$log" --with-zshrc; then
      assert_link "$h" .zshrc home/.zshrc
      assert_link "$h" "$relative/themes/workgrove.zsh-theme" "$THEME_SRC"
      assert_absent "$h" "$THEME_DST"
    fi
  done
  end_scenario
}

scenario_external_zsh_custom() {
  begin_scenario "15b. a ZSH_CUSTOM outside \$HOME is refused rather than half-installed" || return 0
  local h log zc pl

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
scenario_linux_install() {
  begin_scenario "16a. FORCE_OS=Linux: the VM-only steps run" || return 0
  local h log sum
  # shellcheck disable=SC2016  # The installed shell expands HOME.
  local line='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

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
    assert_eq "VM Claude uses fullscreen without UI opt-in" fullscreen \
      "$(jq -r '.tui' "$h/.claude/settings.json")"
    assert_settings_key "$h" theme no
    assert_mouse_key "$h" no
    assert_eq "VM Claude reduces terminal motion without UI opt-in" true \
      "$(jq -r '.prefersReducedMotion' "$h/.claude/settings.json")"
    assert_eq "VM Codex disables animations in its only [tui] table without UI opt-in" "1 1" \
      "$(count_matches "$h/.codex/config.toml" '[tui]') $(count_matches "$h/.codex/config.toml" 'animations = false')"
  fi
  end_scenario
}

scenario_linux_hook_order() {
  begin_scenario "16b. FORCE_OS=Linux: a line an older run appended is moved to the top" || return 0
  local h log sum
  # shellcheck disable=SC2016  # The installed shell expands HOME.
  local line='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

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
}

scenario_linux_hooked_writable() {
  begin_scenario "16c. FORCE_OS=Linux: a 664 ~/.bashrc that is already hooked is not refused" || return 0
  local h log sum
  # shellcheck disable=SC2016  # The installed shell expands HOME.
  local line='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

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
}

scenario_linux_unhooked_writable() {
  begin_scenario "16d. FORCE_OS=Linux: a 664 ~/.bashrc it WOULD rewrite is still refused" || return 0
  local h log sum
  # shellcheck disable=SC2016  # The installed shell expands HOME.
  local line='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

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
}

scenario_linux_managed_bashrc() {
  begin_scenario "16e. FORCE_OS=Linux: a ~/.bashrc a dotfile manager owns is left alone and named" || return 0
  local h log sum
  # shellcheck disable=SC2016  # The installed shell expands HOME.
  local line='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

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


# The cmux configuration remains an opt-in link after removal of the TCP hook merge.
scenario_cmux_config() {
  [[ $OS == Darwin ]] || return 0
  local h log
  begin_scenario "17k. the cmux configuration opt-in persists across a bare rerun" || return 0
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log" "$CMUX_FLAG"; then
    if assert_install_ok "$h" "$log.2"; then
      assert_link "$h" "$CMUX_DST" "$CMUX_SRC"
      assert_eq "$CMUX_FLAG listed as skipped after a bare rerun" 0 "$(count_matches "$log.2" "$CMUX_FLAG")"
    fi
  fi
  end_scenario
}

# The Ghostty config arrives with cmux.json as three separate links, and brings a copy of SF Mono. The run
# stashes a regular config file, leaves a .bak file beside it, and never replaces a font file that is there.
# It retires a Ghostty link whose source is gone, and it leaves a folder that a dotfile manager links alone.
scenario_ghostty_config() {
  local h log f bk
  begin_scenario "17l. the Ghostty config links file by file, and SF Mono is copied only when missing" || return 0
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  RUN_EXTRA_ENV=(FORCE_OS=Linux)
  if assert_install_ok "$h" "$log" "$CMUX_FLAG"; then
    assert_absent "$h" .config/ghostty/config      # cmux and Ghostty's fonts are the Mac's only
    assert_absent "$h" Library/Fonts
  fi
  if [[ $OS != Darwin ]]; then
    end_scenario
    return 0
  fi
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_absent "$h" .config/ghostty/config      # no flag: no Ghostty config and no fonts
    assert_absent "$h" Library/Fonts
  fi
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config/ghostty" "$h/Library/Fonts"
  printf '# STRANGER GHOSTTY\n' >"$h/.config/ghostty/config"
  printf '# OLD GHOSTTY\n' >"$h/.config/ghostty/config.20260101-000000.bak"
  printf 'the user font\n' >"$h/Library/Fonts/${SF_MONO_FONTS[0]}"
  mkdir -p "$h/.config/ghostty/themes"
  ln -s "$REPO/home/.config/ghostty/themes/retired-theme" "$h/.config/ghostty/themes/retired-theme"
  if assert_install_ok "$h" "$log" "$CMUX_FLAG"; then
    for f in "${GHOSTTY_FILES[@]}"; do
      assert_link "$h" ".config/ghostty/$f" "home/.config/ghostty/$f"
    done
    assert_not_link "$h" .config/ghostty
    assert_not_link "$h" .config/ghostty/themes
    assert_regular "$h" .config/ghostty/config.20260101-000000.bak
    bk="$(backup_dir "$h")"
    assert_grep "the stranger's Ghostty config is in the backup dir" "$bk/.config/ghostty/config" "# STRANGER GHOSTTY"
    assert_grep "the user's font file is kept" "$h/Library/Fonts/${SF_MONO_FONTS[0]}" 'the user font'
    # shellcheck disable=SC2088   # the ~ is the label a failure prints, not a path to expand
    assert_same_bytes "~/Library/Fonts/${SF_MONO_FONTS[1]} is the SF Mono file" \
      "$h/Library/Fonts/${SF_MONO_FONTS[1]}" "$SF_MONO_FIXTURE/${SF_MONO_FONTS[1]}"
    assert_absent "$h" Library/Fonts/SFMono-Terminal.ttf
    assert_grep "install.sh counted the copied font" "$log" 'copied SF Mono into ~/Library/Fonts (1 files)'
    assert_absent "$h" .config/ghostty/themes/retired-theme
    if assert_install_ok "$h" "$log.2"; then
      for f in "${GHOSTTY_FILES[@]}"; do
        assert_link "$h" ".config/ghostty/$f" "home/.config/ghostty/$f"
      done
      assert_eq "a bare rerun copies no font" 0 "$(count_matches "$log.2" 'SF Mono')"
    fi
  fi
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h.no-fonts"
  RUN_EXTRA_ENV=(SF_MONO_SRC="$h.no-fonts")
  if assert_install_ok "$h" "$log" "$CMUX_FLAG"; then
    assert_link "$h" .config/ghostty/config home/.config/ghostty/config
    assert_absent "$h" Library/Fonts
    assert_grep "the summary names the missing font" "$log" 'SF Mono was not found in'
  fi
  h="$(new_home)"
  guard_scratch_home "$h"
  log="$h.log"
  mkdir -p "$h/.config" "$h/dotfiles/ghostty"
  printf '# MANAGED GHOSTTY\n' >"$h/dotfiles/ghostty/config"
  ln -s "$h/dotfiles/ghostty" "$h/.config/ghostty"
  if assert_install_ok "$h" "$log" "$CMUX_FLAG"; then
    assert_link "$h" "$CMUX_DST" "$CMUX_SRC"
    assert_eq "the ~/.config/ghostty link is still the manager's" \
      "$h/dotfiles/ghostty" "$(readlink "$h/.config/ghostty")"
    assert_regular "$h" dotfiles/ghostty/config
    assert_grep "the managed Ghostty config is unchanged" "$h/dotfiles/ghostty/config" "# MANAGED GHOSTTY"
    assert_absent "$h" dotfiles/ghostty/themes
    # shellcheck disable=SC2088   # the ~ is the text the summary prints, not a path to expand
    assert_grep "the summary names the managed folder" "$log" '~/.config/ghostty is managed by a symlink'
  fi
  end_scenario
}

# On a Mac, ~/.zshenv points cmux's agent wrappers at the agent CLIs in ~/.local/bin. The stub uname tests
# both platforms on either runner. One home has only codex, so CMUX_CUSTOM_CLAUDE_PATH must stay unset there.
# The other has both agent CLIs, so each variable is checked set and unset.
scenario_zshenv_cmux_paths() {
  begin_scenario "18. ~/.zshenv sets the cmux agent paths only on a Mac, and keeps a preset value" || return 0
  local one both cli shell
  one="$(new_home)"
  both="$(new_home)"
  mkdir -p "$one/.local/bin" "$both/.local/bin"
  for cli in "$one/.local/bin/codex" "$both/.local/bin/codex" "$both/.local/bin/claude"; do
    printf '#!/bin/sh\n' >"$cli"
    chmod +x "$cli"
  done
  for shell in sh bash; do
    assert_eq "$shell on a Mac sets only the installed CLI" "$one/.local/bin/codex unset" \
      "$(zshenv_paths "$shell" "$one" Darwin)"
    assert_eq "$shell on a Mac sets both installed CLIs" "$both/.local/bin/codex $both/.local/bin/claude" \
      "$(zshenv_paths "$shell" "$both" Darwin)"
    assert_eq "$shell on a Mac keeps a preset value" "/preset $both/.local/bin/claude" \
      "$(zshenv_paths "$shell" "$both" Darwin CMUX_CUSTOM_CODEX_PATH=/preset)"
    assert_eq "$shell on Linux sets neither variable" "unset unset" "$(zshenv_paths "$shell" "$both" Linux)"
  done
  end_scenario
}

scenario_failed_symlink_refresh() {
  begin_scenario "failed hook refreshes do not report replacing untouched symlinks" || return 0
  local h log relative target
  for relative in .claude/settings.json .codex/hooks.json; do
    h=$(new_home)
    log="$h.log"
    target="$h/managed.json"
    mkdir -p "$h/$(dirname "$relative")"
    printf '%s\n' 'invalid hook JSON' > "$target"
    cp "$target" "$h/original.json"
    ln -s "$target" "$h/$relative"
    assert_install_fails "$h" "$log" 1 "jq failed on $relative" --refresh-config
    assert_eq "the failed refresh keeps the symlink" "$target" "$(readlink "$h/$relative")"
    assert_same_bytes "the failed refresh keeps its target" "$h/original.json" "$target"
    assert_eq "the failed refresh reports no replacement" 0 "$(count_matches "$log" "replaced the symlink at ~/$relative")"
    assert_eq "the failed refresh reports no installation" 0 "$(count_matches "$log" "installed ~/$relative")"
  done
  end_scenario
}

scenario_json_merge_relative_paths() {
  begin_scenario "JSON merge creates and updates relative destinations" || return 0
  local h script relative rc
  script="$TEST_ROOT/merge-relative.sh"
  cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$1/lib/workgrove/install-files.sh"
cd "$2"
TMPFILES=()
trap 'if [[ ${#TMPFILES[@]} -gt 0 ]]; then rm -f "${TMPFILES[@]}"; fi' EXIT
stash() { mkdir -p "backup/$(dirname "$1")"; mv "$1" "backup/$1"; }
json_merge "$3" true '.created = true'
json_merge "$3" true '.updated = true'
SCRIPT
  for relative in config.json 'nested dir/config.json'; do
    h=$(new_home)
    rc=0
    "$INSTALL_BASH" "$script" "$REPO" "$h" "$relative" > "$h.log" 2>&1 || rc=$?
    assert_eq "$relative merges succeed" 0 "$rc"
    if [[ $rc -eq 0 ]]; then
      assert_regular "$h" "$relative"
      assert_eq "$relative retains both merged fields" '{"created":true,"updated":true}' "$(jq -cS . "$h/$relative")"
      assert_eq "$relative backs up its previous contents" '{"created":true}' "$(jq -cS . "$h/backup/$relative")"
    fi
  done
  end_scenario
}

scenario_json_merge_failures() {
  begin_scenario "JSON merge failures preserve the destination without backups" || return 0
  local h script kind rc
  h=$(new_home)
  script="$TEST_ROOT/merge-failure.sh"
  cat > "$script" <<'SCRIPT'
set -euo pipefail
source "$1/lib/workgrove/install-files.sh"
HOME=$2
BK="$HOME/backup"
TMPFILES=()
trap 'if [[ ${#TMPFILES[@]} -gt 0 ]]; then rm -f "${TMPFILES[@]}"; fi' EXIT
stash() { mkdir -p "$BK"; mv "$1" "$BK/original.json"; }
json_merge "$HOME/config.json" "$3" "$4"
SCRIPT
  for kind in validation merge; do
    printf '%s\n' '{"user":"preserved"}' > "$h/config.json"
    cp "$h/config.json" "$h/original.json"
    rc=0
    if [[ $kind == validation ]]; then
      "$INSTALL_BASH" "$script" "$REPO" "$h" false '.changed = true' > "$h.log" 2>&1 || rc=$?
      assert_eq "validation failure returns 2" 2 "$rc"
    else
      "$INSTALL_BASH" "$script" "$REPO" "$h" true 'error("merge fixture")' > "$h.log" 2>&1 || rc=$?
      assert_eq "merge failure returns 1" 1 "$rc"
    fi
    assert_same_bytes "$kind failure preserves the destination" "$h/original.json" "$h/config.json"
    assert_absent "$h" backup
    assert_eq "$kind failure leaves no temporary files" 0 "$(find "$h" -name 'config.json.*' | wc -l | tr -d ' ')"
  done
  end_scenario
}

scenario_install_tables() {
  begin_scenario "new links and opt-in flags need one table row" || return 0
  local fixture="$TEST_ROOT/table-repo" h log
  mkdir -p "$fixture"
  cp -R "$REPO/install.sh" "$REPO/lib" "$REPO/home" "$REPO/bin" "$fixture/"
  printf 'linked fixture\n' > "$fixture/home/.table-link"
  printf 'optional fixture\n' > "$fixture/home/.table-source"
  printf 'binary fixture\n' > "$fixture/bin/table-bin"
  awk '
    { print }
    /^OPTIN=\(/ { print "  \047--with-table|WITH_TABLE|home/.table-source|.table-optin|all|link|7\047" }
    /^LINKS=\(/ { print "  \047home/.table-link|.table-link|\047" }
  ' "$fixture/install.sh" > "$fixture/install.new"
  mv "$fixture/install.new" "$fixture/install.sh"
  local REPO
  REPO=$(cd "$fixture" && pwd -P)
  h=$(new_home)
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_link "$h" .table-link home/.table-link
    assert_link "$h" .local/bin/table-bin bin/table-bin
    assert_absent "$h" .table-optin
    assert_grep "the new flag appears in skipped config" "$log" --with-table
    assert_install_fails "$h" "$log.usage" 2 '[--with-table]' --unknown
    if assert_install_ok "$h" "$log.selected" --with-table; then
      assert_link "$h" .table-optin home/.table-source
    fi
    if assert_install_ok "$h" "$log.sticky"; then
      assert_link "$h" .table-optin home/.table-source
    fi
    h=$(new_home)
    seed_oh_my_zsh "$h"
    if assert_install_ok "$h" "$log.all" --opinionated-config; then
      assert_link "$h" .table-optin home/.table-source
    fi
    mv "$fixture" "$fixture-moved"
    REPO=$(cd "$fixture-moved" && pwd -P)
    if assert_install_ok "$h" "$log.moved"; then
      assert_link "$h" .table-optin home/.table-source
      assert_eq "the moved checkout retains the new opt-in" 0 "$(count_matches "$log.moved" --with-table)"
    fi
  fi
  end_scenario
}

scenario_automation_summaries() {
  begin_scenario "complete installs summarize automation updates and skips" || return 0
  local kind h log config summary original backup
  for kind in new invalid changed disabled managed unknown; do
    h="$(new_home)"
    config="$h/.cmuxterm/automations.json"
    log="$h.log"
    summary="$h.summary"
    original="$h.original"
    mkdir -p "${config%/*}"
    case $kind in
      new) ;;
      invalid) printf '%s\n' '{"version":1,"rules":{}}' > "$config" ;;
      changed|disabled)
        jq --arg kind "$kind" '
          .rules[0].then[0].command = "old-hook" |
          if $kind == "disabled" then .rules[0].enabled = false else . end' \
          "$REPO/home/.cmuxterm/automations.json" > "$config" ;;
      managed)
        cp "$REPO/home/.cmuxterm/automations.json" "$h/managed.json"
        ln -s "$h/managed.json" "$config" ;;
      unknown) printf '%s\n' '{"version":99,"rules":[]}' > "$config" ;;
    esac
    if [[ -e $config ]]; then cp "$config" "$original"; fi
    RUN_EXTRA_ENV=(FORCE_OS=Darwin)
    if assert_install_ok "$h" "$log"; then
      assert_eq "$kind prints one final summary" 1 "$(count_matches "$log" 'Install summary:')"
      sed -n '/^Install summary:/,$p' "$log" > "$summary"
      assert_eq "$kind finishes before its summary" 0 "$(count_matches "$summary" 'done.')"
      case $kind in
        new)
          assert_eq "a new install gets the complete automation rule" "$(jq -cS . "$REPO/home/.cmuxterm/automations.json")" "$(jq -cS . "$config")"
          assert_mode "$h" .cmuxterm/automations.json 600
          RUN_EXTRA_ENV=(FORCE_OS=Darwin)
          assert_install_ok "$h" "$log.2"
          assert_grep "a rerun keeps the existing rule" "$log.2" "kept ~/.cmuxterm/automations.json's existing wt-native-relay rule"
          assert_eq "a rerun preserves the automation rule" "$(jq -cS . "$REPO/home/.cmuxterm/automations.json")" "$(jq -cS . "$config")" ;;
        invalid)
          assert_grep "invalid automation has a shape warning" "$log" 'expected a version-1 object with a rules array'
          assert_same_bytes "invalid automation stays unchanged" "$original" "$config" ;;
        changed|disabled)
          assert_grep "$kind summary retains the reload command" "$summary" 'Run: cmux automation reload'
          assert_eq "$kind summary prints reload once" 1 "$(count_matches "$summary" 'cmux automation reload')"
          # shellcheck disable=SC2088  # The rule stores the literal home-relative command.
          assert_eq "$kind installs the current command" '~/.local/bin/cmux-hook --event' "$(jq -r '.rules[0].then[0].command' "$config")"
          for backup in "$h"/.workgrove-backup/*/.cmuxterm/automations.json; do
            assert_same_bytes "$kind backs up the previous rule" "$original" "$backup"
          done
          if [[ $kind == disabled ]]; then
            assert_eq "the updated rule remains disabled" false "$(jq -r '.rules[0].enabled' "$config")"
          fi ;;
        managed)
          # shellcheck disable=SC2088  # The summary prints a home-relative path.
          assert_grep "managed summary names the skipped file" "$summary" '~/.cmuxterm/automations.json is managed externally'
          assert_grep "managed summary retains the manual action" "$summary" "Merge home/.cmuxterm/automations.json's wt-native-relay rule into the managed file."
          assert_eq "the managed symlink stays intact" "$h/managed.json" "$(readlink "$config")"
          assert_same_bytes "the managed file stays unchanged" "$original" "$config" ;;
        unknown)
          # shellcheck disable=SC2088  # The summary prints a home-relative path.
          assert_grep "unknown version summary names the skip" "$summary" '~/.cmuxterm/automations.json has unknown automations.json version 99'
          assert_same_bytes "the unknown version stays unchanged" "$original" "$config" ;;
      esac
    fi
  done
  end_scenario
}

scenario_optional_summary_commands() {
  begin_scenario "optional summary commands apply every selected setting" || return 0
  local h log command commands index=0 i
  local args=()
  h="$(new_home)"
  seed_oh_my_zsh "$h"
  log="$h.log"
  commands="$h.commands"
  if assert_install_ok "$h" "$log"; then
    sed -n '/^Install summary:/,$p' "$log" | sed -n 's/^    Run: \(install.sh.*\)$/\1/p' > "$commands"
    while IFS= read -r command; do
      read -r -a args <<<"$command"
      index=$((index + 1))
      if assert_install_ok "$h" "$log.action.$index" "${args[@]:1}"; then :; fi
    done < "$commands"
    assert_eq "the summary gives separate file and settings actions" 2 "$index"
    for i in 0 1 2 3 4; do assert_link "$h" "${FIVE_DST[$i]}" "${FIVE_SRC[$i]}"; done
    assert_link "$h" "$THEME_DST" "$THEME_SRC"
    if [[ $OS == Darwin ]]; then assert_link "$h" "$CMUX_DST" "$CMUX_SRC"; fi
    assert_status_line "$h" yes
    assert_claude_ui "$h" yes
    command=$(head -1 "$commands")
    if [[ $command == *--refresh-config* ]]; then fail 'unrelated file opt-ins require a refresh'; else pass; fi
  fi
  end_scenario
}

scenario_cleanup_summary() {
  begin_scenario "cleanup failures retain their status and the final summary" || return 0
  local h log stub real_rm
  h="$(new_home)"
  log="$h.log"
  stub="$h/stub"
  real_rm=$(command -v rm)
  mkdir -p "$stub"
  cat > "$stub/rm" <<'RM'
#!/usr/bin/env bash
for file in "$@"; do
  if [[ $file == "$HOME/.claude/settings.json."* ]]; then
    echo 'injected cleanup failure' >&2
    exit 23
  fi
done
exec "$INSTALL_REAL_RM" "$@"
RM
  chmod +x "$stub/rm"
  RUN_EXTRA_ENV=("PATH=$stub:$PATH" "INSTALL_REAL_RM=$real_rm")
  assert_install_fails "$h" "$log" 23 'injected cleanup failure'
  assert_eq "cleanup failure still prints one summary" 1 "$(count_matches "$log" 'Install summary:')"
  assert_grep "cleanup failure reports the final status" "$log" 'install.sh stopped part-way (exit 23)'
  assert_grep "cleanup failure keeps the follow-up actions" "$log" '  Follow-up actions:'
  end_scenario
}

scenario_install_summary() {
  begin_scenario "install summaries cover successful runs and early refusals" || return 0
  local h log summary
  h="$(new_home)"
  log="$h.log"
  if assert_install_ok "$h" "$log"; then
    assert_eq "one summary is printed" 1 "$(count_matches "$log" 'Install summary:')"
    summary="$h.summary"
    sed -n '/^Install summary:/,$p' "$log" > "$summary"
    assert_grep "the summary names optional skips" "$summary" 'Optional config was not selected:'
    assert_grep "the summary names follow-up actions" "$summary" '  Follow-up actions:'
    assert_grep "the summary gives the install command" "$summary" 'Run: install.sh'
    if [[ $OS != Darwin ]]; then
      assert_grep "the summary includes the repository directory action" "$summary" 'If repositories live elsewhere, edit WT_REPOS_DIR in ~/.zshenv.local.'
    fi
  fi
  assert_install_fails "$h" "$log.2" 2 'usage: install.sh' --unknown
  assert_eq "an early refusal prints one summary" 1 "$(count_matches "$log.2" 'Install summary:')"
  assert_eq "empty groups print none at the end" "$(printf 'Install summary:\n  Skips:\n    none\n  Follow-up actions:\n    none')" "$(tail -5 "$log.2")"
  rm "$h/.gitconfig.local"
  assert_install_fails "$h" "$log.3" 1 'set user.name/user.email'
  assert_eq "the identity refusal prints one summary" 1 "$(count_matches "$log.3" 'Install summary:')"
  assert_eq "the final action names the missing identity" '    Set user.name/user.email in ~/.gitconfig.local, then rerun install.sh.' "$(tail -1 "$log.3")"
  end_scenario
}

# Refresh both platforms without touching the real home directory.
scenario_refresh_hook_documents() {
  begin_scenario "hook refreshes accept empty files and read only the first existing document" || return 0
  local h log kind relative
  for kind in empty whitespace multiple; do
    h=$(new_home)
    log="$h.log"
    if assert_install_ok "$h" "$log" --with-claude-ui; then
      for relative in .claude/settings.json .codex/hooks.json; do
        cp "$h/$relative" "$h/$relative.expected"
        case $kind in
          empty) : > "$h/$relative" ;;
          whitespace) printf ' \n\t\n' > "$h/$relative" ;;
          multiple)
            printf '%s\n' \
              '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"first-hook"}]}]}}' \
              '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"second-hook"}]}]}}' > "$h/$relative"
            jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"first-hook"}]}]' \
              "$h/$relative.expected" > "$h/expected.json"
            mv "$h/expected.json" "$h/$relative.expected" ;;
        esac
      done
      if assert_install_ok "$h" "$log.refresh" --refresh-config --with-claude-ui; then
        for relative in .claude/settings.json .codex/hooks.json; do
          assert_eq "$kind refresh writes one document to $relative" 1 "$(jq -s length "$h/$relative")"
          assert_eq "$kind refresh preserves the original merge behavior for $relative" \
            "$(jq -cS . "$h/$relative.expected")" "$(jq -cS . "$h/$relative")"
        done
      fi
    fi
  done
  end_scenario
}

scenario_refresh_foreign_hooks() {
  begin_scenario "refresh keeps foreign hooks and prints platform follow-ups" || return 0
  local platform h log rel base command summary before
  for platform in Darwin Linux; do
    h="$(new_home)"
    guard_scratch_home "$h"
    log="$h.log"
    mkdir -p "$h/.claude" "$h/.codex"
    for rel in .claude/settings .codex/hooks; do
      base="$REPO/home/$rel.base.json"
      jq '
        .localSetting = true
        | .hooks.Stop += [
            {matcher: "foreign-only", hooks: [{type: "command", command: "foreign-helper", timeout: 7}]},
            {matcher: "mixed", hooks: [.hooks.Stop[0].hooks[0], {type: "command", command: "mixed-helper"}]},
            {matcher: "different-base-matcher", hooks: [.hooks.Stop[0].hooks[0]]}]
        | .hooks.ForeignEvent = [{matcher: "new-event", hooks: [{type: "command", command: "event-helper"}]}]
        | .hooks.PreToolUse = [{matcher: "foreign-tool", timeout: 42, hooks: [
            .hooks.PreToolUse[0].hooks[0], {type: "command", command: "foreign-policy"}]}]
      ' "$base" >"$h/$rel.json"
      cp "$h/$rel.json" "$h/${rel##*/}.before"
    done
    RUN_EXTRA_ENV=("FORCE_OS=$platform")
    if assert_install_ok "$h" "$log" --refresh-config; then
      for rel in .claude/settings .codex/hooks; do
        base="$REPO/home/$rel.base.json"
        if jq -e --slurpfile base "$base" '
          .hooks.Stop == ($base[0].hooks.Stop + [
            {matcher: "foreign-only", hooks: [{type: "command", command: "foreign-helper", timeout: 7}]},
            {matcher: "mixed", hooks: [{type: "command", command: "mixed-helper"}]}])
          and .hooks.ForeignEvent == [{matcher: "new-event", hooks: [{type: "command", command: "event-helper"}]}]
          and .hooks.PreToolUse == ($base[0].hooks.PreToolUse + [
            {matcher: "foreign-tool", timeout: 42, hooks: [{type: "command", command: "foreign-policy"}]}])
          and (has("localSetting") | not)
        ' "$h/$rel.json" >/dev/null; then pass; else fail "$platform: refreshed $rel hooks differ"; fi
        before="$(backup_dir "$h")/$rel.json"
        assert_unchanged "$platform: backup retains the original $rel" "$h/${rel##*/}.before" "$before"
      done
      if [[ $platform == Darwin ]]; then
        command='cmux hooks codex install --yes'
      else
        command='cmux-tui agent hook status claude codex'
      fi
      summary="$h.summary"
      sed -n '/^Install summary:/,$p' "$log" >"$summary"
      assert_eq "$platform: follow-up appears once in summary" 1 "$(count_matches "$summary" "    Run: $command")"
      assert_eq "$platform: follow-up appears only in summary" 1 "$(count_matches "$log" "$command")"
      RUN_EXTRA_ENV=("FORCE_OS=$platform")
      if assert_install_ok "$h" "$log.2" --refresh-config; then
        for rel in .claude/settings .codex/hooks; do
          assert_eq "$platform: a second refresh keeps one foreign group" 1 "$(jq '[.hooks.Stop[] | select(.matcher == "foreign-only")] | length' "$h/$rel.json")"
        done
      fi
    fi
  done
  end_scenario
}

# Refreshes repair old commands and files that already contain both command forms.
scenario_refresh_hook_upgrade() {
  begin_scenario "refresh replaces retired notify commands and repairs duplicate groups" || return 0
  local platform kind h log rel base attempt old
  for platform in Darwin Linux; do
    for kind in old duplicated; do
      h="$(new_home)"
      guard_scratch_home "$h"
      log="$h.log"
      mkdir -p "$h/.claude" "$h/.codex"
      for rel in .claude/settings .codex/hooks; do
        if [[ $rel == .claude/settings ]]; then
          old="AGENT_NOTIFY_SOURCE='Claude Code' agent-notify"
        else
          old='AGENT_NOTIFY_SOURCE=Codex agent-notify'
        fi
        jq --arg old "$old" --arg kind "$kind" '
          .hooks |= with_entries(.value |= (
            if $kind == "duplicated" then . + map(.hooks |= map(
              if .command | endswith(" ~/.local/bin/agent-notify") then .command = $old else . end))
            else map(.hooks |= map(
              if .command | endswith(" ~/.local/bin/agent-notify") then .command = $old else . end)) end))
          | .hooks.Stop += [{matcher: "mixed", timeout: 42, hooks: [
              {type: "command", command: $old},
              {type: "command", command: "foreign-helper", timeout: 7},
              {type: "command", command: "AGENT_NOTIFY_SOURCE=Personal agent-notify"},
              {type: "command", command: ($old + " --custom")},
              {type: "command", command: ("echo " + $old)}]}]
        ' "$REPO/home/$rel.base.json" >"$h/$rel.json"
      done
      for attempt in 1 2; do
        RUN_EXTRA_ENV=("FORCE_OS=$platform")
        if assert_install_ok "$h" "$log.$attempt" --refresh-config; then
          for rel in .claude/settings .codex/hooks; do
            base="$REPO/home/$rel.base.json"
            if [[ $rel == .claude/settings ]]; then
              old="AGENT_NOTIFY_SOURCE='Claude Code' agent-notify"
            else
              old='AGENT_NOTIFY_SOURCE=Codex agent-notify'
            fi
            if jq -e --slurpfile base "$base" --arg old "$old" '
              .hooks == ($base[0].hooks | .Stop += [{matcher: "mixed", timeout: 42, hooks: [
                {type: "command", command: "foreign-helper", timeout: 7},
                {type: "command", command: "AGENT_NOTIFY_SOURCE=Personal agent-notify"},
                {type: "command", command: ($old + " --custom")},
                {type: "command", command: ("echo " + $old)}]}])
            ' "$h/$rel.json" >/dev/null; then
              pass
            else
              fail "$platform: $rel $kind upgrade $attempt lost or duplicated hook groups"
            fi
          done
        fi
      done
    done
  done
  end_scenario
}

# ---------------------------------------------------------------------------- main

# shellcheck disable=SC2016   # $BASH_VERSION below is for the OTHER bash to expand, not this one
main() {
  echo "install.sh smoke test: repo $REPO, scratch root $TEST_ROOT"
  echo "  this suite under bash ${BASH_VERSION}; install.sh under $INSTALL_BASH" \
       "($("$INSTALL_BASH" -c 'echo "$BASH_VERSION"'))"
  scenario_refresh_foreign_hooks
  scenario_refresh_hook_documents
  scenario_refresh_hook_upgrade
  scenario_install_summary
  scenario_optional_summary_commands
  scenario_cleanup_summary
  scenario_automation_summaries
  scenario_install_tables
  scenario_json_merge_failures
  scenario_json_merge_relative_paths
  scenario_failed_symlink_refresh
  scenario_default_empty
  scenario_default_over_existing
  scenario_opinionated
  scenario_sticky_link
  scenario_regular_not_opted_in
  scenario_default_idempotent
  scenario_opinionated_idempotent
  scenario_individual_flags
  scenario_unknown_flag
  scenario_claude_ui_keys
  scenario_claude_ui_sticky
  scenario_dangling_gitconfig
  scenario_gitconfig_directory
  scenario_live_foreign_link
  scenario_dangling_foreign_link
  scenario_moved_checkout
  scenario_moved_checkout_root
  scenario_git_keeps_yours
  scenario_managed_tmux
  scenario_managed_gitconfig
  scenario_managed_xdg_gitconfig
  scenario_managed_claude_settings
  scenario_retired_sources
  scenario_retired_bin_copy
  scenario_missing_git_identity
  scenario_missing_jq
  scenario_custom_theme
  scenario_external_zsh_custom
  scenario_linux_install
  scenario_linux_hook_order
  scenario_linux_hooked_writable
  scenario_linux_unhooked_writable
  scenario_linux_managed_bashrc
  scenario_cmux_config
  scenario_ghostty_config
  scenario_zshenv_cmux_paths
  lib_summary
}

seed_other_checkout
main "$@"
