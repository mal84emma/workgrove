#!/usr/bin/env bash
#
# install.sh: install this repo into $HOME.
#   bash ~/repos/workstation/install.sh [--refresh-config] [--opinionated-config]
#       [--with-zshrc] [--with-gitconfig] [--with-tmux-conf] [--with-keybindings] [--with-statusline]
#       [--with-claude-ui]
#   (on a VM, prefix WT_HOST=<vm>)
#
# Idempotent: rerun it whenever the repo changes. Nothing is ever deleted; anything in the way is
# moved into ~/.workstation-backup/<YYYYmmdd-HHMMSS>-<pid>, created only if it is actually needed
# (a no-op run leaves no empty directory behind).
#
# Three classes of file:
#   1. Stable files — shell/git/tmux dotfiles, the Claude and Codex instructions, the skills, the
#      bin/ scripts, cmux.json — are SYMLINKED out of this repo, so edits (including an agent's)
#      land in the repo and `git diff` is the review. Five of them are the author's taste rather than
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
# prompt, git config and tmux bindings, so the five files in class 1 that are taste rather than machinery
# arrive only when asked for — ~/.zshrc (and with it the oh-my-zsh theme, the oh-my-zsh prerequisite and the
# plugin clone that exist only to serve it) with --with-zshrc, ~/.gitconfig with --with-gitconfig,
# ~/.tmux.conf with --with-tmux-conf, ~/.claude/keybindings.json with --with-keybindings and
# ~/.claude/statusline-command.sh with --with-statusline.
# A sixth flag, --with-claude-ui, gates KEYS rather than a file: ~/.claude/settings.json is installed on every
# machine because its hooks and permissions are machinery, but .tui, .voice and .theme in it are the author's
# taste in the same way the five files are, so copy_config deletes them from the copy unless the flag is given.
# --opinionated-config turns on all six.
# The five file flags never have to be repeated: a destination that is already a link into this repo counts as
# asked for, so `wt update`, which reruns this script bare, keeps what an earlier run installed. --with-claude-ui
# has no such record to read — the keys live inside a COPIED file, not behind a symlink whose target says who
# made it — so it is not sticky and must be passed again every time the copy is written. That costs nothing in
# practice: a normal rerun keeps the existing ~/.claude/settings.json untouched, so only --refresh-config
# rewrites it, and only that run has to repeat the flag.
# Two of the five also carry settings the rest of this repo depends on, and declining the file does not
# decline those: without the linked ~/.gitconfig, `git config` puts core.excludesFile (what git-ignores
# .worktrees/) and the ~/.gitconfig.local include into the user's own file and changes nothing else; without
# the linked ~/.tmux.conf, its one update-environment line — how cmux's relay variables reach panes in an
# already-running session — is appended to the user's.
#
# Exits 2 on a usage error, 1 if oh-my-zsh (only when ~/.zshrc is opted in), the VM name (Linux) or a git
# identity is missing.
set -euo pipefail
umask 077

# -P, not a plain pwd: every link below records this path and opted_in reads it back, and `wt update`
# reruns this script from "$(cd "$(dirname "$s")/.." && pwd -P)". A clone reached through a symlinked path
# component would otherwise record one spelling from one entry point and the other from the other, and
# every link made under the first would read as "not ours" under the second.
R="$(cd "$(dirname "$0")" && pwd -P)"   # this repo
OS="$(uname -s)"
REFRESH=0                            # set by --refresh-config
WITH_ZSHRC=0                         # the five opinionated files, each set by its own --with-… flag
WITH_GITCONFIG=0
WITH_TMUX_CONF=0
WITH_KEYBINDINGS=0
WITH_STATUSLINE=0
WITH_CLAUDE_UI=0                     # the sixth: UI keys inside the copied ~/.claude/settings.json, not a file
BK=""                                # this run's backup dir; filled in by main
TMPFILES=()                          # half-built files; removed by report, which is the EXIT trap

# parse_args <script args…>: flags in any order and any combination — each --with-… adds one opinionated
# file (or, for --with-claude-ui, one group of keys), --opinionated-config is all six at once,
# --refresh-config is orthogonal to all of them.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-zshrc)         WITH_ZSHRC=1 ;;
      --with-gitconfig)     WITH_GITCONFIG=1 ;;
      --with-tmux-conf)     WITH_TMUX_CONF=1 ;;
      --with-keybindings)   WITH_KEYBINDINGS=1 ;;
      --with-statusline)    WITH_STATUSLINE=1 ;;
      --with-claude-ui)     WITH_CLAUDE_UI=1 ;;
      --opinionated-config) WITH_ZSHRC=1; WITH_GITCONFIG=1; WITH_TMUX_CONF=1
                            WITH_KEYBINDINGS=1; WITH_STATUSLINE=1; WITH_CLAUDE_UI=1 ;;
      --refresh-config)     REFRESH=1 ;;
      *)
        { echo "usage: install.sh [--refresh-config] [--opinionated-config]"
          echo "                  [--with-zshrc] [--with-gitconfig] [--with-tmux-conf]"
          echo "                  [--with-keybindings] [--with-statusline] [--with-claude-ui]"
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

# opted_in <flag> <home-relative dst>: does this run install that opinionated file? Either the flag asked for
# it, or ~/dst is ALREADY a link this script made, which is the record an earlier run's flag left: `wt update`
# reruns this script with no arguments, so a choice made once has to survive a run that cannot see it, and no
# state is stored anywhere for it to disagree with. On a machine where all five are already linked — every
# machine the author has — every answer is yes, so this whole opt-in changes nothing there.
# Only the five FILES can be asked this. --with-claude-ui gates keys inside a copied file, where there is no
# symlink destination to read the earlier answer back out of, so it is tested as a plain flag wherever it is
# used and no state file is invented to stand in for one.
opted_in() {
  if [[ $1 -eq 1 ]]; then
    return 0
  fi
  our_link "$HOME/$2" "home/$2"
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
# voice keys off a Mac, because a VM has no local microphone, and the .tui/.voice/.theme UI keys unless
# --with-claude-ui asked for them, because those are taste rather than machinery; kind "codex" drops the
# Keychain credential store off a Mac, because only macOS has one. The new file is built in full before the
# old one is stashed, so a filter that fails cannot leave a truncated ~/dst behind. A replaced copy is only ever stashed,
# never merged: a refreshed .codex/config.toml loses the tables Codex wrote into it (hook trust,
# folder trust), which the old file in the backup dir still holds and /hooks restores.
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
    if [[ $WITH_CLAUDE_UI -eq 0 ]]; then                  # UI taste, not machinery — the hooks and permissions
      filter="$filter | del(.tui, .voice, .theme)"        # around them stay on every machine. Composed with, not
    fi                                                    # instead of, the line above: del() of a key another
                                                          # del() already removed is a no-op, so .voice goes on a
                                                          # VM either way and the two tests stay independent.
    if ! opted_in "$WITH_STATUSLINE" .claude/statusline-command.sh; then
      filter="$filter | del(.statusLine)"                 # the script it names is opt-in: a command pointing at a
    fi                                                    # file that was never installed breaks the status line
    jq "$filter" "$src" >"$tmp" || { rm -f "$tmp"; die "jq failed on $1"; }
  elif [[ $kind == codex && $OS != Darwin ]]; then
    grep -v '^cli_auth_credentials_store' "$src" >"$tmp" || { rm -f "$tmp"; die "failed to filter $1"; }
  else
    cp "$src" "$tmp"
  fi
  chmod 600 "$tmp"
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
    link home/.oh-my-zsh/custom/themes/workstation.zsh-theme .oh-my-zsh/custom/themes/workstation.zsh-theme
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
link_cmux_config() {
  if [[ $OS == Darwin ]]; then
    link home/.config/cmux/cmux.json .config/cmux/cmux.json
  fi
}

# remove_retired_links: link() only knows the names the repo uses today, so a link an earlier run made
# under a name that has since been renamed away is never revisited and dangles forever — a rerun just adds
# the new link beside it. That is how ~/.oh-my-zsh/custom/themes/max.zsh-theme outlived its rename to
# workstation.zsh-theme, leaving oh-my-zsh looking for a theme that was already gone; `wt update` reruns
# this script, so every later rename would litter every machine the same way.
# Three things together make an entry ours to retire: it is a symlink, its target no longer exists, and it is
# ours by our_link — into this repo, or into the same home/<name> under a root this clone has since moved
# away from, so a rename does not strand the retired names either. Anything else dangling here belongs to the
# user and is left strictly alone, as is every live link. Depth 1, and only the directories the linking steps
# above write into: $HOME is never walked recursively.
remove_retired_links() {
  local d e rel
  for d in "$HOME" "$HOME/.claude" "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex" \
           "$HOME/.local/bin" "$HOME/.oh-my-zsh/custom/themes" "$HOME/.config/cmux"; do
    [[ -d "$d" ]] || continue                            # a directory this machine never got
    while IFS= read -r e; do
      [[ -e "$e" ]] && continue                          # live link: the repo still has the file
      rel="${e#"$HOME"/}"
      our_link "$e" "home/$rel" || continue              # points outside this repo: not ours to touch
      stash "$e"                                         # the backup contract holds here too: nothing is deleted
      echo "retired ~/$rel (the repo no longer has the file it pointed at)"
    done < <(find "$d" -maxdepth 1 -type l)              # -maxdepth 1: never descend into $HOME
  done
}

# install_zsh_plugins: the two plugins ~/.zshrc enables, cloned once. Only that .zshrc names them, so without
# it there is nothing to clone — which also means a default install never touches the network at all.
install_zsh_plugins() {
  local zc="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}" p
  if ! opted_in "$WITH_ZSHRC" .zshrc; then
    return 0
  fi
  for p in zsh-autosuggestions zsh-syntax-highlighting; do
    if [[ ! -d "$zc/plugins/$p" ]]; then
      echo "cloning the $p plugin that ~/.zshrc enables (needs the network)"
      git clone -q --depth 1 "https://github.com/zsh-users/$p" "$zc/plugins/$p" \
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
  if [[ $h == VM || ! $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then   # VM is the page's placeholder
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
require_plain_file() {
  local p="$HOME/$1"
  if [[ -L $p && ! -e $p ]]; then
    die "broken symlink at ~/$1 (-> $(readlink "$p")): remove or repair it, then rerun"
  fi
  if [[ -e $p && ! -L $p && ! -f $p ]]; then
    die "not a regular file: ~/$1; move it aside, then rerun"
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

# check_bashrc: hook_bashrc runs seventh, long after files have moved, so its three refusals would land on a
# half-installed machine. They are made here instead, while nothing has been touched, with the same wording.
# A ~/.bashrc that is a live symlink is not a refusal: hook_bashrc skips it and says so at the point of the
# skip, so the warning is not buried under the whole install's output.
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
  local src='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'
  local rc="$HOME/.bashrc" line first mode tmp target moved=0
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
  first="$(head -n 1 "$rc")"
  if [[ $first == "$src"* ]]; then                 # our line, whatever comment an older version put after it
    return 0
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
# already-running session gets a stale socket path and agent-notify goes nowhere. That line is the whole of
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

# check_gitconfig: check_tmux_conf's reasoning, for the third file this script writes into. configure_git
# runs near the end, and `git config --global` makes its own refusals there in git's voice, mid-install,
# after everything has moved: a dangling ~/.gitconfig is "error: could not lock config file", exit 255, and
# a directory is "fatal: unknown error occurred while reading the configuration files", exit 128. Made here
# instead, while the machine is still untouched, in this script's wording.
check_gitconfig() {
  if opted_in "$WITH_GITCONFIG" .gitconfig; then
    return 0                           # ~/.gitconfig is about to become a link into this repo
  fi
  require_plain_file .gitconfig
}

# configure_git: two settings of home/.gitconfig are machinery, not taste — core.excludesFile, which is what
# git-ignores .worktrees/ and so what makes `wt` invisible to git, and the ~/.gitconfig.local include, which is
# where the identity above lives. When that file was not opted in they are written into the user's own
# ~/.gitconfig with `git config`, which edits in place and leaves every other line of it alone. Silent unless
# it changes something, so a rerun (and `wt update`) says nothing.
configure_git() {
  local ex="$HOME/.gitignore_global" inc="$HOME/.gitconfig.local" rc="$HOME/.gitconfig" have found=0 v
  if opted_in "$WITH_GITCONFIG" .gitconfig; then
    return 0                           # the linked home/.gitconfig carries both settings
  fi
  # check_gitconfig made these refusals before anything moved; they stay here to cover the gap between the
  # two calls, and because `git config` below would write through whatever is at ~/.gitconfig.
  require_plain_file .gitconfig
  if [[ -L $rc ]]; then               # a live link into a dotfiles repo: `git config --global` follows it
    {                                 # and edits the file that repo owns and syncs — not ours to edit, and
      echo "skipped ~/.gitconfig: it is a symlink to $(readlink "$rc"), left alone because a dotfile manager owns it."
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
    echo "set core.excludesFile = ~/.gitignore_global in ~/.gitconfig (it is what git-ignores .worktrees/)"
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
    echo "added include.path = ~/.gitconfig.local to ~/.gitconfig (where your git identity lives)"
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
# same way, though what it leaves out is three keys of ~/.claude/settings.json rather than a file of its own.
# Deliberately not part of report(): that one is the EXIT trap and so also runs after a die(), where a list of
# optional extras would sit under a failure message and say nothing about it.
report_skipped() {
  local f=""
  opted_in "$WITH_ZSHRC"       .zshrc                          || f="$f --with-zshrc"
  opted_in "$WITH_GITCONFIG"   .gitconfig                      || f="$f --with-gitconfig"
  opted_in "$WITH_TMUX_CONF"   .tmux.conf                      || f="$f --with-tmux-conf"
  opted_in "$WITH_KEYBINDINGS" .claude/keybindings.json        || f="$f --with-keybindings"
  opted_in "$WITH_STATUSLINE"  .claude/statusline-command.sh   || f="$f --with-statusline"
  [[ $WITH_CLAUDE_UI -eq 1 ]]                                  || f="$f --with-claude-ui"
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
  require_oh_my_zsh
  require_jq
  require_git_identity
  check_zshenv_local # Linux only — the file the next two steps append to
  check_bashrc       # Linux only — hook_bashrc's refusals, made while ~/.bashrc is still the only thing at stake
  check_tmux_conf    # the same, for the ~/.tmux.conf hook_tmux_conf appends to on both platforms
  check_gitconfig    # the same, for the ~/.gitconfig configure_git writes two settings into
  ask_vm_host        # Linux only — rejects the page's VM placeholder before anything moves
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
  configure_git      # the two fallbacks for the files that were not opted in: after the linking steps, so
  hook_tmux_conf     # what they look at is this run's final state, and no-ops when the link was made instead
  install_zsh_plugins   # last: the only step that needs the network, so an offline VM still gets the rest
  report_skipped     # after every step, so it lists what is still missing rather than what was about to arrive
}

main "$@"
