# shellcheck shell=bash
# lib/workgrove/common.sh — shell functions that more than one script in bin/ needs.
# bin/wt, bin/cmux-hook and bin/agent-notify source this file after they hand off to bash 5.
# This file needs bash 5. An older bash returns at the next line, before it parses the rest,
# so its source fails cleanly.
# Apart from that version check, this file only defines functions. It sets no shell options,
# so it works under the "set -euo pipefail" of bin/wt and under the "set -u" of the hooks.
if ((BASH_VERSINFO[0] < 5)); then return 1; fi

# valid_host <alias> — an ssh alias: letters, digits, '.', '_' and '-', with a letter or digit first.
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# The Mac hook (bin/cmux-hook) drops any other path, so never relay a path that fails this.
hook_safe_path() { [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *//* && "$1" != */ && "$1" != *'/../'* && "$1" != */.. && "$1" != *[\'\"\`\$\\\;]* ]]; }

# Identity. bin/wt and bin/cmux-hook take a task's row title, repo id and tmux session from these functions.
# A row's title tells which task it is. Its description (row_tag in bin/wt) tells which machine
# and which repo. Two repos can have tasks with the same name, so the title alone does not identify a row.
# attach_row in bin/cmux-hook writes the description of the rows that it relays in the same format as
# row_tag, so keep the two byte-compatible.
repo_id()    { printf '%s' "${1##*/}" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'; }
row_title()  { printf '%s' "$1"; }                                          # row_title <name> — a task row's title
wt_session() { printf 'wt-%s-%s' "$(repo_id "$2")" "$1"; }                  # wt_session <name> <repo>
# valid_name <name> — a task name: lowercase letters, digits, '_' and '-', max 63, no '.'.
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; }

ssh_hosts() { # non-wildcard Host aliases in ~/.ssh/config, one per line. known_host reads the same list.
  { awk '$1=="Host"{for(i=2;i<=NF;i++){if($i ~ /^#/)break; if($i !~ /^[!]/ && $i !~ /[*?]/) print $i}}' "$HOME/.ssh/config" 2>/dev/null || true; } | sort -u
}
# known_host <alias> — the alias is one that ssh_hosts prints. grep reads all its input (no -q),
# so sort never gets SIGPIPE, and the answer stays correct under pipefail.
known_host() { ssh_hosts | grep -xF -- "$1" >/dev/null; }
