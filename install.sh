#!/usr/bin/env bash
#
# install.sh: install this repo into $HOME.
#   bash ~/repos/workstation/install.sh [--refresh-config]   (on a VM, prefix WT_HOST=<vm>)
#
# Idempotent: rerun it whenever the repo changes. Nothing is ever deleted; anything in the way is
# moved into ~/.workstation-backup/<YYYYmmdd-HHMMSS>-<pid>, created only if it is actually needed
# (a no-op run leaves no empty directory behind).
#
# Three classes of file:
#   1. Stable files — shell/git/tmux dotfiles, the Claude and Codex instructions, the skills, the
#      bin/ scripts, cmux.json — are SYMLINKED out of this repo, so edits (including an agent's)
#      land in the repo and `git diff` is the review.
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
# Exits 2 on a usage error, 1 if oh-my-zsh, the VM name (Linux) or a git identity is missing.
set -euo pipefail
umask 077

R="$(cd "$(dirname "$0")" && pwd)"   # this repo
OS="$(uname -s)"
REFRESH=0                            # set by --refresh-config
BK=""                                # this run's backup dir; filled in by main

# parse_args <script args…>: the only argument accepted is --refresh-config.
parse_args() {
  if [[ ${1:-} == --refresh-config ]]; then
    REFRESH=1
    shift
  fi
  if [[ $# -ne 0 ]]; then
    echo "usage: install.sh [--refresh-config]" >&2
    exit 2
  fi
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

# copy_config <repo-relative .base> <home-relative dst> <claude|plain>: install one machine-local
# copy, keeping an existing real file unless --refresh-config was given. Kind "claude" drops the
# voice keys off a Mac, because a VM has no local microphone. A replaced copy is only ever stashed,
# never merged: a refreshed .codex/config.toml loses the tables Codex wrote into it (hook trust,
# folder trust), which the old file in the backup dir still holds and /hooks restores.
copy_config() {
  local src="$R/$1" dst="$HOME/$2" kind="$3"
  if [[ -e "$dst" && ! -L "$dst" && $REFRESH -eq 0 ]]; then
    echo "kept ~/$2 (install.sh --refresh-config replaces it)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  stash "$dst"
  if [[ $kind == claude && $OS != Darwin ]]; then
    jq 'del(.voice, .voiceEnabled)' "$src" >"$dst"
  else
    cp "$src" "$dst"
  fi
  chmod 600 "$dst"
  echo "installed ~/$2"
}

# require_oh_my_zsh: the linked ~/.zshrc needs it, so stop early and name the setup page.
require_oh_my_zsh() {
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
    stash "$HOME/bin/$b"
    link "bin/$b" ".local/bin/$b"
  done
}

# link_dotfiles: the stable shell, git, tmux, Claude and theme files.
link_dotfiles() {
  local f
  for f in .zshenv .zshrc .gitconfig .gitignore_global .tmux.conf \
           .claude/AGENTS.md .claude/CLAUDE.md .claude/keybindings.json .claude/statusline-command.sh \
           .oh-my-zsh/custom/themes/workstation.zsh-theme; do
    link "home/$f" "$f"
  done
}

# install_configs: the three mutable files, copied from their .base versions.
install_configs() {
  copy_config home/.claude/settings.base.json .claude/settings.json claude
  copy_config home/.codex/config.base.toml    .codex/config.toml    plain
  copy_config home/.codex/hooks.base.json     .codex/hooks.json     plain
}

# link_skills: each skill is linked twice — Codex reads ~/.agents/skills, Claude only ~/.claude/skills —
# and Codex takes the shared instructions from ~/.codex/AGENTS.md.
link_skills() {
  local d n
  for d in "$R"/home/.agents/skills/*/; do
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

# install_zsh_plugins: the two plugins ~/.zshrc enables, cloned once.
install_zsh_plugins() {
  local zc="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}" p
  for p in zsh-autosuggestions zsh-syntax-highlighting; do
    if [[ ! -d "$zc/plugins/$p" ]]; then
      git clone -q --depth 1 "https://github.com/zsh-users/$p" "$zc/plugins/$p"
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

# hook_bashrc: cmux's remote tmux rows start every pane as bash with its own rcfile, which ends by sourcing
# ~/.bashrc, and never run zsh, so the linked ~/.zshenv is otherwise never read there. It is plain sh, so one
# line gives bash the same environment (PATH, WT_HOST, WT_REPOS_DIR) that a zsh session gets.
# shellcheck disable=SC2016
hook_bashrc() {
  local src='[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"'
  if [[ $OS == Darwin ]] || grep -qsF "$src" "$HOME/.bashrc"; then
    return 0
  fi
  append_line "$HOME/.bashrc" "$src   # workstation: PATH, WT_HOST, WT_REPOS_DIR in cmux's bash rows"
  echo "bash reads ~/.zshenv too (line added to ~/.bashrc): cmux rows on a VM run bash"
}

# require_git_identity: ~/.gitconfig.local is machine-local and hand-written; commits need it.
require_git_identity() {
  local email
  email="$(git config --file "$HOME/.gitconfig.local" user.email 2>/dev/null || true)"
  if [[ -z "$email" ]]; then
    echo "set user.name/user.email in ~/.gitconfig.local (see the setup page), then rerun" >&2
    exit 1
  fi
}

# report: where anything that was in the way ended up.
report() {
  if [[ -d "$BK" ]]; then
    echo "done. backups in $BK"
  else
    echo "done. nothing needed backing up"
  fi
}

main() {
  parse_args "$@"
  BK="$HOME/.workstation-backup/$(date +%Y%m%d-%H%M%S)-$$"   # timestamp+pid: same-second reruns cannot collide
  require_oh_my_zsh
  make_dirs
  install_bins
  link_dotfiles
  install_configs
  link_skills
  link_cmux_config
  install_zsh_plugins
  ask_vm_host        # Linux only
  record_repos_dir   # Linux only
  hook_bashrc        # Linux only
  require_git_identity
  report
}

main "$@"
