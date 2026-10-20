#!/usr/bin/env sh
# Check the requested repository and agent in the VM's non-interactive shell.
PATH="$HOME/.local/bin:$PATH"; export PATH
test -x "$HOME/.local/bin/wt" || { echo "remote wt is missing" >&2; exit 1; }
# WT_COMPAT: Remove when every VM supports wt version.
version=$("$HOME/.local/bin/wt" version 2>/dev/null) || version='{"commit":null,"protocol":null}'
printf '%s\n' "$version"
repo=$1
if [ -n "$repo" ]; then
  "$HOME/.local/bin/wt" repos "$repo" >/dev/null || exit 1
fi
command -v tmux >/dev/null 2>&1 || { echo "remote tmux is missing" >&2; exit 1; }
agent=$2
[ -n "$agent" ] || agent=${WT_AGENT:-claude}
case "$agent" in none) ;; claude|codex) command -v "$agent" >/dev/null 2>&1 || { echo "remote agent is missing: $agent" >&2; exit 1; } ;; *) echo "invalid remote agent: $agent" >&2; exit 1 ;; esac
