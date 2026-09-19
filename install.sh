#!/usr/bin/env bash
# Install this repo into $HOME. Existing files are backed up, never deleted. Run: bash ~/repos/workstation/install.sh
set -euo pipefail
umask 077
R="$(cd "$(dirname "$0")" && pwd)"; OS="$(uname -s)"; REFRESH=0
[[ ${1:-} == --refresh-config ]] && { REFRESH=1; shift; }
[[ $# -eq 0 ]] || { echo "usage: install.sh [--refresh-config]" >&2; exit 2; }
BK="$HOME/.workstation-backup/$(date +%Y%m%d-%H%M%S)-$$"   # timestamp+pid: same-second reruns cannot collide
bk() { mkdir -p "$BK/$(dirname "${1#"$HOME"/}")"; }         # created lazily, so a no-op run leaves no empty dir
stash() { [[ -e "$1" || -L "$1" ]] || return 0; bk "$1"; mv "$1" "$BK/${1#"$HOME"/}"; }
link() { # link <repo-relative> <home-relative>
  local src="$R/$1" dst="$HOME/$2"
  [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]] && return 0
  mkdir -p "$(dirname "$dst")"; stash "$dst"; ln -s "$src" "$dst"; echo "linked ~/$2"
}
copy_config() { # copy_config <repo-relative-base> <home-relative> <claude|plain>
  local src="$R/$1" dst="$HOME/$2" kind=$3
  if [[ -e "$dst" && ! -L "$dst" && $REFRESH -eq 0 ]]; then echo "kept ~/$2 (install.sh --refresh-config replaces it)"; return 0; fi
  mkdir -p "$(dirname "$dst")"; stash "$dst"
  if [[ $kind == claude && $OS != Darwin ]]; then jq 'del(.voice, .voiceEnabled)' "$src" >"$dst"   # voice needs a local mic
  else cp "$src" "$dst"; fi
  chmod 600 "$dst"; echo "installed ~/$2"
}
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] || { echo "install oh-my-zsh first (docs/new-$([[ $OS == Darwin ]] && echo mac || echo vm).md)" >&2; exit 1; }
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills" "$HOME/.codex" "$HOME/.agents/skills" "$HOME/Documents/Repositories"
for b in wt agent-notify cmux-hook; do stash "$HOME/bin/$b"; link "bin/$b" ".local/bin/$b"; done   # ~/bin is first on PATH
for f in .zshenv .zshrc .gitconfig .gitignore_global .tmux.conf \
         .claude/AGENTS.md .claude/CLAUDE.md .claude/keybindings.json .claude/statusline-command.sh \
         .oh-my-zsh/custom/themes/workstation.zsh-theme; do link "home/$f" "$f"; done
copy_config home/.claude/settings.base.json .claude/settings.json claude
copy_config home/.codex/config.base.toml   .codex/config.toml    plain
copy_config home/.codex/hooks.base.json    .codex/hooks.json     plain
for d in "$R"/home/.agents/skills/*/; do n=$(basename "$d")
  link "home/.agents/skills/$n" ".agents/skills/$n"; link "home/.agents/skills/$n" ".claude/skills/$n"; done
link home/.claude/AGENTS.md .codex/AGENTS.md
[[ $OS == Darwin ]] && link home/.config/cmux/cmux.json .config/cmux/cmux.json
ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
for p in zsh-autosuggestions zsh-syntax-highlighting; do
  [[ -d "$ZC/plugins/$p" ]] || git clone -q --depth 1 "https://github.com/zsh-users/$p" "$ZC/plugins/$p"; done
if [[ $OS != Darwin ]] && ! grep -qs '^export WT_HOST=' "$HOME/.zshenv.local"; then   # VMs: this host's alias on the Mac
  [[ -t 0 ]] || { echo "WT_HOST unset: run install.sh in a terminal so it can ask for the VM name" >&2; exit 1; }
  read -r -p "Name of this VM exactly as in the Mac's ~/.ssh/config (e.g. dev-a): " h
  [[ $h =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid or blank name: '$h'" >&2; exit 1; }
  printf 'export WT_HOST=%s\n' "$h" >> "$HOME/.zshenv.local"; echo "WT_HOST=$h written to ~/.zshenv.local"
fi
[[ -n "$(git config --file "$HOME/.gitconfig.local" user.email 2>/dev/null)" ]] ||
  { echo "set user.name/user.email in ~/.gitconfig.local (see the setup page), then rerun" >&2; exit 1; }
[[ -d $BK ]] && echo "done. backups in $BK" || echo "done. nothing needed backing up"
