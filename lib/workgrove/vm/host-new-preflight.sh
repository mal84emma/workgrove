#!/usr/bin/env sh
# Check the requested repository and agent in the VM's non-interactive shell.
PATH="$HOME/.local/bin:$PATH"; export PATH
test -x "$HOME/.local/bin/wt" || { echo "remote wt is missing" >&2; exit 1; }
# The Mac also supplies portable validation; older direct callers retain the existing checks.
if command -v wg_portable_preflight >/dev/null 2>&1; then
  wg_portable_preflight || exit 1
fi
# The Mac supplies version.sh before this script.
version=$(wt_vm_version)
printf '%s\n' "$version"
repo=$1
if [ -n "$repo" ]; then
  "$HOME/.local/bin/wt" repos "$repo" >/dev/null || exit 1
fi
command -v tmux >/dev/null 2>&1 || { echo "remote tmux is missing" >&2; exit 1; }
agent=$2
[ -n "$agent" ] || agent=${WT_AGENT:-claude}
case "$agent" in none) ;; claude|codex) command -v "$agent" >/dev/null 2>&1 || { echo "remote agent is missing: $agent" >&2; exit 1; } ;; *) echo "invalid remote agent: $agent" >&2; exit 1 ;; esac
