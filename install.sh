#!/usr/bin/env bash
#
# install.sh: install this repo into $HOME.
#   bash ~/repos/workgrove/install.sh [--refresh-config] [--opinionated-config]
#       [--with-zshrc] [--with-gitconfig] [--with-tmux-conf] [--with-keybindings] [--with-statusline]
#       [--with-claude-ui] [--with-cmux-config]
#   (on a VM, prefix WT_HOST=<vm>)
#
# The script is idempotent: rerun it whenever the repo changes. It never deletes anything. It moves anything
# in the way into ~/.workgrove-backup/<YYYYmmdd-HHMMSS>-<pid>, and creates that directory only when it needs
# it. So a run that changes nothing leaves no empty directory behind.
#
# The script handles three classes of file:
#   1. Stable files are SYMLINKED out of this repo. They are the shell, git and tmux dotfiles, the Claude and
#      Codex instructions, the skills, the bin/ scripts and cmux.json. So edits (an agent's edits too) land in
#      the repo, and `git diff` is the review. Six of these files are the author's taste, not machinery, so they
#      are OPT-IN (see below).
#   2. ~/.claude/settings.json, ~/.codex/config.toml and ~/.codex/hooks.json are machine-local COPIES of the
#      versioned .base files, because the apps write local state into them. A normal run keeps an existing
#      copy ("kept …"). Only --refresh-config stashes the copy and rewrites it. A refresh therefore drops
#      the state that Codex writes into config.toml (its hook trust hashes and folder trust). So trust the
#      hooks in /hooks after a refresh, not before.
#   3. The script never rewrites anything else:
#      - The hand-written overrides ~/.gitconfig.local, ~/.zshrc.local and ~/.zshenv.local. On a VM,
#        ~/.zshenv.local only gains a WT_HOST line and a WT_REPOS_DIR line, each only when it has none.
#      - The real directories that the apps write into.
#      On a VM, ~/.bashrc likewise only gains one line, which sources ~/.zshenv, and only when it has none.
#
# The opt-in cuts across the three classes. An install of this repo must not give a stranger the author's
# shell prompt, git config and tmux bindings. So the six class-1 files that are taste, not machinery, arrive
# only when the user asks for them:
#   ~/.zshrc                          --with-zshrc. With it come the oh-my-zsh theme, the oh-my-zsh
#                                     prerequisite and the plugin clone, which exist only to serve it.
#   ~/.gitconfig                      --with-gitconfig
#   ~/.tmux.conf                      --with-tmux-conf
#   ~/.claude/keybindings.json        --with-keybindings
#   ~/.claude/statusline-command.sh   --with-statusline
#   ~/.config/cmux/cmux.json          --with-cmux-config, on a Mac only
# A seventh flag, --with-claude-ui, gates KEYS, not a file. Every machine gets ~/.claude/settings.json, because
# its hooks and permissions are machinery. But .tui, .voice, .theme and the env var that turns off mouse clicks
# in the Claude Code TUI are taste, like the six files. So copy_config deletes them from the copy unless the
# flag is given. --opinionated-config turns on all seven.
#
# The user never has to repeat any of the seven flags. For the six files, the destination itself is the
# record: a destination that is already a link into this repo counts as asked for. So `wt update`, which
# reruns this script bare, keeps what an earlier run installed. --with-claude-ui has no symlink to read, but it
# has the same kind of record. Only a run that was given the flag can have written an existing
# ~/.claude/settings.json that still has a top-level .tui key. claude_ui_opted_in reads that key with the same
# jq probe that copy_config already makes for its kept-copy warning.
# This stickiness is necessary. The one documented way to pick up a change to a .base file is
# --refresh-config, and `wt update --refresh-config` cannot forward --with-claude-ui. So a non-sticky flag
# would make the prescribed update command silently strip the UI keys off every machine that has them.
#
# Exit status 2 is a usage error. Exit status 1 means one of these:
#   - A prerequisite is missing: jq, oh-my-zsh (only when ~/.zshrc is opted in), the VM name (Linux) or a git
#     identity.
#   - The script would write to something that it may not write to: a broken symlink or a non-regular file at
#     any of the paths that require_plain_file guards, or a group- or other-writable ~/.bashrc that it would
#     have to rewrite.
# The script makes every one of these refusals before the first file moves.
set -euo pipefail
umask 077

# -P, not a plain pwd: every link below records this path, and opted_in reads it back. `wt update` also
# reruns this script from "$(cd "$(dirname "$s")/.." && pwd -P)". Without -P here, a clone reached through a
# symlinked path component would record one spelling from a direct run and the other from `wt update`. Then
# every link made under the first spelling would read as "not ours" under the second.
R="$(cd "$(dirname "$0")" && pwd -P)"   # this repo
OS="${FORCE_OS:-$(uname -s)}"        # FORCE_OS exists only so that test/install-smoke.sh can drive the
                                     # Linux-only steps from a Mac: above all hook_bashrc, the most intricate
                                     # function here. Nothing else ever sets it.
# ZC: oh-my-zsh's own customization directory. It is the one place where BOTH things that ~/.zshrc needs from
# this script must land. When ZSH_CUSTOM is set, oh-my-zsh looks only under $ZSH_CUSTOM for the theme that
# ZSH_THEME names and for the plugins. install_zsh_plugins always honored ZSH_CUSTOM, but link_dotfiles used
# to hardcode ~/.oh-my-zsh/custom. So with ZSH_CUSTOM set, the plugins arrived and the theme did not. Every
# shell start then said "[oh-my-zsh] theme 'workgrove' not found", while every line of the install said success.
# link() spells its destination relative to $HOME, so it cannot express a $ZSH_CUSTOM outside $HOME at all.
# In that case require_oh_my_zsh refuses --with-zshrc, instead of installing half of it.
ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
ZC_REL=""                            # $ZC as a home-relative path; empty when $ZC is not under $HOME
if [[ $ZC == "$HOME"/* ]]; then
  ZC_REL="${ZC#"$HOME"/}"
fi
REFRESH=0                            # set by --refresh-config
WITH_ZSHRC=0                         # the six opinionated files, each set by its own --with-… flag
WITH_GITCONFIG=0
WITH_TMUX_CONF=0
WITH_KEYBINDINGS=0
WITH_STATUSLINE=0
WITH_CMUX_CONFIG=0                   # …the sixth of them, and the only one that exists on a Mac alone
WITH_CLAUDE_UI=0                     # the seventh: UI keys inside the copied ~/.claude/settings.json, not a file
BK=""                                # this run's backup dir; filled in by main
SUMMARY_SKIPS=()
SUMMARY_ACTIONS=()
REPORT_ACTIVE=0
TMPFILES=()                          # Half-built files are removed by report at exit.
ZSHENV_ROOT=""                       # the clone root that ~/.zshenv pointed at before this run; found by
                                     # read_zshenv_root, used by opted_in
GITRC=""                             # the file that `git config --global` writes, which need not be
                                     # ~/.gitconfig; set by resolve_git_global
GITRC_LABEL=""                       # …the same path, spelled for a message

# parse_args <script args…>: accept the flags in any order and any combination. Each --with-… flag adds one
# opinionated file (or, for --with-claude-ui, one group of keys). --opinionated-config is all seven at once.
# --refresh-config is independent of all of them.
# parse_args accepts --with-cmux-config on a VM too, where it has nothing to do, because cmux is a Mac app.
# If the flag were a usage error only on a VM, the user would have to remember not to run
# `wt update --with-cmux-config` there.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-zshrc)         WITH_ZSHRC=1 ;;
      --with-gitconfig)     WITH_GITCONFIG=1 ;;
      --with-tmux-conf)     WITH_TMUX_CONF=1 ;;
      --with-keybindings)   WITH_KEYBINDINGS=1 ;;
      --with-statusline)    WITH_STATUSLINE=1 ;;
      --with-cmux-config)   WITH_CMUX_CONFIG=1 ;;
      --with-claude-ui)     WITH_CLAUDE_UI=1 ;;
      --opinionated-config) WITH_ZSHRC=1; WITH_GITCONFIG=1; WITH_TMUX_CONF=1
                            WITH_KEYBINDINGS=1; WITH_STATUSLINE=1; WITH_CMUX_CONFIG=1
                            WITH_CLAUDE_UI=1 ;;
      --refresh-config)     REFRESH=1 ;;
      *)
        { echo "usage: install.sh [--refresh-config] [--opinionated-config]"
          echo "                  [--with-zshrc] [--with-gitconfig] [--with-tmux-conf]"
          echo "                  [--with-keybindings] [--with-statusline] [--with-claude-ui]"
          echo "                  [--with-cmux-config]"
        } >&2
        exit 2 ;;
    esac
    shift
  done
}

# our_link <absolute path> <repo-relative src>: is that symlink one that this script made for <src>? A link can
# be ours in three ways, in order of how much each way assumes:
#   1. It points into $R. Every link that this run makes carries that spelling.
#   2. It still RESOLVES into $R. Before this script resolved $R with pwd -P, a run recorded the clone's path
#      with a symlinked component in it. That link is live and correct; it only spells the repo differently.
#   3. It DANGLES, and its target ends in the same repo-relative path. A link made before the clone was moved
#      or renamed looks like this afterwards. Its old root is gone, but its tail is this repo's own layout. So
#      link() can stash it and re-point it, and the machine heals itself.
# The dangling requirement in case 3 keeps the tail test honest. The user may deliberately keep a LIVE link
# into a SECOND checkout, and this script must never touch that one link. The tail test alone would match it.
# So a link whose target still exists is ours only when it resolves into THIS repo, which that link never does.
# Case 3 is a statement about LAYOUT, not about consent. Only remove_retired_links may read it as consent,
# because there the worst cost is a stash. home/.zshrc, home/.gitconfig and home/.tmux.conf are not distinctive
# tails: chezmoi, yadm, dotbot, homeshick and a `home` stow package all produce them. So a machine whose dotfile
# links only happen to dangle must not read as "already opted in" to a run given no flags. For example,
# bootstrap ran before the dotfiles repo was cloned, or the repo is on an unmounted volume. opted_in therefore
# does not reuse case 3 as it stands; see the predicate there.
our_link() {
  local p="$1" t dir
  if [[ ! -L $p ]]; then
    return 1
  fi
  t="$(readlink "$p")"
  if [[ $t == "$R"/* ]]; then
    return 0
  fi
  if [[ -e $p ]]; then
    dir="$(cd "$(dirname "$p")" 2>/dev/null && cd "$(dirname "$t")" 2>/dev/null && pwd -P)" || dir=""
    if [[ -n $dir && "$dir/$(basename "$t")" == "$R"/* ]]; then
      return 0                         # the same repo, reached by another spelling of the path
    fi
    return 1                           # live and landing elsewhere: someone else's link, left alone
  fi
  [[ $t == */"$2" ]]
}

# read_zshenv_root: read the one fact that makes a DANGLING link readable as consent. main() must call this
# function exactly once, at its top, before link_dotfiles re-points ~/.zshenv at $R. After that, every
# still-dangling sibling stops matching. Every run of this script links ~/.zshenv unconditionally, and no
# dotfile manager installs one. So a dangling ~/.zshenv whose target ends in home/.zshenv names exactly the
# clone that THIS machine was installed from before the clone moved. A live ~/.zshenv adds no fact: our_link's
# cases 1 and 2 already settle every live sibling.
read_zshenv_root() {
  local p="$HOME/.zshenv" t
  ZSHENV_ROOT=""
  if [[ ! -L $p || -e $p ]]; then
    return 0
  fi
  t="$(readlink "$p")"
  if [[ $t == */home/.zshenv ]]; then
    ZSHENV_ROOT="${t%/home/.zshenv}"
  fi
}

# consenting_link <absolute path> <repo-relative src>: is that symlink the record of a --with-… flag from an
# earlier run? This test is stricter than our_link, because its answer is read as CONSENT, not as ownership.
# A wrong yes gives a stranger the author's shell prompt, git config and tmux bindings, and nothing in the
# output says so. That is exactly the harm that the opt-in above exists to prevent.
#   A live link: our_link decides, with its cases 1 and 2, which are about this repo and nothing else.
#   A dangling link: it is ours only when its old root is the old root of a link that this script CERTAINLY
#   made. read_zshenv_root got that root. This still heals a moved clone, because every link that the script
#   made moved together. And it no longer mistakes a foreign manager's momentarily dangling home/.zshrc for an
#   answer that this user gave.
consenting_link() {
  local p="$1" t
  if [[ ! -L $p ]]; then
    return 1
  fi
  t="$(readlink "$p")"
  if [[ $t == "$R"/* || -e $p ]]; then
    our_link "$p" "$2"
    return
  fi
  [[ -n $ZSHENV_ROOT && $t == "$ZSHENV_ROOT/$2" ]]
}

# opted_in <flag> <home-relative dst>: does this run install that opinionated file? Yes when the flag asked for
# it. Also yes when ~/dst is ALREADY a link that an earlier run of this script made. That link is the record
# that the earlier run's flag left. `wt update` reruns this script with no arguments, so a choice made once
# must survive a run that cannot see it. This script stores no state anywhere that could disagree with the link.
# On a machine where all six files are already linked (every machine the author has), every answer is yes.
# There, this whole opt-in changes nothing.
# Only the six FILES can be asked about here. --with-claude-ui gates keys inside a copied file, so its record
# is the keys themselves; claude_ui_opted_in reads that record.
opted_in() {
  if [[ $1 -eq 1 ]]; then
    return 0
  fi
  consenting_link "$HOME/$2" "home/$2"
}

# claude_ui_opted_in: the same question for the seventh flag. (--with-cmux-config is the sixth, and the last of
# the six that are FILES.) copy_config strips the top-level .tui key from every copy written without
# --with-claude-ui. So an existing ~/.claude/settings.json that is a real file and still has that key was
# written by a run that was given the flag. This read-back keeps `wt update --refresh-config`, which cannot
# forward the flag, from silently deleting the UI keys of a machine that has them. The probe is the same jq
# call that copy_config already makes eleven lines further down, so the two cannot drift.
claude_ui_opted_in() {
  local dst="$HOME/.claude/settings.json"
  if [[ $WITH_CLAUDE_UI -eq 1 ]]; then
    return 0
  fi
  if [[ ! -f $dst || -L $dst ]]; then
    return 1
  fi
  jq -e 'has("tui")' "$dst" >/dev/null 2>&1
}

# die <message>: stop with a message on stderr. The EXIT trap still reports where anything went.
die() {
  SUMMARY_ACTIONS+=("$*")
  echo "$*" >&2
  exit 1
}

# stash <path>: move an existing file, dir or symlink into the backup dir. It never deletes.
stash() {
  if [[ ! -e "$1" && ! -L "$1" ]]; then
    return 0
  fi
  local rel="${1#"$HOME"/}"
  mkdir -p "$BK/$(dirname "$rel")"   # made here, so the backup dir exists only when used
  mv "$1" "$BK/$rel"
}

# link <repo-relative src> <home-relative dst>: point ~/dst at <repo>/src, and stash what was there.
link() {
  local src="$R/$1" dst="$HOME/$2"
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    return 0                         # already correct: say nothing, change nothing
  fi
  mkdir -p "$(dirname "$dst")"
  stash "$dst"
  ln -s "$src" "$dst"
  echo "linked ~/$2"
}

# copy_config <repo-relative .base> <home-relative dst> <claude|codex|plain>: install one machine-local copy.
# It keeps an existing real file unless --refresh-config was given.
#   Kind "claude" drops the voice keys on a VM, because a VM has no local microphone. It drops the UI keys
#   unless --with-claude-ui (or the record of an earlier one) asked for them, because those keys are taste,
#   not machinery. VM copies also reduce terminal motion for tmux rows.
#   Kind "codex" drops the Keychain credential store on a VM, because only macOS has one. It also disables
#   Codex's terminal animations there.
# copy_config displaces a SYMLINK at $dst, and does so deliberately. This is the one place that does not leave
# a dotfile manager's link alone. hook_bashrc and configure_git leave such a link alone.
# The apps write their own state into exactly these three files, so each must be a real file at the path that
# the app opens. A link would send Claude's and Codex's writes into a synced repo, which then fights them.
# Nothing is lost: only the LINK moves into the backup dir, and the file it pointed at is untouched. The
# displacement gets its own line in the output; it is not folded into "installed ~/…". That is also why this
# step has no check_… twin in the refuse-before-writes pass: it has nothing to refuse.
# copy_config builds the new file in full before it stashes the old one, so a filter that fails cannot leave a
# truncated ~/dst behind. A replaced copy is only ever stashed, never merged. So a refreshed .codex/config.toml
# loses the tables that Codex wrote into it (hook trust, folder trust). The old file in the backup dir still
# holds them, and /hooks restores them.
copy_config() {
  local src="$R/$1" dst="$HOME/$2" kind="$3"
  if [[ -e "$dst" && ! -L "$dst" && $REFRESH -eq 0 ]]; then
    # shellcheck disable=SC2088  # The summary prints a home-relative path.
    SUMMARY_SKIPS+=("~/$2 already exists; the machine-local copy was kept")
    SUMMARY_ACTIONS+=("To replace ~/$2, run: install.sh --refresh-config")
    echo "kept ~/$2 (install.sh --refresh-config replaces it)"
    # A kept file also keeps the filter decision that the FIRST install made. So --with-statusline on a machine
    # that is already installed links the script, but leaves settings.json without the key that names it. The
    # status line then never appears, while every line of the run says success. Say so here instead.
    if [[ $kind == claude ]] && opted_in "$WITH_STATUSLINE" .claude/statusline-command.sh \
       && ! jq -e 'has("statusLine")' "$dst" >/dev/null 2>&1; then
      # shellcheck disable=SC2088  # The summary prints a home-relative path.
      SUMMARY_SKIPS+=("~/$2 has no statusLine key")
      SUMMARY_ACTIONS+=("Run: install.sh --refresh-config")
      echo "…but the kept ~/$2 has no statusLine key, so the status line will not appear:" >&2
      echo "rerun with --refresh-config to rewrite it (the old copy goes to the backup dir)" >&2
    fi
    # The same trap applies to the keys that --with-claude-ui asks for. The flag only ever reaches a file
    # that is being WRITTEN. So on an already-installed machine, the flag changes nothing, and every line of
    # the run says success.
    if [[ $kind == claude && $WITH_CLAUDE_UI -eq 1 ]] \
       && ! jq -e 'has("tui")' "$dst" >/dev/null 2>&1; then
      # shellcheck disable=SC2088  # The summary prints a home-relative path.
      SUMMARY_SKIPS+=("~/$2 has no tui key")
      SUMMARY_ACTIONS+=("Run: install.sh --refresh-config")
      echo "…but the kept ~/$2 has no tui key, so --with-claude-ui changed nothing:" >&2
      echo "rerun with --refresh-config to rewrite it (the old copy goes to the backup dir)" >&2
    fi
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  local tmp; tmp="$(mktemp "$dst.XXXXXX")"                # built first: a failure here leaves ~/$2 untouched
  TMPFILES+=("$tmp")                                      # and the EXIT trap removes it, signals included
  if [[ $kind == claude ]]; then
    local filter='.'
    if [[ $OS != Darwin ]]; then
      filter="$filter | del(.voice, .voiceEnabled) | .prefersReducedMotion = true"
    fi
    # UI taste, not machinery: the hooks and permissions around these keys stay on every machine. The env var
    # is in this list for the same reason as the three keys: it turns mouse clicks off in the Claude Code TUI.
    # If the list left the env var out, a stranger who never asked for the author's UI would find their mouse
    # dead. Nothing in the run's output would name the key.
    # This del() adds to the line above; it does not replace it. A del() is a no-op for a key that another
    # del() already removed, and for a nested path that is not there. So .voice goes on a VM either way, and
    # the two tests stay independent.
    if ! claude_ui_opted_in; then
      filter="$filter | del(.tui, .voice, .theme, .env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS)"
    fi
    if ! opted_in "$WITH_STATUSLINE" .claude/statusline-command.sh; then
      filter="$filter | del(.statusLine)"                 # the script it names is opt-in: a command pointing at a
    fi                                                    # file that was never installed breaks the status line
    # Today .env holds exactly that one key, so the del above can empty it. In that case, drop the object
    # instead of writing an `"env": {}` that no run ever meant to put there.
    filter="$filter | if (.env | length) == 0 then del(.env) else . end"
    jq "$filter" "$src" >"$tmp" || { rm -f "$tmp"; die "jq failed on $1"; }
  elif [[ $kind == codex && $OS != Darwin ]]; then
    grep -v '^cli_auth_credentials_store' "$src" >"$tmp" || { rm -f "$tmp"; die "failed to filter $1"; }
    # The base keeps animations on for the Mac; only a VM's tmux rows need a still spinner.
    printf '\n[tui]\nanimations = false\n' >>"$tmp"
  else
    cp "$src" "$tmp"
  fi
  chmod 600 "$tmp"
  if [[ -L "$dst" ]]; then                                # see the header: the link goes, its target stays
    echo "replaced the symlink at ~/$2 (-> $(readlink "$dst")) with a real file: the app writes its own state"
    echo "into this one, so it cannot be a link; the link itself is in the backup dir, its target untouched"
  fi
  stash "$dst"                                            # only now does anything move
  mv "$tmp" "$dst"
  echo "installed ~/$2"
}

# require_jq: copy_config filters the Claude settings on every platform, and jq must be present BEFORE
# anything moves.
require_jq() {
  if command -v jq >/dev/null 2>&1; then                  # every platform: copy_config filters the Claude
    return 0                                              # settings on both, and statusline-command.sh is
  fi                                                      # opt-in, so the statusLine key is dropped on a Mac too
  if [[ $OS == Darwin ]]; then
    die "jq not found: brew install jq (or brew bundle --file $R/Brewfile), then rerun"
  fi
  die "jq not found: sudo apt-get install -y jq, then rerun"
}

# require_oh_my_zsh: the linked ~/.zshrc needs oh-my-zsh. When that .zshrc is opted in, stop early and name
# the setup page. No other file that this script installs uses oh-my-zsh. So a refusal when ~/.zshrc is not
# opted in would invent a prerequisite for a file that the user is not getting.
require_oh_my_zsh() {
  if ! opted_in "$WITH_ZSHRC" .zshrc; then
    return 0
  fi
  if [[ -z $ZC_REL ]]; then            # see ZC above: link() can only spell a destination under $HOME. Before
                                       # this check, the script silently half-installed: plugins yes, theme no
    echo "ZSH_CUSTOM=$ZC is outside \$HOME, so the theme ~/.zshrc names cannot be linked into $ZC/themes" >&2
    die "unset ZSH_CUSTOM, or point it inside \$HOME, then rerun"
  fi
  if [[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
    return 0
  fi
  local page=vm
  [[ $OS == Darwin ]] && page=mac
  SUMMARY_ACTIONS+=("Install oh-my-zsh first (docs/new-$page.md), then rerun install.sh.")
  echo "install oh-my-zsh first (docs/new-$page.md)" >&2
  exit 1
}

# make_dirs: the directories that the apps write into stay real directories. Never link them.
make_dirs() {
  mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills" "$HOME/.codex" "$HOME/.agents/skills"
  if [[ $OS == Darwin ]]; then          # the Mac's task repos folder; on a VM they live in the home folder
    mkdir -p "$HOME/Documents/Repositories"
  fi
}

# install_bins: link the scripts into ~/.local/bin, and retire any copy in ~/bin (which is first on PATH).
install_bins() {
  local b
  for b in wt agent-notify cmux-hook azml-ssh-host github-guard; do
    if [[ -e "$HOME/bin/$b" || -L "$HOME/bin/$b" ]]; then
      stash "$HOME/bin/$b"
      echo "retired ~/bin/$b (it shadowed ~/.local/bin/$b); the old copy is in the backup dir"
    fi
    link "bin/$b" ".local/bin/$b"
  done
}

# link_dotfiles: link the stable shell, git, tmux, Claude and theme files. The first loop is machinery that
# every install needs:
#   ~/.zshenv carries PATH and the wt variables.
#   ~/.gitignore_global is the list that core.excludesFile points at. It is linked either way, because the git
#   fallback below points at it too.
#   The two instruction files are what the agents read.
# The rest is taste, so each file waits for its own opt-in. The theme waits for the ~/.zshrc opt-in, because
# that ~/.zshrc is the only thing that names it.
link_dotfiles() {
  local f
  for f in .zshenv .gitignore_global .claude/AGENTS.md .claude/CLAUDE.md; do
    link "home/$f" "$f"
  done
  if opted_in "$WITH_ZSHRC" .zshrc; then
    link home/.zshrc .zshrc
    link home/.oh-my-zsh/custom/themes/workgrove.zsh-theme "$ZC_REL/themes/workgrove.zsh-theme"
  fi
  if opted_in "$WITH_GITCONFIG" .gitconfig; then
    link home/.gitconfig .gitconfig
  fi
  if opted_in "$WITH_TMUX_CONF" .tmux.conf; then
    link home/.tmux.conf .tmux.conf
  fi
  if opted_in "$WITH_KEYBINDINGS" .claude/keybindings.json; then
    link home/.claude/keybindings.json .claude/keybindings.json
  fi
  if opted_in "$WITH_STATUSLINE" .claude/statusline-command.sh; then
    link home/.claude/statusline-command.sh .claude/statusline-command.sh
  fi
}

# install_configs: copy the three mutable files from their .base versions.
install_configs() {
  copy_config home/.claude/settings.base.json .claude/settings.json claude
  copy_config home/.codex/config.base.toml    .codex/config.toml    codex
  copy_config home/.codex/hooks.base.json     .codex/hooks.json     plain
}

# link_skills: link each skill twice, because Codex reads ~/.agents/skills and Claude reads only
# ~/.claude/skills. Codex takes the shared instructions from ~/.codex/AGENTS.md.
link_skills() {
  local d n
  for d in "$R"/home/.agents/skills/*/; do
    [[ -d "$d" ]] || continue          # nullglob is off. So in a fork with no skills, the body runs once with
                                       # the pattern itself and would link ~/.agents/skills/*. The next run
                                       # then retires that link, and so makes a backup dir on every run
    n="$(basename "$d")"
    link "home/.agents/skills/$n" ".agents/skills/$n"
    link "home/.agents/skills/$n" ".claude/skills/$n"
  done
  link home/.claude/AGENTS.md .codex/AGENTS.md
}

# link_cmux_config: cmux runs only on the Mac. Its UI settings stay a link, so changes show in `git diff`.
CMUX_DST=.config/cmux/cmux.json
link_cmux_config() {
  if [[ $OS != Darwin ]]; then
    return 0
  fi
  if opted_in "$WITH_CMUX_CONFIG" "$CMUX_DST"; then
    link "home/$CMUX_DST" "$CMUX_DST"
  fi
}

# retired_src <home-relative dst>: print the repo-relative path that the linking steps above point that
# destination at. our_link's tail test needs this path to recognize a link made before this clone moved.
# Five of the eight directories mirror the repo's own layout, so for them the source is home/<dst>. This
# function used to infer that source for all of them. So once the clone had moved, the three exceptions below
# could never be retired: their source is not their destination, so the tail never matched. A renamed skill or
# script then outlived its rename on exactly the machines that this function exists for.
# ~/.oh-my-zsh/custom/themes is a sixth exception whenever ZSH_CUSTOM moves the DESTINATION, because the source
# under home/ does not move with it.
retired_src() {
  local rel="$1"
  if [[ -n $ZC_REL && $rel == "$ZC_REL"/themes/* ]]; then
    echo "home/.oh-my-zsh/custom/themes/${rel#"$ZC_REL"/themes/}"
    return 0
  fi
  case "$rel" in
    .local/bin/*)     echo "bin/${rel#.local/bin/}" ;;                       # install_bins
    .claude/skills/*) echo "home/.agents/skills/${rel#.claude/skills/}" ;;   # link_skills, the Claude copy
    .codex/AGENTS.md) echo "home/.claude/AGENTS.md" ;;                       # link_skills, the shared file
    *)                echo "home/$rel" ;;
  esac
}

# remove_retired_links: link() knows only the names that the repo uses today. An earlier run may have made a
# link under a name that the repo later renamed away. Nothing revisits that link, so it dangles forever; a
# rerun only adds the new link beside it. That is how ~/.oh-my-zsh/custom/themes/max.zsh-theme outlived the
# theme's first rename, and left oh-my-zsh looking for a theme that was already gone. `wt update` reruns this
# script, so every later rename would litter every machine the same way. That includes the same theme's rename
# to workgrove.zsh-theme, which came with the project's own rename. This function retires the stale link on the
# next run, on every machine that already had the old one.
# An entry is ours to retire only when all three of these are true:
#   - It is a symlink.
#   - Its target no longer exists.
#   - It is ours by our_link: it points into this repo, or into the same source path under a root that this
#     clone has since moved away from. So a rename does not strand the retired names either.
# Anything else that dangles here belongs to the user, and this function leaves it strictly alone. It also
# leaves every live link alone. It looks only at depth 1, and only in the directories that the linking steps
# above write into: it never walks $HOME recursively.
remove_retired_links() {
  local d e rel dirs
  dirs=("$HOME" "$HOME/.claude" "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex" \
        "$HOME/.local/bin" "$HOME/.config/cmux")
  if [[ -n $ZC_REL ]]; then
    dirs[${#dirs[@]}]="$ZC/themes"                       # where link_dotfiles put the theme; with ZSH_CUSTOM
  fi                                                     # set, that is not ~/.oh-my-zsh/custom
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue                            # a directory this machine never got
    while IFS= read -r e; do
      [[ -e "$e" ]] && continue                          # live link: the repo still has the file
      rel="${e#"$HOME"/}"
      our_link "$e" "$(retired_src "$rel")" || continue  # points outside this repo: not ours to touch
      stash "$e"                                         # the backup contract holds here too: nothing is deleted
      echo "retired ~/$rel (the repo no longer has the file it pointed at)"
    done < <(find "$d" -maxdepth 1 -type l)              # -maxdepth 1: never descend into $HOME
  done
}

# install_zsh_plugins: clone the two plugins that ~/.zshrc enables, once. Only that .zshrc names them, so
# without it there is nothing to clone. This also means that a default install never touches the network.
install_zsh_plugins() {
  local p
  if ! opted_in "$WITH_ZSHRC" .zshrc; then
    return 0
  fi
  for p in zsh-autosuggestions zsh-syntax-highlighting; do
    if [[ ! -d "$ZC/plugins/$p" ]]; then                  # $ZC, the same directory the theme was linked under
      echo "cloning the $p plugin that ~/.zshrc enables (needs the network)"
      git clone -q --depth 1 "https://github.com/zsh-users/$p" "$ZC/plugins/$p" \
        || die "could not clone $p; rerun when the network is back"
    fi
  done
}

# append_line: add one line to a file. A hand-written last line that lacks its newline stays intact.
append_line() {
  local f="$1" line="$2"
  if [[ -s "$f" && -n "$(tail -c 1 "$f")" ]]; then
    printf '\n' >> "$f"
  fi
  printf '%s\n' "$line" >> "$f"
}

# ask_vm_host: on a VM, wt needs this host's alias from the Mac's ~/.ssh/config. The setup page runs
# WT_HOST=<vm> bash install.sh, so the answer never comes from stdin; otherwise read would eat the next line of
# a block that was pasted in one go. The script asks in a terminal only when the variable is absent. Either
# way, it records the answer in ~/.zshenv.local.
ask_vm_host() {
  if [[ $OS == Darwin ]] || grep -qs '^export WT_HOST=' "$HOME/.zshenv.local"; then
    return 0
  fi
  local h="${WT_HOST:-}"
  if [[ -z $h ]]; then
    if [[ ! -t 0 ]]; then
      SUMMARY_ACTIONS+=("Run install.sh in a terminal so it can ask for the VM name.")
      echo "WT_HOST unset: run install.sh in a terminal so it can ask for the VM name" >&2
      exit 1
    fi
    read -r -p "Name of this VM exactly as in the Mac's ~/.ssh/config (e.g. dev-a): " h
  fi
  if [[ ! $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "invalid or blank name: '$h'" >&2
    exit 1
  fi
  append_line "$HOME/.zshenv.local" "export WT_HOST=$h"
  echo "WT_HOST=$h written to ~/.zshenv.local"
}

# record_repos_dir: wt's own default is the Mac's ~/Documents/Repositories, but on a VM the task repos are
# cloned to ~/<repo>. So this function records the home folder once, as a literal $HOME that works for any user.
# shellcheck disable=SC2016
record_repos_dir() {
  if [[ $OS == Darwin ]] || grep -qs '^export WT_REPOS_DIR=' "$HOME/.zshenv.local"; then
    return 0
  fi
  append_line "$HOME/.zshenv.local" 'export WT_REPOS_DIR="$HOME"'
  echo 'WT_REPOS_DIR=$HOME written to ~/.zshenv.local (edit the line if repos live elsewhere)'
}

# require_plain_file <home-relative path>: some steps edit a file that this repo does not own. This function
# makes the refusals that each of those steps must make about that file:
#   A dangling symlink: -f calls it false, and a redirection, an append or `git config` would write through
#   it, somewhere outside $HOME.
#   Anything that is not a regular file, such as a directory or a device in its place: nothing below could
#   read it.
# A LIVE symlink is not a refusal here. Each caller decides for itself. The three callers that leave the link
# to its dotfile manager say so at the point where they skip it.
# The function is shared so that each step's check_… twin, which makes the same refusals early, cannot drift
# from its wording.
# One rule has two entry points. Most callers name a path under $HOME and want it spelled ~/… in the message.
# But git's global config file can be at $XDG_CONFIG_HOME/git/config or wherever GIT_CONFIG_GLOBAL points,
# which need not be under $HOME at all. So that caller passes the absolute path and the label to print.
require_plain_file() {
  # shellcheck disable=SC2088   # the ~ is literal on purpose: this is the label a message prints, not a path
  require_plain_path "$HOME/$1" "~/$1"
}

require_plain_path() {
  local p="$1" label="$2"
  if [[ -L $p && ! -e $p ]]; then
    die "broken symlink at $label (-> $(readlink "$p")): remove or repair it, then rerun"
  fi
  if [[ -e $p && ! -L $p && ! -f $p ]]; then
    die "not a regular file: $label; move it aside, then rerun"
  fi
}

# check_zshenv_local: ask_vm_host and record_repos_dir append to ~/.zshenv.local. So this check makes the same
# two refusals for it as for the files that the hooks append to:
#   - A dangling symlink at that path. append_line's >> creates the target, a file outside $HOME that nothing
#     will ever read.
#   - A directory at that path. The append fails raw.
# Here, unlike at ~/.tmux.conf, a LIVE symlink is deliberately NOT a refusal, for these reasons:
#   - This is the machine-local overrides file.
#   - The two lines are machine-local facts (this VM's name, where its repos live), not anything this repo owns.
#   - Both callers check with grep, which reads back through the link, so a rerun still adds nothing.
#   - A refusal would leave a VM whose ~/.zshenv.local is managed with no way to finish the install at all.
check_zshenv_local() {
  if [[ $OS == Darwin ]]; then
    return 0                           # neither caller writes the file on a Mac
  fi
  require_plain_file .zshenv.local
}

# BASHRC_SRC: the line that hook_bashrc puts at the top of ~/.bashrc, without the trailing comment. It is
# defined here, outside both functions, because check_bashrc must make exactly the same test on it as
# hook_bashrc. When the two tests drifted apart, check_bashrc refused installs that hook_bashrc would never
# have written to.
# shellcheck disable=SC2016
BASHRC_SRC='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

# bashrc_hooked <path>: tests whether our line is already the FIRST line of that file. If it is, hook_bashrc
# returns without doing anything: it never reads the mode, never builds a temp file, and never writes. So
# nothing downstream of that early return may refuse either.
bashrc_hooked() {
  local first
  [[ -f $1 && -r $1 ]] || return 1
  first="$(head -n 1 "$1")"
  [[ $first == "$BASHRC_SRC"* ]]       # with any comment that an older version of this script put after it
}

# check_bashrc: hook_bashrc runs after the linking steps, long after files have moved. So its three refusals
# would land on a half-installed machine. This function makes them instead, while nothing has been touched,
# with the same wording. Two cases are not refusals:
#   - A ~/.bashrc that is a live symlink. hook_bashrc skips it and says so at the point of the skip, so the
#     warning is not buried under the output of the whole install.
#   - A mode that hook_bashrc will never copy. On a Linux VM, an image that ships a 664 ~/.bashrc (umask 002,
#     user-private groups) is ordinary. When our line is at the top of that file, nothing is left to rewrite.
#     A refusal there would fail this install, and so every `wt update`, forever, over a file that this script
#     was not going to touch.
check_bashrc() {
  local rc="$HOME/.bashrc" mode
  if [[ $OS == Darwin ]]; then
    return 0
  fi
  require_plain_file .bashrc
  if [[ -L $rc ]]; then
    return 0                           # a dotfile manager owns it; hook_bashrc leaves it alone and warns
  fi
  if [[ ! -e $rc ]]; then
    return 0                           # nothing there: hook_bashrc writes the file itself
  fi
  if bashrc_hooked "$rc"; then
    return 0                           # already hooked: hook_bashrc returns before it reads the mode
  fi
  mode="$(stat -c %a "$rc" 2>/dev/null || stat -f %Lp "$rc" 2>/dev/null || true)"   # -c is GNU, -f is BSD
  if [[ $mode =~ ^[0-7]+$ ]] && (( 8#$mode & 8#022 )); then
    die "refusing to copy mode $mode: ~/.bashrc is group- or other-writable; chmod go-w ~/.bashrc, then rerun"
  fi
}

# hook_bashrc: cmux's remote tmux rows start every pane as bash with its own rcfile, and never run zsh. That
# rcfile ends by sourcing ~/.bashrc. Without this hook, nothing in those rows reads the linked ~/.zshenv.
# That file is plain sh, so one line gives bash the same environment (PATH, WT_HOST, WT_REPOS_DIR) that a zsh
# session gets. The line goes first in ~/.bashrc, because Ubuntu's ~/.bashrc returns on its fourth line when
# the shell is not interactive. The bash that sshd starts for `ssh <vm> '<cmd>'` does read ~/.bashrc. So a
# line further down never runs in that bash, and `wt -H <vm> …` fails. Nothing on a VM may depend on zsh
# anyway: an Azure ML compute instance resets the login shell to /bin/bash on every boot. So this one line
# carries the environment to every bash on the VM.
# shellcheck disable=SC2016
hook_bashrc() {
  local src="$BASHRC_SRC"
  local rc="$HOME/.bashrc" line mode tmp target moved=0
  line="$src   # workgrove: PATH, WT_HOST, WT_REPOS_DIR in cmux's bash rows"
  if [[ $OS == Darwin ]]; then
    return 0
  fi
  # check_bashrc made these refusals before anything moved. They stay here to cover the gap between the two
  # calls, and because nothing further down may run on a ~/.bashrc that it cannot read.
  require_plain_file .bashrc
  if [[ -L $rc ]]; then               # a live link into a dotfiles repo: a rewrite here would put a regular
    target="$(readlink -f "$rc")"     # file in its place and orphan the target. The repo would then quietly
    {                                 # stop governing ~/.bashrc, and the user would find out only weeks later.
      # shellcheck disable=SC2088  # The summary prints a home-relative path.
      SUMMARY_SKIPS+=("~/.bashrc is managed by a symlink")
      SUMMARY_ACTIONS+=("Add this as the FIRST line of $target: $line")
      echo "skipped ~/.bashrc: it is a symlink to $target, left alone because a dotfile manager owns it."
      echo "add this yourself, as the FIRST line of $target:"
      echo "  $line"
      echo "until then 'wt -H <vm> …' fails: cmux's remote bash rows read ~/.bashrc, never ~/.zshenv."
    } >&2
    return 0
  fi
  if [[ ! -e $rc && ! -L $rc ]]; then   # -L as well as -e: only both tests together show that nothing is there
    printf '%s\n' "$line" > "$rc"
    echo "bash reads ~/.zshenv too (first line of ~/.bashrc): cmux rows on a VM run bash"
    return 0
  fi
  if bashrc_hooked "$rc"; then                     # our line is already first, whatever comment follows it:
    return 0                                       # check_bashrc made the same test, so the two cannot drift
  fi
  if awk -v s="$src" 'index($0, s) == 1 { found = 1 } END { exit !found }' "$rc"; then
    moved=1                                        # an older run appended it below Ubuntu's early return
  fi
  mode="$(stat -c %a "$rc" 2>/dev/null || stat -f %Lp "$rc" 2>/dev/null || true)"   # -c is GNU, -f is BSD;
                                                                                    # $rc is a regular file here, so there is no link mode to read through
  if [[ ! $mode =~ ^[0-7]+$ ]]; then
    mode=""                            # stat gave no usable mode: keep the 600 that mktemp gives under this umask
  elif (( 8#$mode & 8#022 )); then     # never copy a group- or other-writable mode to a file every login shell sources
    die "refusing to copy mode $mode: ~/.bashrc is group- or other-writable; chmod go-w ~/.bashrc, then rerun"
  fi
  tmp="$(mktemp "$rc.XXXXXX")"
  TMPFILES+=("$tmp")                 # the EXIT trap removes it if anything below fails
  {
    printf '%s\n' "$line"
    if (( moved )); then
      awk -v s="$src" 'index($0, s) != 1' "$rc"      # drop only lines that START with it: a user line that
                                                    # merely mentions the text in prose is left alone
    else
      cat "$rc"
    fi
  } > "$tmp"
  if [[ -n $mode ]]; then
    chmod "$mode" "$tmp"
  fi
  stash "$rc"                        # the backup contract applies here too: keep the original
  mv "$tmp" "$rc"
  if (( moved )); then
    echo "moved the ~/.zshenv line to the top of ~/.bashrc so non-interactive shells read it too"
  else
    echo "bash reads ~/.zshenv too (first line of ~/.bashrc): cmux rows on a VM run bash"
  fi
}

# require_git_identity: commits need an identity, so this check stays unconditional. On every machine, opted in
# or not, this repo puts the identity in ~/.gitconfig.local, because configure_git includes that file when
# ~/.gitconfig is not linked. The function reads that file directly, not through git's own lookup, because on a
# first run the include does not exist yet. A user who already keeps an identity in their own ~/.gitconfig is
# not asked to move it.
require_git_identity() {
  local email
  email="$(git config --file "$HOME/.gitconfig.local" user.email 2>/dev/null || true)"
  if [[ -z "$email" ]]; then
    email="$(git config --global user.email 2>/dev/null || true)"
  fi
  if [[ -z "$email" ]]; then
    SUMMARY_ACTIONS+=("Set user.name/user.email in ~/.gitconfig.local, then rerun install.sh.")
    echo "set user.name/user.email in ~/.gitconfig.local (see the setup page), then rerun" >&2
    exit 1
  fi
}

# resolve_git_global: finds WHICH file `git config --global` writes. That file is not always ~/.gitconfig, so it
# is not always the file that the two steps below must guard. git's own order, confirmed against git 2.39:
#   1. $GIT_CONFIG_GLOBAL, if it is set.
#   2. Else ~/.gitconfig, if it EXISTS. The test follows the link, so a dangling link does not count.
#   3. Else $XDG_CONFIG_HOME/git/config (default ~/.config/git/config), if that exists.
#   4. Else ~/.gitconfig, which git creates.
# A guard on ~/.gitconfig alone missed both refusals that this script makes about the file:
#   - On a machine whose dotfile manager owns ~/.config/git/config and leaves no ~/.gitconfig, configure_git
#     wrote two machine-local absolute paths straight through that manager's symlink. That is the one thing it
#     promises not to do. It then reported the edit as a change to a ~/.gitconfig that does not exist.
#   - A directory at the XDG path took the whole install down mid-way in git's voice, with exit 128:
#     "unknown error occurred while reading the configuration files".
#     check_gitconfig exists to prevent precisely that.
# main resolves the file once, before anything moves.
resolve_git_global() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
  if [[ -n ${GIT_CONFIG_GLOBAL:-} ]]; then
    GITRC="$GIT_CONFIG_GLOBAL"
  elif [[ -e "$HOME/.gitconfig" ]]; then
    GITRC="$HOME/.gitconfig"
  elif [[ -e "$xdg" ]]; then
    GITRC="$xdg"
  else
    GITRC="$HOME/.gitconfig"
  fi
  if [[ $GITRC == "$HOME"/* ]]; then
    # shellcheck disable=SC2088     # literal, as above: $GITRC is the path, $GITRC_LABEL only prints
    GITRC_LABEL="~/${GITRC#"$HOME"/}"  # the spelling every other message in this script uses
  else
    GITRC_LABEL="$GITRC"
  fi
}

# check_gitconfig: the reasoning of check_bashrc, for the third file that this script writes into.
# configure_git runs near the end. There, `git config --global` makes its own refusals in git's voice,
# mid-install, after everything has moved:
#   - A dangling target gives "error: could not lock config file", exit 255.
#   - A directory gives "fatal: unknown error occurred while reading the configuration files", exit 128.
# This function makes those refusals instead, while the machine is still untouched, in this script's wording.
# It checks $GITRC, not ~/.gitconfig, because $GITRC is the file that git will open.
check_gitconfig() {
  if opted_in "$WITH_GITCONFIG" .gitconfig; then
    return 0                           # ~/.gitconfig is about to become a link into this repo, and git prefers
  fi                                   # it over the XDG file as soon as it exists
  require_plain_path "$GITRC" "$GITRC_LABEL"
}

# configure_git: two settings of home/.gitconfig are machinery, not taste:
#   - core.excludesFile. It is what git-ignores .worktrees/, and so what makes `wt` invisible to git.
#   - The ~/.gitconfig.local include. It is where the identity above lives.
# When home/.gitconfig was not opted in, this function writes the two settings into the user's own global
# config with `git config`. `git config` edits in place and leaves every other line of that config alone.
# That file is $GITRC, resolved above. It is usually ~/.gitconfig, but ~/.config/git/config on a machine that
# keeps it there. It is never a path that this script assumed. The function is silent unless it changes
# something, so a rerun (and `wt update`) says nothing.
configure_git() {
  local ex="$HOME/.gitignore_global" inc="$HOME/.gitconfig.local" rc="$GITRC" have found=0 v
  if opted_in "$WITH_GITCONFIG" .gitconfig; then
    return 0                           # the linked home/.gitconfig carries both settings
  fi
  # check_gitconfig made these refusals before anything moved. They stay here to cover the gap between the
  # two calls, and because `git config` below would write through whatever is at $GITRC.
  require_plain_path "$rc" "$GITRC_LABEL"
  if [[ -L $rc ]]; then               # a live link into a dotfiles repo: `git config --global` follows it
    {                                 # and edits the file that the repo owns and syncs, which is not ours to edit
      SUMMARY_SKIPS+=("$GITRC_LABEL is managed by a symlink")
      SUMMARY_ACTIONS+=("Add core.excludesFile = $ex and include.path = $inc to $GITRC_LABEL.")
      echo "skipped $GITRC_LABEL: it is a symlink to $(readlink "$rc"), left alone because a dotfile manager owns it."
      echo "add these yourself, in that file (both paths are this machine's, so keep them out of anything you sync):"
      echo "  [core]"
      echo "      excludesFile = $ex"
      echo "  [include]"
      echo "      path = $inc"
      echo "until then .worktrees/ is not git-ignored and git never reads your ~/.gitconfig.local identity."
    } >&2
    return 0
  fi
  # --type=path, not the raw string: a config that says `excludesFile = ~/.gitignore_global` (what this repo's
  # own home/.gitconfig writes) holds exactly the wanted value. A raw comparison would warn about it forever.
  have="$(git config --global --get --type=path core.excludesFile 2>/dev/null || true)"
  if [[ -z $have ]]; then
    git config --global core.excludesFile "$ex"
    echo "set core.excludesFile = ~/.gitignore_global in $GITRC_LABEL (it is what git-ignores .worktrees/)"
  elif [[ $have != "$ex" ]]; then      # the user points it at their own file: replacing it would silently drop
    {                                  # every rule in that file, so say what is missing instead
      SUMMARY_SKIPS+=("core.excludesFile points at $have")
      SUMMARY_ACTIONS+=("Add the lines of ~/.gitignore_global to $have.")
      echo "kept core.excludesFile = $have: this repo did not change it."
      echo "add the lines of ~/.gitignore_global to that file, or .worktrees/ is not ignored."
    } >&2
  fi
  # include.path is multi-valued, so a plain `git config --global include.path …` is not idempotent in the way
  # that core.excludesFile is. It would overwrite the one include that the user already has, and it would
  # refuse outright (exit 5) when there are two. So read every value, and --add only when ours is missing.
  # --type=path expands a value written as ~/…, so that value compares equal to the one written here.
  while IFS= read -r v; do
    if [[ $v == "$inc" ]]; then found=1; fi
  done < <(git config --global --get-all --type=path include.path 2>/dev/null || true)
  if (( ! found )); then
    git config --global --add include.path "$inc"
    echo "added include.path = ~/.gitconfig.local to $GITRC_LABEL (where your git identity lives)"
  fi
}

# report: the EXIT trap, armed when files start to move. It has two jobs:
#   1. It removes the half-built files that the mktemp steps leave behind when a signal arrives between
#      building one and moving it into place. An EXIT trap runs on SIGINT and SIGTERM too. So without this
#      job, a ^C mid-run orphans a ~/.claude/settings.json.XXXXXX for good.
#   2. It says where anything that was in the way ended up. But a die() reaches the trap in the same way as a
#      finished run does. finish_install passes the exit status to report.
#      A failure gets a failure message instead of "done." under the error message.
report() {
  local rc=$1
  if [[ ${#TMPFILES[@]} -gt 0 ]]; then
    rm -f "${TMPFILES[@]}"             # already moved into place: rm -f on a gone path is a no-op
  fi
  if [[ $rc -ne 0 ]]; then
    if [[ -d "$BK" ]]; then
      echo "install.sh stopped part-way (exit $rc): what had already moved is in $BK" >&2
    else
      echo "install.sh stopped part-way (exit $rc): nothing had been backed up" >&2
    fi
    return 0                           # a return does not change the status the script is exiting with
  fi
  if [[ -d "$BK" ]]; then
    echo "done. backups in $BK"
  else
    echo "done. nothing needed backing up"
  fi
}

# Report optional config that this run left alone.
report_skipped() {
  local f=""
  opted_in "$WITH_ZSHRC"       .zshrc                          || f="$f --with-zshrc"
  opted_in "$WITH_GITCONFIG"   .gitconfig                      || f="$f --with-gitconfig"
  opted_in "$WITH_TMUX_CONF"   .tmux.conf                      || f="$f --with-tmux-conf"
  opted_in "$WITH_KEYBINDINGS" .claude/keybindings.json        || f="$f --with-keybindings"
  opted_in "$WITH_STATUSLINE"  .claude/statusline-command.sh   || f="$f --with-statusline"
  if [[ $OS == Darwin ]]; then         # on a VM there is no cmux, so this run does not offer the flag
    opted_in "$WITH_CMUX_CONFIG" "$CMUX_DST"                   || f="$f --with-cmux-config"
  fi
  claude_ui_opted_in                                           || f="$f --with-claude-ui"
  if [[ -n $f ]]; then
    SUMMARY_SKIPS+=("Optional config was not selected:$f")
    SUMMARY_ACTIONS+=("Run: install.sh$f (or install.sh --opinionated-config)")
    echo "left alone (the author's own taste, not machinery):$f"
    echo "rerun with those flags, or --opinionated-config for all of them, to install them"
  fi
}

finish_install() {
  local rc=$?
  if (( REPORT_ACTIVE )); then report "$rc"; fi
  if [[ $rc -eq 0 ]]; then print_summary; else print_summary >&2; fi
}

# Print the accumulated actions after the final status, including early refusals.
print_summary() {
  local item
  echo "Install summary:"
  echo "  Skips:"
  if [[ ${#SUMMARY_SKIPS[@]} -eq 0 ]]; then
    echo "    none"
  else
    for item in "${SUMMARY_SKIPS[@]}"; do printf '    %s\n' "$item"; done
  fi
  echo "  Follow-up actions:"
  if [[ ${#SUMMARY_ACTIONS[@]} -eq 0 ]]; then
    echo "    none"
  else
    for item in "${SUMMARY_ACTIONS[@]}"; do printf '    %s\n' "$item"; done
  fi
}

# shellcheck source=lib/workgrove/automation.sh
source "$R/lib/workgrove/automation.sh"

main() {
  trap finish_install EXIT
  parse_args "$@"
  BK="$HOME/.workgrove-backup/$(date +%Y%m%d-%H%M%S)-$$"   # timestamp+pid: same-second reruns cannot collide
  # Every step that can refuse runs first, while the machine is still untouched. A half-install that then
  # says "set user.name … and rerun" leaves the user with displaced files and no idea where they went. So
  # every refusal, including the check_… twins of the later steps, comes before the FIRST write of any kind.
  # The two ~/.zshenv.local lines below were once written in among the refusals. A run that then refused had
  # already edited a file that class 3 promises is never rewritten. It also had no trap yet to say so.
  # Two facts must be read while the machine is still as the LAST run left it:
  #   - link_dotfiles re-points ~/.zshenv. After that, no dangling sibling can be matched against the root
  #     that ~/.zshenv used to carry.
  #   - Which file `git config --global` writes depends on whether ~/.gitconfig exists, and this run may
  #     change that.
  read_zshenv_root
  resolve_git_global
  require_oh_my_zsh
  require_jq
  require_git_identity
  check_zshenv_local # Linux only: the file that the next two steps append to
  check_bashrc       # Linux only: hook_bashrc's refusals, made while ~/.bashrc is still the only thing at stake
  check_gitconfig    # the same, for the ~/.gitconfig that configure_git writes two settings into
  ask_vm_host        # Linux only: rejects an unusable VM name before anything moves
  record_repos_dir   # Linux only
  trap 'exit 130' INT    # so $? at report's entry is the signal's status, not the last command's
  trap 'exit 143' TERM
  REPORT_ACTIVE=1   # From here on, report where the originals went.
  make_dirs
  install_bins
  link_dotfiles
  install_configs
  link_skills
  link_cmux_config
  remove_retired_links  # after every linking step, so this run's links exist and are live; before the two
                        # steps that can fail, so a rerun still tidies up even without a network or a ~/.bashrc
  hook_bashrc        # Linux only
  configure_git
  hook_cmux_automation
  install_zsh_plugins   # last: the only step that needs the network, so an offline VM still gets the rest
  report_skipped     # after every step, so it lists what is still missing rather than what was about to arrive
}

main "$@"
