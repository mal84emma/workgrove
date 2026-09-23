#!/usr/bin/env bash
#
# install.sh: install this repo into $HOME.
#   bash ~/repos/workstation/install.sh [--refresh-config] [--opinionated-config]
#       [--with-zshrc] [--with-gitconfig] [--with-tmux-conf] [--with-keybindings] [--with-statusline]
#       [--with-claude-ui] [--with-cmux-config]
#   (on a VM, prefix WT_HOST=<vm>)
#
# Idempotent: rerun it whenever the repo changes. Nothing is ever deleted; anything in the way is
# moved into ~/.workstation-backup/<YYYYmmdd-HHMMSS>-<pid>, created only if it is actually needed
# (a no-op run leaves no empty directory behind).
#
# Three classes of file:
#   1. Stable files — shell/git/tmux dotfiles, the Claude and Codex instructions, the skills, the
#      bin/ scripts, cmux.json — are SYMLINKED out of this repo, so edits (including an agent's)
#      land in the repo and `git diff` is the review. Six of them are the author's taste rather than
#      machinery, so they are OPT-IN; see below.
#   2. ~/.claude/settings.json, ~/.codex/config.toml and ~/.codex/hooks.json are machine-local
#      COPIES of the versioned .base files, because the apps write local state into them. A normal
#      run keeps an existing copy ("kept …"); only --refresh-config stashes it and rewrites it.
#      A refresh therefore drops the state Codex writes into config.toml (its hook trust hashes and
#      folder trust), so trust the hooks in /hooks after a refresh, not before.
#   3. Everything else is never rewritten: the hand-written overrides (~/.gitconfig.local, ~/.zshrc.local
#      and ~/.zshenv.local, which on a VM only gains a WT_HOST and a WT_REPOS_DIR line when it has none)
#      and the real directories the apps write into. On a VM ~/.bashrc likewise only gains one line, which
#      sources ~/.zshenv, when it has none.
#
# Cutting across the three, an opt-in: installing this repo must not hand a stranger the author's shell
# prompt, git config and tmux bindings, so the six files in class 1 that are taste rather than machinery
# arrive only when asked for — ~/.zshrc (and with it the oh-my-zsh theme, the oh-my-zsh prerequisite and the
# plugin clone that exist only to serve it) with --with-zshrc, ~/.gitconfig with --with-gitconfig,
# ~/.tmux.conf with --with-tmux-conf, ~/.claude/keybindings.json with --with-keybindings,
# ~/.claude/statusline-command.sh with --with-statusline and, on a Mac only, ~/.config/cmux/cmux.json with
# --with-cmux-config.
# A seventh flag, --with-claude-ui, gates KEYS rather than a file: ~/.claude/settings.json is installed on every
# machine because its hooks and permissions are machinery, but .tui, .voice, .theme and the env var that turns
# mouse clicks off in the Claude Code TUI are the author's taste in the same way the six files are, so
# copy_config deletes them from the copy unless the flag is given. --opinionated-config turns on all seven.
# None of the seven flags ever has to be repeated. For the six files the record is the destination itself: one
# that is already a link into this repo counts as asked for, so `wt update`, which reruns this script bare,
# keeps what an earlier run installed. --with-claude-ui has no symlink to read, but it has the same kind of
# record — an existing ~/.claude/settings.json that still carries a top-level .tui key can only have been
# written by a run that was given the flag — and claude_ui_opted_in reads it with the very jq probe copy_config
# already makes for its kept-copy warning. Stickiness is not a nicety here: the one documented way to pick up a
# change to a .base file is --refresh-config, `wt update --refresh-config` cannot forward --with-claude-ui, and
# a non-sticky flag would therefore make the prescribed update command silently strip the UI keys off every
# machine that has them.
# Three of the six also carry settings the rest of this repo depends on, and declining the file does not
# decline those: without the linked ~/.gitconfig, `git config` puts core.excludesFile (what git-ignores
# .worktrees/) and the ~/.gitconfig.local include into the user's own file and changes nothing else; without
# the linked ~/.tmux.conf, its update-environment line — how cmux's relay variables reach panes in an
# already-running session — is appended to the user's; and without the linked cmux.json, the one hook entry
# that runs ~/.local/bin/cmux-hook is merged into the user's own, by hook_cmux_config, which is the only
# fallback here that cannot always be made — see the refusals written out there.
#
# Exits 2 on a usage error. Exits 1 when a prerequisite is missing — jq, oh-my-zsh (only when ~/.zshrc is
# opted in), the VM name (Linux), a git identity — or when something this script would write to is not
# something it may write to: a broken symlink or a non-regular file at any of the paths require_plain_file
# guards, or a group- or other-writable ~/.bashrc it would have to rewrite. Every one of those refusals is
# made before the first file moves.
set -euo pipefail
umask 077

# -P, not a plain pwd: every link below records this path and opted_in reads it back, and `wt update`
# reruns this script from "$(cd "$(dirname "$s")/.." && pwd -P)". A clone reached through a symlinked path
# component would otherwise record one spelling from one entry point and the other from the other, and
# every link made under the first would read as "not ours" under the second.
R="$(cd "$(dirname "$0")" && pwd -P)"   # this repo
OS="${FORCE_OS:-$(uname -s)}"        # FORCE_OS exists only so test/install-smoke.sh can drive the Linux-only
                                     # steps — hook_bashrc above all, the most intricate function here — from a
                                     # Mac. Nothing else ever sets it.
# ZC: oh-my-zsh's own customisation directory, and the one place BOTH things ~/.zshrc needs from this script
# have to land: oh-my-zsh looks for the theme ZSH_THEME names, and for the plugins, under $ZSH_CUSTOM alone
# whenever that is set. install_zsh_plugins always honoured it; link_dotfiles used to hardcode
# ~/.oh-my-zsh/custom, so on a machine with ZSH_CUSTOM set the plugins arrived, the theme did not, and every
# shell start said "[oh-my-zsh] theme 'workstation' not found" while every line of the install said success.
# link() spells its destination relative to $HOME, so a $ZSH_CUSTOM outside $HOME cannot be expressed at all;
# require_oh_my_zsh refuses --with-zshrc there rather than installing half of it.
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
TMPFILES=()                          # half-built files; removed by report, which is the EXIT trap
ZSHENV_ROOT=""                       # the clone root ~/.zshenv pointed at before this run; read by
                                     # read_zshenv_root, used by opted_in
GITRC=""                             # the file `git config --global` actually writes; resolve_git_global
GITRC_LABEL=""                       # …the same path, spelled for a message

# parse_args <script args…>: flags in any order and any combination — each --with-… adds one opinionated
# file (or, for --with-claude-ui, one group of keys), --opinionated-config is all seven at once,
# --refresh-config is orthogonal to all of them. --with-cmux-config is accepted on a VM too, where it
# simply has nothing to do: cmux is a Mac application, and a flag that is a usage error on one platform and
# not the other would make `wt update --with-cmux-config` a command the user has to remember not to run there.
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

# our_link <absolute path> <repo-relative src>: is that symlink one this script made for <src>? Three ways to
# be ours, in order of how much they assume.
#   1. It points into $R, the spelling every link this run makes carries.
#   2. It still RESOLVES into $R. A run before $R was resolved with pwd -P recorded the clone's path with a
#      symlinked component in it, and that link is live and correct — it just spells the repo differently.
#   3. It DANGLES and its target ends in the same repo-relative path. That is what a link made before the
#      clone was moved or renamed looks like afterwards: the old root is gone, but the tail is this repo's
#      own layout, so link() can stash it and re-point it and the machine heals itself.
# The dangling requirement in 3 is what keeps the tail test honest. A LIVE link into a SECOND checkout the
# user deliberately keeps — the one link this script must never touch — would match on its tail alone, so a
# link whose target still exists is ours only when it resolves into THIS repo, which that one never does.
# Case 3 is a statement about LAYOUT, not about consent, and only remove_retired_links may read it as one: the
# worst it can cost there is a stash. home/.zshrc, home/.gitconfig and home/.tmux.conf are not distinctive
# tails — they are what chezmoi, yadm, dotbot, homeshick and a `home` stow package all produce — so a machine
# whose dotfile links merely happen to be dangling (bootstrap ran before the dotfiles repo was cloned, the repo
# is on an unmounted volume) must not read as "already opted in" to a run given no flags. opted_in therefore
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

# read_zshenv_root: the one fact that makes a DANGLING link readable as consent, read once — and it has to be
# once, at the top of main(), before link_dotfiles re-points ~/.zshenv at $R and every still-dangling sibling
# stops matching. ~/.zshenv is linked unconditionally by every run of this script and no dotfile manager
# installs one, so a dangling ~/.zshenv whose target ends in home/.zshenv names, exactly, the clone THIS
# machine was installed from before it moved. A live ~/.zshenv says nothing extra: our_link's cases 1 and 2
# already settle every live sibling.
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

# consenting_link <absolute path> <repo-relative src>: is that symlink the record of an earlier run's --with-…
# flag? Stricter than our_link, because this answer is read as CONSENT rather than as ownership, and the price
# of a wrong yes is handing a stranger the author's shell prompt, git config and tmux bindings with nothing in
# the output saying so — the precise harm the opt-in above exists to prevent.
#   A live link: our_link decides, its cases 1 and 2, which are about this repo and nothing else.
#   A dangling link: ours only when its old root is the old root of a link this script CERTAINLY made, which is
#   what read_zshenv_root went and got. That still heals a moved clone — every link it made moved together — and
#   it no longer mistakes a foreign manager's momentarily dangling home/.zshrc for an answer this user gave.
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

# opted_in <flag> <home-relative dst>: does this run install that opinionated file? Either the flag asked for
# it, or ~/dst is ALREADY a link an earlier run of this script made, which is the record that run's flag left:
# `wt update` reruns this script with no arguments, so a choice made once has to survive a run that cannot see
# it, and no state is stored anywhere for it to disagree with. On a machine where all six are already linked —
# every machine the author has — every answer is yes, so this whole opt-in changes nothing there.
# Only the six FILES can be asked this. --with-claude-ui gates keys inside a copied file, so its record is the
# keys themselves; claude_ui_opted_in reads that one.
opted_in() {
  if [[ $1 -eq 1 ]]; then
    return 0
  fi
  consenting_link "$HOME/$2" "home/$2"
}

# claude_ui_opted_in: the same question for the sixth flag. An existing ~/.claude/settings.json that is a real
# file and still has a top-level .tui key was written by a run that was given --with-claude-ui: copy_config
# strips that key from every copy written without it. Reading it back here is what keeps `wt update
# --refresh-config`, which cannot forward the flag, from silently deleting the UI keys of a machine that has
# them. Probed with the jq call copy_config already makes eleven lines further down, so the two cannot drift.
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
  echo "$*" >&2
  exit 1
}

# stash <path>: move an existing file, dir or symlink into the backup dir. Never deletes.
stash() {
  if [[ ! -e "$1" && ! -L "$1" ]]; then
    return 0
  fi
  local rel="${1#"$HOME"/}"
  mkdir -p "$BK/$(dirname "$rel")"   # made here, so the backup dir exists only when used
  mv "$1" "$BK/$rel"
}

# link <repo-relative src> <home-relative dst>: point ~/dst at <repo>/src, stashing what was there.
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

# copy_config <repo-relative .base> <home-relative dst> <claude|codex|plain>: install one machine-local
# copy, keeping an existing real file unless --refresh-config was given. Kind "claude" drops the
# voice keys off a Mac, because a VM has no local microphone, and the UI keys unless --with-claude-ui (or the
# record of an earlier one) asked for them, because those are taste rather than machinery; kind "codex" drops
# the Keychain credential store off a Mac, because only macOS has one.
# A SYMLINK at $dst is displaced, and deliberately so — this is the one place that does not leave a dotfile
# manager's link alone the way hook_bashrc, hook_tmux_conf and configure_git do. These three files are exactly
# the ones the apps write their own state into, so they must be real files at the path the app opens; a link
# would send Claude's and Codex's writes into a synced repo that then fights them. Nothing is lost: only the
# LINK moves into the backup dir, the file it pointed at is untouched, and the displacement gets a line of its
# own in the output rather than being folded into "installed ~/…". That is also why this step has no check_…
# twin in the refuse-before-writes pass: it has nothing to refuse.
# The new file is built in full before the old one is stashed, so a filter that fails cannot leave a truncated
# ~/dst behind. A replaced copy is only ever stashed, never merged: a refreshed .codex/config.toml loses the
# tables Codex wrote into it (hook trust, folder trust), which the old file in the backup dir still holds and
# /hooks restores.
copy_config() {
  local src="$R/$1" dst="$HOME/$2" kind="$3"
  if [[ -e "$dst" && ! -L "$dst" && $REFRESH -eq 0 ]]; then
    echo "kept ~/$2 (install.sh --refresh-config replaces it)"
    # Keeping the file also keeps the filter decision the FIRST install made. --with-statusline on a machine
    # that is already installed therefore links the script and leaves settings.json without the key that
    # names it: the status line never appears and every line of the run says success. Say it here instead.
    if [[ $kind == claude ]] && opted_in "$WITH_STATUSLINE" .claude/statusline-command.sh \
       && ! jq -e 'has("statusLine")' "$dst" >/dev/null 2>&1; then
      echo "…but the kept ~/$2 has no statusLine key, so the status line will not appear:" >&2
      echo "rerun with --refresh-config to rewrite it (the old copy goes to the backup dir)" >&2
    fi
    # The same trap for the keys --with-claude-ui asks for: the flag only ever reaches the file being
    # WRITTEN, so on an already-installed machine it changes nothing and every line of the run says success.
    if [[ $kind == claude && $WITH_CLAUDE_UI -eq 1 ]] \
       && ! jq -e 'has("tui")' "$dst" >/dev/null 2>&1; then
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
      filter="$filter | del(.voice, .voiceEnabled)"       # no local microphone on a VM, flag or no flag
    fi
    # UI taste, not machinery — the hooks and permissions around them stay on every machine. The env var is
    # in this list for the same reason the three keys are: it turns mouse clicks off in the Claude Code TUI, so
    # a stranger who never asked for the author's UI would otherwise find their mouse dead with nothing in the
    # run's output naming the key. Composed with, not instead of, the line above: del() of a key another del()
    # already removed is a no-op — and so is del() of a nested path that is not there — so .voice goes on a VM
    # either way and the two tests stay independent.
    if ! claude_ui_opted_in; then
      filter="$filter | del(.tui, .voice, .theme, .env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS)"
    fi
    if ! opted_in "$WITH_STATUSLINE" .claude/statusline-command.sh; then
      filter="$filter | del(.statusLine)"                 # the script it names is opt-in: a command pointing at a
    fi                                                    # file that was never installed breaks the status line
    # .env holds exactly that one key today, so the del above can empty it: drop the object rather than write
    # an `"env": {}` no run ever meant to put there.
    filter="$filter | if (.env | length) == 0 then del(.env) else . end"
    jq "$filter" "$src" >"$tmp" || { rm -f "$tmp"; die "jq failed on $1"; }
  elif [[ $kind == codex && $OS != Darwin ]]; then
    grep -v '^cli_auth_credentials_store' "$src" >"$tmp" || { rm -f "$tmp"; die "failed to filter $1"; }
  else
    cp "$src" "$tmp"
  fi
  chmod 600 "$tmp"
  if [[ -L "$dst" ]]; then                                # see the header: the link goes, its target stays
    echo "replaced the symlink at ~/$2 (-> $(readlink "$dst")) with a real file: the app writes its own state"
    echo "into this one, so it cannot be a link; the link itself is in the backup dir, its target untouched"
  fi
  stash "$dst"                                            # only now is anything moved
  mv "$tmp" "$dst"
  echo "installed ~/$2"
}

# require_oh_my_zsh: the linked ~/.zshrc needs it, so stop early and name the setup page — but only when that
# .zshrc is opted in: nothing else this script installs uses oh-my-zsh, so refusing without it would be a
# prerequisite invented for a file the user is not getting.
# require_jq: copy_config filters the Claude settings on every platform, and it must be present BEFORE anything moves.
require_jq() {
  if command -v jq >/dev/null 2>&1; then                  # every platform: copy_config filters the Claude
    return 0                                              # settings on both, and statusline-command.sh is
  fi                                                      # opt-in, so the statusLine key is dropped on a Mac too
  if [[ $OS == Darwin ]]; then
    die "jq not found: brew install jq (or brew bundle --file $R/Brewfile), then rerun"
  fi
  die "jq not found: sudo apt-get install -y jq, then rerun"
}

require_oh_my_zsh() {
  if ! opted_in "$WITH_ZSHRC" .zshrc; then
    return 0
  fi
  if [[ -z $ZC_REL ]]; then            # see ZC above: link() can only spell a destination under $HOME, and half
                                       # an install — plugins yes, theme no — is what this used to do silently
    echo "ZSH_CUSTOM=$ZC is outside \$HOME, so the theme ~/.zshrc names cannot be linked into $ZC/themes" >&2
    die "unset ZSH_CUSTOM, or point it inside \$HOME, then rerun"
  fi
  if [[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
    return 0
  fi
  local page=vm
  [[ $OS == Darwin ]] && page=mac
  echo "install oh-my-zsh first (docs/new-$page.md)" >&2
  exit 1
}

# make_dirs: the directories the apps write into stay real directories — never link them.
make_dirs() {
  mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills" "$HOME/.codex" "$HOME/.agents/skills"
  if [[ $OS == Darwin ]]; then          # the Mac's task repos folder; on a VM they live in the home folder
    mkdir -p "$HOME/Documents/Repositories"
  fi
}

# install_bins: link the scripts into ~/.local/bin, retiring any copy in ~/bin (which is first on PATH).
install_bins() {
  local b
  for b in wt agent-notify cmux-hook azml-ssh-host; do
    if [[ -e "$HOME/bin/$b" || -L "$HOME/bin/$b" ]]; then
      stash "$HOME/bin/$b"
      echo "retired ~/bin/$b (it shadowed ~/.local/bin/$b); the old copy is in the backup dir"
    fi
    link "bin/$b" ".local/bin/$b"
  done
}

# link_dotfiles: the stable shell, git, tmux, Claude and theme files. The first loop is machinery every
# install needs: ~/.zshenv carries PATH and the wt variables, ~/.gitignore_global is the list core.excludesFile
# points at (linked either way, because the git fallback below points at it too), and the two instruction
# files are what the agents read. The rest is taste, so each waits for its own opt-in — the theme with the
# ~/.zshrc that is the only thing naming it.
link_dotfiles() {
  local f
  for f in .zshenv .gitignore_global .claude/AGENTS.md .claude/CLAUDE.md; do
    link "home/$f" "$f"
  done
  if opted_in "$WITH_ZSHRC" .zshrc; then
    link home/.zshrc .zshrc
    link home/.oh-my-zsh/custom/themes/workstation.zsh-theme "$ZC_REL/themes/workstation.zsh-theme"
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

# install_configs: the three mutable files, copied from their .base versions.
install_configs() {
  copy_config home/.claude/settings.base.json .claude/settings.json claude
  copy_config home/.codex/config.base.toml    .codex/config.toml    codex
  copy_config home/.codex/hooks.base.json     .codex/hooks.json     plain
}

# link_skills: each skill is linked twice — Codex reads ~/.agents/skills, Claude only ~/.claude/skills —
# and Codex takes the shared instructions from ~/.codex/AGENTS.md.
link_skills() {
  local d n
  for d in "$R"/home/.agents/skills/*/; do
    [[ -d "$d" ]] || continue          # nullglob is off, so a fork with no skills runs the body once with
                                       # the pattern itself and would link ~/.agents/skills/* — which the
                                       # next run then retires, minting a backup dir on every run
    n="$(basename "$d")"
    link "home/.agents/skills/$n" ".agents/skills/$n"
    link "home/.agents/skills/$n" ".claude/skills/$n"
  done
  link home/.claude/AGENTS.md .codex/AGENTS.md
}

# link_cmux_config: cmux runs on the Mac only; its UI settings stay a link so changes show in `git diff`.
# Opt-in, like the other five taste files: of home/.config/cmux/cmux.json's 279 lines exactly one entry is
# machinery — the hook that runs ~/.local/bin/cmux-hook — and the rest is a palette, sound overrides, a
# sidebar layout, three hotkeys and tab-bar buttons nobody but the author asked for. Without the flag the
# file is not linked and hook_cmux_config merges that one entry into whatever the user already has.
link_cmux_config() {
  if [[ $OS != Darwin ]]; then
    return 0
  fi
  if opted_in "$WITH_CMUX_CONFIG" "$CMUX_DST"; then
    link "home/$CMUX_DST" "$CMUX_DST"
  fi
}

# retired_src <home-relative dst>: the repo-relative path the linking steps above point that destination at,
# which is what our_link's tail test needs to recognise a link made before this clone moved. Five of the eight
# directories mirror the repo's own layout, so home/<dst> is right there — and this used to be inferred for all
# of them, which meant the three below could never be retired once the clone had moved: their source is not
# their destination, the tail never matched, and a renamed skill or script outlived its rename on exactly the
# machines this function exists for. ~/.oh-my-zsh/custom/themes is a sixth exception whenever ZSH_CUSTOM moves
# the DESTINATION, because the source under home/ does not move with it.
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

# remove_retired_links: link() only knows the names the repo uses today, so a link an earlier run made
# under a name that has since been renamed away is never revisited and dangles forever — a rerun just adds
# the new link beside it. That is how ~/.oh-my-zsh/custom/themes/max.zsh-theme outlived its rename to
# workstation.zsh-theme, leaving oh-my-zsh looking for a theme that was already gone; `wt update` reruns
# this script, so every later rename would litter every machine the same way.
# Three things together make an entry ours to retire: it is a symlink, its target no longer exists, and it is
# ours by our_link — into this repo, or into the same source path under a root this clone has since moved
# away from, so a rename does not strand the retired names either. Anything else dangling here belongs to the
# user and is left strictly alone, as is every live link. Depth 1, and only the directories the linking steps
# above write into: $HOME is never walked recursively.
remove_retired_links() {
  local d e rel dirs
  dirs=("$HOME" "$HOME/.claude" "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex" \
        "$HOME/.local/bin" "$HOME/.config/cmux")
  if [[ -n $ZC_REL ]]; then
    dirs[${#dirs[@]}]="$ZC/themes"                       # where link_dotfiles actually put the theme; with
  fi                                                     # ZSH_CUSTOM set that is not ~/.oh-my-zsh/custom
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

# install_zsh_plugins: the two plugins ~/.zshrc enables, cloned once. Only that .zshrc names them, so without
# it there is nothing to clone — which also means a default install never touches the network at all.
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

# append_line: add one line to a file, keeping a hand-written last line that lacks its newline intact.
append_line() {
  local f="$1" line="$2"
  if [[ -s "$f" && -n "$(tail -c 1 "$f")" ]]; then
    printf '\n' >> "$f"
  fi
  printf '%s\n' "$line" >> "$f"
}

# ask_vm_host: on a VM, wt needs this host's alias from the Mac's ~/.ssh/config. The setup page runs
# WT_HOST=<vm> bash install.sh, so the answer never comes from stdin: read would otherwise eat the next
# line of a block pasted in one go. Asked in a terminal only when the variable is absent, then either way
# recorded in ~/.zshenv.local.
ask_vm_host() {
  if [[ $OS == Darwin ]] || grep -qs '^export WT_HOST=' "$HOME/.zshenv.local"; then
    return 0
  fi
  local h="${WT_HOST:-}"
  if [[ -z $h ]]; then
    if [[ ! -t 0 ]]; then
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
# cloned to ~/<repo>, so the home folder is recorded once, as the literal $HOME so any user's line works.
# shellcheck disable=SC2016
record_repos_dir() {
  if [[ $OS == Darwin ]] || grep -qs '^export WT_REPOS_DIR=' "$HOME/.zshenv.local"; then
    return 0
  fi
  append_line "$HOME/.zshenv.local" 'export WT_REPOS_DIR="$HOME"'
  echo 'WT_REPOS_DIR=$HOME written to ~/.zshenv.local (edit the line if repos live elsewhere)'
}

# require_plain_file <home-relative path>: the refusals every step that edits a file this repo does not own
# has to make about it. A dangling symlink: -f calls it false, and a redirection, an append or `git config`
# would write through it, somewhere outside $HOME. Anything that is not a regular file: a directory or a
# device in its place, which nothing below could read. A LIVE symlink is not a refusal here — each caller
# decides for itself, and the three that leave it to its dotfile manager say so at the point of the skip.
# Shared so that each step's check_… twin, which makes the same refusals early, cannot drift from its wording.
# Two entry points for one rule: most callers name a path under $HOME and want it spelled ~/… in the message,
# but git's global config file can sit at $XDG_CONFIG_HOME/git/config or wherever GIT_CONFIG_GLOBAL points,
# which need not be under $HOME at all, so that caller passes the absolute path and the label to print.
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

# check_zshenv_local: ask_vm_host and record_repos_dir append to ~/.zshenv.local, so it needs the same two
# refusals as the files the hooks append to — a dangling symlink there and append_line's >> creates the
# target, a file outside $HOME that nothing will ever read; a directory there and the append fails raw.
# A LIVE symlink is deliberately NOT a refusal, unlike ~/.tmux.conf: this is the machine-local overrides
# file, the two lines are machine-local facts (this VM's name, where its repos live) rather than anything
# this repo owns, both callers' grep reads back through the link so a rerun still adds nothing, and refusing
# would leave a VM whose ~/.zshenv.local is managed with no way to finish the install at all.
check_zshenv_local() {
  if [[ $OS == Darwin ]]; then
    return 0                           # neither caller writes the file on a Mac
  fi
  require_plain_file .zshenv.local
}

# BASHRC_SRC: the line hook_bashrc puts at the top of ~/.bashrc, without the trailing comment. It lives out
# here because check_bashrc has to make exactly the test hook_bashrc makes on it, and the two drifting is how
# check_bashrc came to refuse installs hook_bashrc would never have written to.
# shellcheck disable=SC2016
BASHRC_SRC='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'

# bashrc_hooked <path>: is our line already the FIRST line of that file? Then hook_bashrc returns having done
# nothing — it never reads the mode, never builds a temp file and never writes — so nothing downstream of that
# early return may refuse either.
bashrc_hooked() {
  local first
  [[ -f $1 && -r $1 ]] || return 1
  first="$(head -n 1 "$1")"
  [[ $first == "$BASHRC_SRC"* ]]       # whatever comment an older version of this script put after it
}

# check_bashrc: hook_bashrc runs seventh, long after files have moved, so its three refusals would land on a
# half-installed machine. They are made here instead, while nothing has been touched, with the same wording.
# A ~/.bashrc that is a live symlink is not a refusal: hook_bashrc skips it and says so at the point of the
# skip, so the warning is not buried under the whole install's output. Nor is a mode hook_bashrc will never
# copy: an image that ships a 664 ~/.bashrc (umask 002, user-private groups) is ordinary on a Linux VM, and
# once our line is at the top of it there is nothing left to rewrite — refusing there would fail this install,
# and so every `wt update`, forever, over a file this script was not going to touch.
check_bashrc() {
  local rc="$HOME/.bashrc" mode
  if [[ $OS == Darwin ]]; then
    return 0
  fi
  require_plain_file .bashrc           # the two refusals hook_bashrc shares with hook_tmux_conf
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

# hook_bashrc: cmux's remote tmux rows start every pane as bash with its own rcfile, which ends by sourcing
# ~/.bashrc, and never run zsh, so the linked ~/.zshenv is otherwise never read there. It is plain sh, so one
# line gives bash the same environment (PATH, WT_HOST, WT_REPOS_DIR) that a zsh session gets. The line goes
# at the very top: Ubuntu's ~/.bashrc returns on its fourth line when the shell is not interactive, and the
# bash sshd starts for `ssh <vm> '<cmd>'` does read ~/.bashrc, so a line further down never runs there and
# `wt -H <vm> …` fails. Nothing may depend on zsh on a VM anyway: an Azure ML compute instance resets the
# login shell to /bin/bash on every boot, so this one line carries the environment to every bash there.
# shellcheck disable=SC2016
hook_bashrc() {
  local src="$BASHRC_SRC"
  local rc="$HOME/.bashrc" line mode tmp target moved=0
  line="$src   # workstation: PATH, WT_HOST, WT_REPOS_DIR in cmux's bash rows"
  if [[ $OS == Darwin ]]; then
    return 0
  fi
  # check_bashrc made these refusals before anything moved; they stay here to cover the gap between the
  # two calls, and because nothing further down may run on a ~/.bashrc it cannot read.
  require_plain_file .bashrc
  if [[ -L $rc ]]; then               # a live link into a dotfiles repo: rewriting it here would put a regular
    target="$(readlink -f "$rc")"     # file in its place and orphan the target, so the repo would quietly stop
    {                                 # governing ~/.bashrc — a breakage the user only meets weeks later
      echo "skipped ~/.bashrc: it is a symlink to $target, left alone because a dotfile manager owns it."
      echo "add this yourself, as the FIRST line of $target:"
      echo "  $line"
      echo "until then 'wt -H <vm> …' fails: cmux's remote bash rows read ~/.bashrc, never ~/.zshenv."
    } >&2
    return 0
  fi
  if [[ ! -e $rc && ! -L $rc ]]; then   # -L as well as -e: only now is there really nothing there
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
                                                                                    # $rc is a regular file by here, so there is no link mode to read through
  if [[ ! $mode =~ ^[0-7]+$ ]]; then
    mode=""                            # stat said nothing usable: keep the 600 mktemp gives under this umask
  elif (( 8#$mode & 8#022 )); then     # never copy a group- or other-writable mode onto a file every login shell sources
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

# check_tmux_conf: check_bashrc's reasoning, for the other file this script adds a line to — hook_tmux_conf
# runs near the end, so its refusals are made here, while the machine is still untouched. Unlike
# check_bashrc this one is not Linux-only: cmux drives tmux on the Mac too.
check_tmux_conf() {
  if opted_in "$WITH_TMUX_CONF" .tmux.conf; then
    return 0                           # ~/.tmux.conf is about to become a link into this repo
  fi
  require_plain_file .tmux.conf
}

# hook_tmux_conf: tmux forwards to a pane only the variables named in update-environment, and cmux rebinds
# CMUX_SOCKET_PATH and CMUX_WORKSPACE_ID on every attach, so without the one line below a pane started in an
# already-running session gets a stale socket path and agent-notify goes nowhere. That line opens
# home/.tmux.conf, but the rest of that file is the author's taste, so when it was not asked for the line
# alone is APPENDED to the user's own ~/.tmux.conf (created if there is none). Appending, not rewriting:
# every line already there survives, which is why — unlike hook_bashrc, which has to rebuild ~/.bashrc to get
# its line above Ubuntu's early return — there is nothing here to stash and no mode to carry to a new file.
# `set -ag` appends to update-environment, so it cannot clobber a setting of the user's either.
hook_tmux_conf() {
  local line='set -ag update-environment " CMUX_SOCKET_PATH CMUX_WORKSPACE_ID"'
  local rc="$HOME/.tmux.conf"
  if opted_in "$WITH_TMUX_CONF" .tmux.conf; then
    return 0                          # the linked home/.tmux.conf already carries this line
  fi
  # check_tmux_conf made these refusals before anything moved; they stay here to cover the gap between the
  # two calls, and because nothing further down may run on a ~/.tmux.conf it cannot read.
  require_plain_file .tmux.conf
  if [[ -L $rc ]]; then               # a live link into a dotfiles repo: appending would write through it,
    {                                 # into a file that repo owns and rewrites — not ours to edit
      echo "skipped ~/.tmux.conf: it is a symlink to $(readlink "$rc"), left alone because a dotfile manager owns it."
      echo "add this line yourself, at the end of that file:"
      echo "  $line"
      echo "until then cmux's relay variables never reach panes started in a running tmux session."
    } >&2
    return 0
  fi
  if [[ ! -e $rc && ! -L $rc ]]; then   # -L as well as -e: only now is there really nothing there
    printf '%s\n' "$line" > "$rc"
    echo "created ~/.tmux.conf with the update-environment line cmux needs"
    return 0
  fi
  if awk -v s="$line" 'index($0, s) == 1 { found = 1 } END { exit !found }' "$rc"; then
    return 0                            # already there: only lines that START with it count, so a mention
  fi                                    # inside a comment is not mistaken for the setting
  append_line "$rc" "$line"
  echo "appended the update-environment line cmux needs to ~/.tmux.conf"
}

# CMUX_DST and the three fields of the one hook entry that is machinery. Out here because link_cmux_config,
# check_cmux_config, hook_cmux_config and the fragment they print must all name the same thing: cmux composes
# the hooks in file order and identifies them by "id", so an entry that differs in any field is a different
# entry, and a fragment that told the user to paste something else would be worse than no fragment at all.
CMUX_DST=.config/cmux/cmux.json
# shellcheck disable=SC2088   # the ~ is literal on purpose: cmux expands it itself, and the repo's file spells it so
CMUX_HOOK_CMD='~/.local/bin/cmux-hook'
CMUX_HOOK_ID=wt
CMUX_HOOK_TIMEOUT=20

# cmux_fragment: the entry, exactly as it appears in home/.config/cmux/cmux.json, for the user to paste when
# this script will not write the file itself.
cmux_fragment() {
  echo "      {"
  echo "        \"command\": \"$CMUX_HOOK_CMD\","
  echo "        \"id\": \"$CMUX_HOOK_ID\","
  echo "        \"timeoutSeconds\": $CMUX_HOOK_TIMEOUT"
  echo "      }"
}

# cmux_skip <first line> <the file to name>: every branch of hook_cmux_config that declines to write says the
# same things in the same order — what it will not do, what to paste instead, where in the array it goes, and
# what stays broken until it is pasted. One function so they cannot drift, and so a reader who has met one of
# these messages has met all of them. The id-collision branch is the one exception, and only because it has a
# fifth thing to say: which command it found under our id, which is the whole reason it stopped.
cmux_skip() {
  { echo "$1"
    echo "add this yourself, in the notifications.hooks array of $2, as its LAST entry:"
    cmux_fragment
    echo "cmux composes hooks in file order, so it goes after any hook of yours that suppresses a notification."
    echo "until then cmux's relay never reaches $CMUX_HOOK_CMD, so a wt row on a VM never attaches or opens."
  } >&2
}

# cmux_hook_state <file>: what a cmux.json that this script may write to already says about our entry.
#   invalid — not one JSON object: JSONC comments (which cmux allows and jq cannot parse) or a real syntax error
#   shape   — valid JSON, but .notifications or .notifications.hooks is not the type this merge needs
#   ours    — the entry is already there, command and all: nothing to do, and nothing to rewrite
#   foreign — an entry with our id that runs something else: the user's hook, which we may not overwrite
#   none    — no entry with our id: the one case that gets merged
# The validity probe is slurped on purpose: `jq -e .` exits 0 on an EMPTY file, having produced nothing, and
# the merge filter would then write an empty file over the user's. length == 1 also rejects a stream of two.
# shellcheck disable=SC2016   # the $id/$cmd/$h are jq's variables, passed in with --arg; they must not expand here
cmux_hook_state() {
  local f="$1"
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' "$f" >/dev/null 2>&1; then
    echo invalid
    return 0
  fi
  jq -r --arg id "$CMUX_HOOK_ID" --arg cmd "$CMUX_HOOK_CMD" '
    def hooks:
      if (.notifications | type) == "null" then "missing"
      elif (.notifications | type) != "object" then "bad"
      elif (.notifications | has("hooks") | not) then "missing"
      elif (.notifications.hooks | type) != "array" then "bad"
      else .notifications.hooks end;
    hooks as $h
    | if ($h | type) == "string" then (if $h == "bad" then "shape" else "none" end)
      else [$h[] | select((type == "object") and .id == $id)] as $m
           | if ($m | length) == 0 then "none"
             elif ([$m[] | select(.command == $cmd)] | length) > 0 then "ours"
             else "foreign" end
      end' "$f" 2>/dev/null || echo invalid
}

# check_cmux_config: check_tmux_conf's reasoning, for the fourth file this script writes into — and like that
# one it is only a refusal when the file is not about to become a link. hook_cmux_config runs near the end,
# so the two things it cannot read at all are refused here, while the machine is still untouched: a dangling
# symlink (jq would read nothing and the rewrite would land wherever it points, outside $HOME) and anything
# that is not a regular file. Mac only — there is no cmux on a VM, so there is nothing to refuse there.
# Everything else hook_cmux_config declines to do it declines in place, with cmux_skip, and the install goes on:
# a cmux.json with // comments in it is an ORDINARY cmux.json, so dying on one would fail this install, and
# with it every `wt update`, forever, over one hook entry — the trap check_bashrc's mode rule already names.
check_cmux_config() {
  if [[ $OS != Darwin ]]; then
    return 0
  fi
  if opted_in "$WITH_CMUX_CONFIG" "$CMUX_DST"; then
    return 0                           # ~/.config/cmux/cmux.json is about to become a link into this repo
  fi
  require_plain_file "$CMUX_DST"
}

# hook_cmux_config: hook_tmux_conf's job for cmux. cmux runs every hook in notifications.hooks on every
# notification, and ~/.local/bin/cmux-hook is how a `wt` row learns which workspace fired — without it
# `wt attach`/`wt open` on a VM row never happens. That entry lives in home/.config/cmux/cmux.json, but the
# other 275 lines of that file are the author's palette and hotkeys, so when it was not asked for the ENTRY
# alone is merged into the user's own ~/.config/cmux/cmux.json (created if there is none).
# Unlike hook_tmux_conf this is not an append: JSON has no such thing, so the whole file is rewritten, and it
# therefore follows copy_config's discipline instead — build the new file with jq first, stash the original
# only once that succeeded, then mv. A jq that fails can never truncate a file the user cares about.
# Appended, never prepended: order is semantic in that array (this repo's own file runs quiet-when-focused
# before wt), and keyed on the id, so a rerun finds its own entry and changes nothing.
# Four things it will not do, each said out loud rather than skipped quietly, because every one of them leaves
# the machinery uninstalled and the user with no other way to find that out:
#   a live symlink — a dotfile manager owns the file, and rewriting it would orphan the target (hook_tmux_conf
#     and configure_git make the same skip, for the same reason);
#   JSONC or broken — `cmux config check` accepts // comments and jq does not, so the file cannot be read,
#     let alone rewritten; the fragment is the whole answer here, which is why it is printed in full;
#   a shape this merge does not know — .notifications or .hooks of the wrong type;
#   an entry with id "wt" that runs something else — the user's own hook, and there is no safe answer:
#     overwriting loses it, and silently skipping leaves the relay dead. So it is named and left alone.
# shellcheck disable=SC2016   # as in cmux_hook_state: $cmd/$id/$t are jq variables passed with --arg/--argjson
# shellcheck disable=SC2088   # and the ~ in the "~/$CMUX_DST" labels is the spelling every message here uses
hook_cmux_config() {
  local rc="$HOME/$CMUX_DST" state tmp mode other
  if [[ $OS != Darwin ]]; then
    return 0                            # no cmux on a VM, so no file and nothing to merge into
  fi
  if opted_in "$WITH_CMUX_CONFIG" "$CMUX_DST"; then
    return 0                            # the linked home/.config/cmux/cmux.json already carries the entry
  fi
  # check_cmux_config made these refusals before anything moved; they stay here to cover the gap between the
  # two calls, and because nothing further down may run on a cmux.json it cannot read.
  require_plain_file "$CMUX_DST"
  if [[ -L $rc ]]; then
    cmux_skip "skipped ~/$CMUX_DST: it is a symlink to $(readlink "$rc"), left alone because a dotfile manager owns it." \
              "that file"
    return 0
  fi
  if [[ ! -e $rc && ! -L $rc ]]; then    # -L as well as -e: only now is there really nothing there
    mkdir -p "$(dirname "$rc")"
    { echo "{"
      echo "  \"schemaVersion\": 1,"
      echo "  \"notifications\": {"
      echo "    \"hooks\": ["
      cmux_fragment
      echo "    ]"
      echo "  }"
      echo "}"
    } > "$rc"
    echo "created ~/$CMUX_DST with the cmux-hook entry wt needs"
    echo "run 'cmux reload-config' (or relaunch cmux): a running cmux does not reread the file by itself"
    return 0
  fi
  state="$(cmux_hook_state "$rc")"
  case "$state" in
    ours)
      return 0 ;;                        # already merged, byte for byte: a rerun writes nothing at all
    invalid)
      if grep -qE '^[[:space:]]*(//|/\*)' "$rc"; then
        cmux_skip "skipped ~/$CMUX_DST: it has // comments in it (JSONC, which cmux accepts and jq cannot parse), so this script will not rewrite it." \
                  "~/$CMUX_DST"
      else
        cmux_skip "skipped ~/$CMUX_DST: jq cannot parse it, so this script will not rewrite it (run 'cmux config check' to see what is wrong)." \
                  "~/$CMUX_DST"
      fi
      return 0 ;;
    foreign)
      other="$(jq -r --arg id "$CMUX_HOOK_ID" \
        'first(.notifications.hooks[] | select((type == "object") and .id == $id)) | .command // "?"' \
        "$rc" 2>/dev/null || true)"
      { echo "skipped ~/$CMUX_DST: it already has a hook with id \"$CMUX_HOOK_ID\", and it runs ${other:-?}, not $CMUX_HOOK_CMD."
        echo "overwriting it would lose your hook, so this script changed nothing."
        echo "rename one of the two — the id is what cmux identifies a hook by — and rerun, or add this by hand:"
        cmux_fragment
        echo "until then cmux's relay never reaches $CMUX_HOOK_CMD, so a wt row on a VM never attaches or opens."
      } >&2
      return 0 ;;
    none)
      : ;;                               # the only case that is merged, below
    *)
      # "shape", and anything cmux_hook_state could not name. The merge filter below assumes .notifications
      # is an object and .hooks an array; when they are not, there is no rewrite that keeps what is there.
      cmux_skip "skipped ~/$CMUX_DST: its notifications.hooks is not a shape this script can merge into." \
                "~/$CMUX_DST"
      return 0 ;;
  esac
  tmp="$(mktemp "$rc.XXXXXX")"
  TMPFILES+=("$tmp")                     # the EXIT trap removes it if anything below fails
  if ! jq --arg cmd "$CMUX_HOOK_CMD" --arg id "$CMUX_HOOK_ID" --argjson t "$CMUX_HOOK_TIMEOUT" \
       '.notifications = (.notifications // {})
        | .notifications.hooks = ((.notifications.hooks // [])
            + [{"command": $cmd, "id": $id, "timeoutSeconds": $t}])' "$rc" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"                         # the original has not been touched: stash comes after this, not before
    cmux_skip "skipped ~/$CMUX_DST: jq could not rewrite it, so it is exactly as it was." "~/$CMUX_DST"
    return 0
  fi
  mode="$(stat -c %a "$rc" 2>/dev/null || stat -f %Lp "$rc" 2>/dev/null || true)"   # -c is GNU, -f is BSD
  if [[ $mode =~ ^[0-7]+$ ]]; then
    chmod "$mode" "$tmp"                 # the user's own file keeps its own mode, not mktemp's 600
  fi
  stash "$rc"                            # the backup contract applies here too: keep the original
  mv "$tmp" "$rc"
  echo "merged the cmux-hook entry into ~/$CMUX_DST (the file it replaces is in the backup dir)"
  echo "run 'cmux reload-config' (or relaunch cmux): a running cmux does not reread the file by itself"
}

# require_git_identity: commits need one, so this stays unconditional — ~/.gitconfig.local is where this repo
# puts it on every machine, opted in or not, because configure_git includes that file when ~/.gitconfig is
# not linked. It is read directly, not through git's own lookup, because on a first run the include does not
# exist yet; a user who already keeps an identity in their own ~/.gitconfig is not asked to move it.
require_git_identity() {
  local email
  email="$(git config --file "$HOME/.gitconfig.local" user.email 2>/dev/null || true)"
  if [[ -z "$email" ]]; then
    email="$(git config --global user.email 2>/dev/null || true)"
  fi
  if [[ -z "$email" ]]; then
    echo "set user.name/user.email in ~/.gitconfig.local (see the setup page), then rerun" >&2
    exit 1
  fi
}

# resolve_git_global: WHICH file `git config --global` writes, which is not always ~/.gitconfig and so not
# always the file the two steps below have to guard. git's own order, confirmed against git 2.39: $GIT_CONFIG_GLOBAL
# if it is set; else ~/.gitconfig if it EXISTS (following the link, so a dangling one does not count); else
# $XDG_CONFIG_HOME/git/config — default ~/.config/git/config — if that exists; else ~/.gitconfig, created.
# Guarding ~/.gitconfig alone missed both refusals this script makes about the file: on a machine whose
# dotfile manager owns ~/.config/git/config and leaves no ~/.gitconfig, configure_git wrote two machine-local
# absolute paths straight through that manager's symlink — the one thing it promises not to do — and reported
# it as a change to a ~/.gitconfig that does not exist; and a directory there took the whole install down
# mid-way in git's voice ("unknown error occurred while reading the configuration files", exit 128), which is
# precisely what check_gitconfig exists to prevent. Resolved once, in main, before anything moves.
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

# check_gitconfig: check_tmux_conf's reasoning, for the third file this script writes into. configure_git
# runs near the end, and `git config --global` makes its own refusals there in git's voice, mid-install,
# after everything has moved: a dangling target is "error: could not lock config file", exit 255, and
# a directory is "fatal: unknown error occurred while reading the configuration files", exit 128. Made here
# instead, while the machine is still untouched, in this script's wording, and about $GITRC rather than
# ~/.gitconfig, because that is the file git will open.
check_gitconfig() {
  if opted_in "$WITH_GITCONFIG" .gitconfig; then
    return 0                           # ~/.gitconfig is about to become a link into this repo, and git prefers
  fi                                   # it over the XDG file as soon as it exists
  require_plain_path "$GITRC" "$GITRC_LABEL"
}

# configure_git: two settings of home/.gitconfig are machinery, not taste — core.excludesFile, which is what
# git-ignores .worktrees/ and so what makes `wt` invisible to git, and the ~/.gitconfig.local include, which is
# where the identity above lives. When that file was not opted in they are written into the user's own
# global config with `git config`, which edits in place and leaves every other line of it alone. That file is
# $GITRC, resolved above — usually ~/.gitconfig, but ~/.config/git/config on a machine that keeps it there,
# and never a path this script simply assumed. Silent unless it changes something, so a rerun (and
# `wt update`) says nothing.
configure_git() {
  local ex="$HOME/.gitignore_global" inc="$HOME/.gitconfig.local" rc="$GITRC" have found=0 v
  if opted_in "$WITH_GITCONFIG" .gitconfig; then
    return 0                           # the linked home/.gitconfig carries both settings
  fi
  # check_gitconfig made these refusals before anything moved; they stay here to cover the gap between the
  # two calls, and because `git config` below would write through whatever is at $GITRC.
  require_plain_path "$rc" "$GITRC_LABEL"
  if [[ -L $rc ]]; then               # a live link into a dotfiles repo: `git config --global` follows it
    {                                 # and edits the file that repo owns and syncs — not ours to edit, and
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
  # --type=path, not the raw string: a config that says `excludesFile = ~/.gitignore_global` — what this
  # repo's own home/.gitconfig writes — is the very value wanted, and comparing it raw warns about it forever.
  have="$(git config --global --get --type=path core.excludesFile 2>/dev/null || true)"
  if [[ -z $have ]]; then
    git config --global core.excludesFile "$ex"
    echo "set core.excludesFile = ~/.gitignore_global in $GITRC_LABEL (it is what git-ignores .worktrees/)"
  elif [[ $have != "$ex" ]]; then      # the user points it at their own file: replacing it would silently drop
    {                                  # every rule in that file, so say what is missing instead
      echo "kept core.excludesFile = $have: this repo did not change it."
      echo "add the lines of ~/.gitignore_global to that file, or .worktrees/ is not ignored."
    } >&2
  fi
  # include.path is multi-valued, so a plain `git config --global include.path …` is not idempotent in the way
  # core.excludesFile is: it would overwrite the one include the user already has, and refuse outright (exit 5)
  # once there are two. Read every value and --add only when ours is missing. --type=path expands a value
  # written as ~/… so it compares equal to the one written here.
  while IFS= read -r v; do
    if [[ $v == "$inc" ]]; then found=1; fi
  done < <(git config --global --get-all --type=path include.path 2>/dev/null || true)
  if (( ! found )); then
    git config --global --add include.path "$inc"
    echo "added include.path = ~/.gitconfig.local to $GITRC_LABEL (where your git identity lives)"
  fi
}

# report: the EXIT trap, armed once files start to move. Two jobs. It removes the half-built files the two
# mktemp steps leave behind when a signal arrives between building one and moving it into place — an EXIT
# trap runs on SIGINT and SIGTERM too, so without this a ^C mid-run orphans a ~/.claude/settings.json.XXXXXX
# for good. And it says where anything that was in the way ended up — but a die() reaches it just as a
# finished run does, so it has to know which happened: $? at trap entry is still the status that is ending
# the script, so a failure gets a line that admits it instead of "done." printed under the error message.
report() {
  local rc=$?
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

# report_skipped: name the opinionated files this run did not install, and the flag that would. A default
# install deliberately leaves the user's own shell, git and tmux alone, and someone who wanted the author's
# prompt should not have to read this script to find out why it never arrived. --with-claude-ui is listed the
# same way, though what it leaves out is three keys of ~/.claude/settings.json rather than a file of its own,
# and so is --with-cmux-config, though what it leaves out is the rest of a file whose one machinery entry
# hook_cmux_config merged in anyway.
# Deliberately not part of report(): that one is the EXIT trap and so also runs after a die(), where a list of
# optional extras would sit under a failure message and say nothing about it.
report_skipped() {
  local f=""
  opted_in "$WITH_ZSHRC"       .zshrc                          || f="$f --with-zshrc"
  opted_in "$WITH_GITCONFIG"   .gitconfig                      || f="$f --with-gitconfig"
  opted_in "$WITH_TMUX_CONF"   .tmux.conf                      || f="$f --with-tmux-conf"
  opted_in "$WITH_KEYBINDINGS" .claude/keybindings.json        || f="$f --with-keybindings"
  opted_in "$WITH_STATUSLINE"  .claude/statusline-command.sh   || f="$f --with-statusline"
  if [[ $OS == Darwin ]]; then         # on a VM there is no cmux, so the flag is not something to offer
    opted_in "$WITH_CMUX_CONFIG" "$CMUX_DST"                   || f="$f --with-cmux-config"
  fi
  claude_ui_opted_in                                           || f="$f --with-claude-ui"
  if [[ -n $f ]]; then
    echo "left alone (the author's own taste, not machinery):$f"
    echo "rerun with those flags, or --opinionated-config for all of them, to install them"
  fi
}

main() {
  parse_args "$@"
  BK="$HOME/.workstation-backup/$(date +%Y%m%d-%H%M%S)-$$"   # timestamp+pid: same-second reruns cannot collide
  # Everything that can refuse runs first, while the machine is still untouched: a half-install that
  # then says "set user.name … and rerun" leaves the user with displaced files and no idea where. Every
  # refusal, including the later steps' check_… twins, therefore comes before the FIRST write of any kind
  # — the two ~/.zshenv.local lines below used to be made in among them, so a run that went on to refuse
  # had already edited a file class 3 promises is never rewritten, and had no trap yet to say so.
  # Two facts that have to be read while the machine is still as the LAST run left it. ~/.zshenv is re-pointed
  # by link_dotfiles, after which no dangling sibling can be matched against the root it used to carry; and
  # which file `git config --global` writes depends on whether ~/.gitconfig exists, which this run may change.
  read_zshenv_root
  resolve_git_global
  require_oh_my_zsh
  require_jq
  require_git_identity
  check_zshenv_local # Linux only — the file the next two steps append to
  check_bashrc       # Linux only — hook_bashrc's refusals, made while ~/.bashrc is still the only thing at stake
  check_tmux_conf    # the same, for the ~/.tmux.conf hook_tmux_conf appends to on both platforms
  check_gitconfig    # the same, for the ~/.gitconfig configure_git writes two settings into
  check_cmux_config  # Mac only — the same, for the cmux.json hook_cmux_config merges one entry into
  ask_vm_host        # Linux only — rejects an unusable VM name before anything moves
  record_repos_dir   # Linux only
  trap 'exit 130' INT    # so $? at report's entry is the signal's status, not the last command's
  trap 'exit 143' TERM
  trap report EXIT   # from here on files move, so always say where the originals went
  make_dirs
  install_bins
  link_dotfiles
  install_configs
  link_skills
  link_cmux_config
  remove_retired_links  # after every linking step, so this run's links exist and are live; before the two
                        # steps that can fail, so a rerun still tidies up even without a network or a ~/.bashrc
  hook_bashrc        # Linux only
  configure_git      # the three fallbacks for the files that were not opted in: after the linking steps, so
  hook_tmux_conf     # what they look at is this run's final state, and each no-ops when the link was made
  hook_cmux_config   # instead (hook_cmux_config on a VM too, where there is no cmux at all)
  install_zsh_plugins   # last: the only step that needs the network, so an offline VM still gets the rest
  report_skipped     # after every step, so it lists what is still missing rather than what was about to arrive
}

main "$@"
