#!/usr/bin/env bash
#
# test/install-smoke.sh: run install.sh against throwaway HOMEs and assert what it did.
#   bash test/install-smoke.sh          (KEEP=1 leaves the scratch homes behind for inspection)
#
# Why this file exists: install.sh's five opinionated files (~/.zshrc, ~/.gitconfig, ~/.tmux.conf,
# ~/.claude/keybindings.json, ~/.claude/statusline-command.sh) are opt-in, as are the UI keys of
# ~/.claude/settings.json behind --with-claude-ui, and every machine the author owns is fully opted in — so
# the no-flags path, the one every stranger gets, is the one path the author
# never runs and the one most likely to rot. These scenarios exercise it, the flags, the stickiness rule
# and idempotence, and above all they check that a default install leaves a stranger's own dotfiles alone.
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
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"   # -P: install.sh records the physical path, so compare like for like
OS="$(uname -s)"
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

line_count() {
  local n
  n="$(wc -l <"$1")"
  echo "$((n))"
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
  printf '%s\n' '# STRANGER TMUX' 'set -g mouse on' >"$h/.tmux.conf"
  printf '%s\n' '{ "stranger": true }' >"$h/.claude/keybindings.json"
  printf '%s\n' '#!/bin/sh' 'echo STRANGER STATUSLINE' >"$h/.claude/statusline-command.sh"
}

# ---------------------------------------------------------------------------- running install.sh

# run_install <home> <logfile> [args…]: the only place install.sh is ever invoked.
# HOME is the scratch dir; XDG_CONFIG_HOME goes with it because `git config --global` prefers
# $XDG_CONFIG_HOME/git/config when that file exists, and an inherited XDG_CONFIG_HOME would point back at
# the real home. GIT_CONFIG_GLOBAL/SYSTEM/COUNT are unset for the same reason — any of them would override
# HOME for every `git config` install.sh runs. ZSH_CUSTOM is unset because install_zsh_plugins honours it
# and an inherited one would make the plugin check look outside the scratch HOME.
# stdin is /dev/null so ask_vm_host can never block on a read.
run_install() {
  local h="$1" log="$2" rc=0
  shift 2
  guard_scratch_home "$h"
  env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_COUNT -u ZSH_CUSTOM \
      HOME="$h" XDG_CONFIG_HOME="$h/.config" WT_HOST="$VM_HOST" \
      bash "$REPO/install.sh" "$@" >"$log" 2>&1 </dev/null || rc=$?
  return "$rc"
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
TMUX_LINE='set -ag update-environment'

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
  # The three machine-local copies: real files, never links, so the apps can write their state into them.
  assert_regular "$h" .claude/settings.json
  assert_regular "$h" .codex/config.toml
  assert_regular "$h" .codex/hooks.json
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
    # ~/.tmux.conf gains exactly one line and keeps the one it had.
    assert_regular "$h" .tmux.conf
    assert_grep "the ~/.tmux.conf keeps its own line" "$h/.tmux.conf" "set -g mouse on"
    assert_grep "the ~/.tmux.conf keeps its own comment" "$h/.tmux.conf" "# STRANGER TMUX"
    assert_eq "update-environment lines in ~/.tmux.conf" 1 "$(count_matches "$h/.tmux.conf" "$TMUX_LINE")"
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
  local h log i bk n
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
    for bk in "$h"/.workstation-backup/*/; do
      [[ -d "$bk" ]] || continue
      n=$((n + 1))
    done
    assert_eq "backup directories under ~/.workstation-backup" 1 "$n"
    for bk in "$h"/.workstation-backup/*/; do
      [[ -d "$bk" ]] || continue
      assert_grep "stashed .zshrc" "$bk/.zshrc" "# STRANGER ZSHRC"
      assert_grep "stashed .gitconfig" "$bk/.gitconfig" "stranger@example.invalid"
      assert_grep "stashed .tmux.conf" "$bk/.tmux.conf" "# STRANGER TMUX"
      assert_grep "stashed .claude/keybindings.json" "$bk/.claude/keybindings.json" '"stranger"'
      assert_grep "stashed .claude/statusline-command.sh" "$bk/.claude/statusline-command.sh" \
        "STRANGER STATUSLINE"
    done
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
      bash "$REPO/install.sh" --no-such-flag >"$out" 2>"$err" </dev/null || rc=$?
  assert_eq "exit status for an unknown flag" 2 "$rc"
  assert_grep "usage printed on stderr" "$err" "usage: install.sh"
  assert_eq "bytes written to stdout" 0 "$(wc -c <"$out" | tr -d ' ')"
  # parse_args runs before anything moves, so the HOME must be untouched.
  assert_absent "$h" .zshenv
  assert_absent "$h" .local/bin
  end_scenario
}

# 8. The sixth flag. It is unlike the other five twice over: it installs no file, and it cannot be sticky,
#    because the keys it keeps live inside a COPIED ~/.claude/settings.json and there is no symlink
#    destination for opted_in to read an earlier run's answer back out of. Both halves are asserted here —
#    the second one is the surprising half, and the one a future refactor is most likely to get wrong.
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

  begin_scenario "8b. --with-claude-ui is not sticky: the kept copy needs --refresh-config"
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
    # And a later refresh without the flag takes them away again — which is what "not sticky" means, and
    # the inverse of scenario 4a, where an existing link IS the record of an earlier flag.
    if assert_install_ok "$h" "$log.4" --refresh-config; then
      assert_claude_ui "$h" no
    fi
  fi
  end_scenario
}


# ---------------------------------------------------------------------------- main

main() {
  echo "install.sh smoke test: repo $REPO, scratch root $TEST_ROOT, bash ${BASH_VERSION}"
  scenario_default_empty
  scenario_default_over_existing
  scenario_opinionated
  scenario_sticky_optin
  scenario_idempotent
  scenario_individual_flags
  scenario_unknown_flag
  scenario_claude_ui
  echo "$((PASS + FAIL)) assertions: $PASS passed, $FAIL failed"
  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
