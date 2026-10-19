# shellcheck shell=bash
# Reads globals: CMUX_ERROR, CMUX_SSH_ATTEMPT_ID, CODEX_SANDBOX, HOME, PWD, REPO, REPOS_PATH,
#   ROW_SEP, WT_AGENT, WT_DIRNAME, WT_FS, WT_HOST, WT_REPOS_DIR, WT_TMPFILES.
# Requires cmux.sh: cmux_notify, cmux_ok, cmux_row_field, row_label.
# Requires common.sh: die, have, hook_safe_path, on_exit, repo_id, row_title, shell_join,
#   valid_host, valid_name, warn, wt_result, wt_session.
# Requires safety.sh: branch_landed.
REPOS_PATH="${WT_REPOS_DIR:-$HOME/Documents/Repositories}"   # ':'-separated, searched in order (see repos_entries)
# shellcheck disable=SC2034  # command defaults used by bin/wt
DEFAULT_AGENT="${WT_AGENT:-claude}"

cmux_require() {
  CMUX_ERROR=''
  "$@" || die "$CMUX_ERROR"
  [[ -z $CMUX_ERROR ]] || warn "$CMUX_ERROR"
  return 0
}

# Remove sidecar temp files when a command exits, including after a signal.
WT_TMPFILES=()
wt_cleanup() {
  if [[ ${#WT_TMPFILES[@]} -gt 0 ]]; then
    rm -f "${WT_TMPFILES[@]}"          # already moved into place: rm -f on a gone path is a no-op
  fi
}
on_exit wt_cleanup

# ---------------------------------------------------------------- which side of the ssh we are on
# In a cmux remote pane or on a machine that is not a Mac, is_remote is true.
# Then this machine hosts the worktrees and the Mac drives cmux. CMUX_SURFACE_ID is cleared inside remote
# tmux panes by design, so never test it.
is_remote() { [[ -n ${CMUX_SSH_ATTEMPT_ID:-} ]] || [[ $(uname -s) != Darwin ]]; }
mac_only()  { if is_remote; then die "wt $1: run this on the Mac"; fi; }

wt_host() { # this VM's alias in the Mac's ~/.ssh/config
  [[ -n "${WT_HOST:-}" ]] || die "WT_HOST is not set; on this VM: echo 'export WT_HOST=<alias>' >> ~/.zshenv.local"
  valid_host "$WT_HOST" || die "invalid WT_HOST '$WT_HOST'; fix it in ~/.zshenv.local"
  printf '%s' "$WT_HOST"
}

hook_ok_repo() { # both relayed bodies carry $REPO (wt-open sends a path inside it)
  hook_safe_path "$REPO" && return 0
  warn "the Mac hook rejects this repo path ($REPO); run the printed command by hand"; return 1
}

notify_mac() { # notify_mac <title> <key> <value> …  — JSON body, so paths with spaces survive
  local title="$1" args=() body; shift
  while [[ $# -gt 1 ]]; do args+=(--arg "$1" "$2"); shift 2; done
  body=$(jq -cn "${args[@]}" '$ARGS.named')
  cmux_notify "$title" "$body" || { warn "$CMUX_ERROR"; return 1; }
}

# Resolve the MAIN checkout root for a path. A linked worktree resolves back to its main checkout.
main_root_of() {
  local p="$1" common
  common=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ "$common" == */.git ]] || return 1          # bare repos are not supported
  printf '%s' "${common%/.git}"
}

: "${REPO:=}"      # main checkout root
: "${WT_DIRNAME:=}"
set_repo() { REPO=$(main_root_of "$1") || return 1; WT_DIRNAME=$(git -C "$REPO" config --get wt.dir 2>/dev/null || echo .worktrees); }
lookup_repo() { # uses a path as given; looks up a name along $WT_REPOS_DIR, where it must be in one folder only
  local want="${1:-}" hits
  if [[ -n "$want" ]]; then
    if [[ ! -d "$want" ]]; then
      hits=$(repo_matches "$want")
      [[ -n "$hits" ]] || die "repo not found: ${1} (see: wt repos)"
      [[ "$hits" == *$'\n'* ]] && die "repo name '${1}' is in more than one WT_REPOS_DIR folder ($(printf '%s' "$hits" | tr '\n' ' ')); pass the path instead"
      want="$hits"
    fi
    set_repo "$want" || die "not a git repo: $want"
  else
    set_repo "$PWD" || die "not inside a git repo; pass -r <repo> (a name in $REPOS_PATH, or a path)"
  fi
}
# every command that makes or reads a worktree needs a commit to branch from; a plain lookup does not
resolve_repo() { lookup_repo "${1:-}"; need_commits; }
need_commits() { git -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || die "$REPO has no commits yet (git -C $REPO commit --allow-empty -m init)"; }
wt_root()   { printf '%s/%s' "$REPO" "$WT_DIRNAME"; }
wt_path()   { printf '%s/%s/%s' "$REPO" "$WT_DIRNAME" "$1"; }
wt_meta()   { printf '%s/.git/wt/%s.json' "$REPO" "$1"; }
wt_prompt() { printf '%s/.git/wt/%s.prompt' "$REPO" "$1"; }
wt_started(){ printf '%s/.git/wt/%s.started' "$REPO" "$1"; }
wt_branch() { printf 'wt/%s' "$1"; }

# Identity. repo_id, row_title, wt_session and valid_name are in lib/workgrove/common.sh. attach_row in
# bin/cmux-hook tags the rows that it relays in the same format as row_tag, so keep the two byte-compatible.
where_am_i() { if is_remote; then printf '%s' "${WT_HOST:-remote}"; else printf 'local'; fi; }
row_tag() { # row_tag [host] [repo] — the row description: "@<host> · <repo>", or "@<host>" for a row with no repo
  printf '@%s' "${1:-$(where_am_i)}"
  if [[ -n "${2:-}" ]]; then printf '%s%s' "$ROW_SEP" "$(repo_id "$2")"; fi
}
need_name()  { valid_name "$1" || die "invalid name '$1' (lowercase letters, digits, _ and -, max 63, no '.')"; }
tidy_name()  { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/-/g'; }  # "Fix Auth" -> fix-auth; anything else must already be valid
valid_agent() { case "$1" in claude|codex|none) ;; *) die "unknown agent '$1' (use claude, codex or none)" ;; esac; }
valid_model() { local LC_ALL=C; [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*(\[[A-Za-z0-9._-]+\])?$ ]]; }
need_model()  { valid_model "$1" || die "invalid model '$1' (use letters, digits, ., _, -, /, @, : and an optional [suffix])"; }

slugify() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9' '-' \
    | sed 's/^-//; s/-$//' | cut -d- -f1-5 | cut -c1-48 | sed 's/-$//'
}

# $WT_REPOS_DIR is a search path like $PATH: entries in order, each one once, empty and missing ones skipped.
repos_entries() {
  local rest="$REPOS_PATH" d seen=""
  while [[ -n "$rest" ]]; do
    d="${rest%%:*}"
    case "$rest" in *:*) rest="${rest#*:}" ;; *) rest="" ;; esac
    while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done      # "$X/" and "$X" are the same folder
    [[ -n "$d" && -d "$d" ]] || continue
    case "$seen" in *":$d:"*) continue ;; esac
    seen="$seen:$d:"
    printf '%s\n' "$d"
  done
  return 0
}
need_repos_dir() { [[ -n "$(repos_entries)" ]] || die "repos dir not found: $REPOS_PATH (set WT_REPOS_DIR, or pass -r <repo>)"; }
repo_dirs() { # every git repo on the search path: entry order, sorted within an entry, unreadable and hidden folders skipped
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ -r "$d" ]] || { warn "skipping unreadable folder in WT_REPOS_DIR: $d"; continue; }
    { find "$d" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -exec test -d '{}/.git' ';' -print 2>/dev/null || true; } | sort
  done <<<"$(repos_entries)"
  return 0
}
repo_matches() { # repo_matches <name> -> the entries holding that repo, first entry first; hidden names never match
  local name="$1" d
  case "$name" in ""|*/*|.*) return 0 ;; esac
  while IFS= read -r d; do
    [[ -n "$d" && -d "$d/$name/.git" ]] && printf '%s\n' "$d/$name"
  done <<<"$(repos_entries)"
  return 0
}

default_base() {
  local ref b
  if ref=$(git -C "$REPO" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s' "$ref"; return
  fi
  for b in main master; do
    git -C "$REPO" show-ref -q --verify "refs/remotes/origin/$b" && { printf 'origin/%s' "$b"; return; }
    git -C "$REPO" show-ref -q --verify "refs/heads/$b" && { printf '%s' "$b"; return; }
  done
  # Fall back to the branch checked out here, or to the HEAD commit when HEAD is detached. Never use the
  # literal "HEAD": in every worktree it resolves to that worktree's own tip, so it compares a worktree with
  # itself.
  git -C "$REPO" symbolic-ref -q --short HEAD || git -C "$REPO" rev-parse HEAD
}

meta_get() { # meta_get <name> <key> — "" for a missing key, and for a key stored as null
  # `.[$k] // ""` looks correct but is not: // also fires on a stored `false`, which would then read as "".
  # has/tojson is exact. A non-string (a number, a bool) comes back as JSON, so `false` reads as "false".
  local f; f=$(wt_meta "$1"); [[ -f "$f" ]] || return 1
  jq -r --arg k "$2" 'if has($k) and .[$k] != null then .[$k] else "" end
                      | if type == "string" then . else tojson end' "$f"
}
meta_get_pair() { # meta_get_pair <name> <key> <key> — one read for fields used together on each launch/show
  local f; f=$(wt_meta "$1"); [[ -f "$f" ]] || return 1
  jq -r --arg a "$2" --arg b "$3" --arg fs "$WT_FS" '
    [.[$a], .[$b]] | map(if . == null then "" elif type == "string" then . else tojson end) | join($fs)' "$f"
}
meta_set() { # meta_set <name> key=value ...  — a key with no '=' is stored with an empty value
  # jq cannot write the file that it reads, so meta_set writes through a temp file. The mv also makes
  # meta_set crash-safe. The earlier json.dump(d, open(f,'w')) was not: an interrupted write used to truncate
  # the sidecar.
  # In jq, index("=") is null when there is no '=', and null+1 is 1. So the no-'=' arm is necessary: without
  # it, `meta_set x bare` would slice the key and store the wrong one.
  local f t; f=$(wt_meta "$1"); shift; mkdir -p "$(dirname "$f")"; t="$f.new.$$"
  WT_TMPFILES+=("$t")                    # a signal between the jq below and the mv would otherwise orphan it
  if ! { if [[ -f "$f" ]]; then cat "$f"; else printf '{}\n'; fi; } \
       | jq --indent 1 'reduce ($ARGS.positional[]) as $kv (.;
             ($kv | index("=")) as $i
             | if $i == null then .[$kv] = "" else .[$kv[0:$i]] = $kv[$i+1:] end)' --args "$@" >"$t" \
     || ! mv "$t" "$f"; then
    rm -f "$t"; die "could not write $f"
  fi
}
prompt_line() { local f; f=$(wt_prompt "$1"); if [[ -f "$f" ]]; then head -1 "$f"; fi; }

require_wt() { # require_wt <name> <path output> <branch output> <command> requires a registered worktree.
  local -n __wt_path=$2 __wt_branch=$3
  local __n="$1"; valid_name "$__n" || die "invalid worktree name: $__n"
  __wt_path=$(wt_path "$__n"); __wt_branch=$(wt_branch "$__n")
  local __registered
  __registered=$(git -C "$REPO" worktree list --porcelain) || die "cannot list worktrees in $REPO"
  # A pipe to grep -q can fail under pipefail when a long list causes SIGPIPE.
  if grep -qxF "worktree $__wt_path" <<<"$__registered"; then
    # A registration whose directory was deleted outside wt (rm -rf, a lost VM disk) still has a branch and
    # metadata. Only `wt rm` can clear them, so let it through. The other commands find no files there.
    [[ -d "$__wt_path" ]] || warn "$__wt_path is registered but missing (deleted outside wt?); clean it up with: wt rm $__n"
    return 0
  fi
  [[ -d "$__wt_path" ]] && die "$__wt_path exists but is not a registered worktree (try: git -C $REPO worktree prune)"
  if [[ ${4:-} == path ]]; then wt_result path missing "$__n" "$REPO" >&2; fi
  die "no worktree named '$__n' in $REPO (see: wt list)"
}

task_title() { # task_title <name> [saved title] — the title of the task's row. No saved title: read the sidecar.
  # A title that an older wt saved ("<repo>:<name>") reads as the name, so the sidecar moves to the new form.
  local t="${2-}"
  if [[ $# -lt 2 ]]; then t=$(meta_get "$1" title 2>/dev/null || true); fi
  if [[ -z "$t" || "$t" == "$(repo_id "$REPO"):$1" ]]; then t=$(row_title "$1"); fi
  printf '%s' "$t"
}

check_identity() { # refuse a name whose row belongs to another repo with the same basename (same repo_id)
  local n="$1" other s
  if is_remote; then                  # this repo has no such worktree, so a live session belongs to another repo
    s=$(wt_session "$n" "$REPO")
    if tmux has-session -t "=$s" 2>/dev/null; then die "tmux session $s is already in use here; pick another name (or: tmux kill-session -t '=$s')"; fi
    return 0
  fi
  cmux_ok || return 0
  other=$(cmux_row_field "$(row_title "$n")" "$REPO" current_directory)
  [[ -n "$other" ]] || return 0
  other=$(main_root_of "$other" 2>/dev/null || printf '%s' "$other")   # resolved like $REPO; raw if the dir is gone
  [[ "$other" == "$REPO" || "$other" == "$REPO/"* ]] && return 0
  die "row '$(row_label "$(row_title "$n")" "$REPO")' already belongs to $other; pick another name (wt new <other-name> -r $REPO)"
}

physical_dir() { # physical_dir <dir> — the directory with each symlink resolved, or <dir> itself when it cannot be entered
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}
path_within() { [[ -n "$2" && ( "$1" == "$2" || "$1" == "$2/"* ) ]]; }   # path_within <path> <dir> — <dir> or below it

open_code() { # open_code <folder uri> <label>   (no --new-window: a repeat call focuses the window)
  have code || die "VS Code CLI 'code' not found (install it from VS Code: Shell Command: Install 'code' command in PATH)"
  # On the Mac, code hands the launch to a detached `open` and exits 0 whatever that does. Codex's sandbox
  # (which sets CODEX_SANDBOX) blocks Launch Services. So from inside that sandbox, no window opens and
  # nothing says so.
  [[ -z "${CODEX_SANDBOX:-}" ]] \
    || die "the Codex sandbox blocks app launches, so VS Code cannot open $2 from here; rerun this command with escalation"
  local err
  err=$(code --folder-uri "$1" 2>&1 >/dev/null) || die "VS Code did not open $2: code exited $?${err:+: $err}"
  printf 'opened in VS Code: %s\n' "$2"
}

open_worktree() { # open_worktree <name> <path> — VS Code here; from a VM ask the Mac to do it
  local path="$2"
  if ! is_remote; then open_code "file://$path" "$path"; return 0; fi
  local h manual; h=$(wt_host)
  manual="wt -H $h open -r $(shell_join "$REPO") $1"
  if ! hook_ok_repo || ! notify_mac wt-open host "$h" path "$path"; then
    printf 'VS Code request to the Mac failed. Run on the Mac: %s\n' "$manual"
    return 1
  fi
  printf 'requested VS Code on the Mac: %s:%s\n' "$h" "$path"
  printf 'if no window appears, run on the Mac: %s\n' "$manual"
}

request_row() { # request_row <name> — VM side: ask the Mac for a cmux row, and always print the recovery line
  local h; h=$(wt_host)
  if hook_ok_repo; then notify_mac wt-attach host "$h" repo "$REPO" task "$1" || true; fi
  printf 'on the Mac: wt -H %s attach -r %s %s\n' "$h" "$(shell_join "$REPO")" "$1"
}

session_state() { # session_state <name> — what the VM's tmux holds for this task, and whether a row holds that
  local s state=none t; s=$(wt_session "$1" "$REPO")
  if tmux has-session -t "=$s" 2>/dev/null; then
    state='shell only'
    while IFS= read -r t; do                           # the agent is a child of `wt run`, so it is never the pane's
      [[ -n "$t" ]] || continue                        # own command; everything on the pane's tty is what counts
      if pgrep -t "${t#/dev/}" -x 'claude|codex' >/dev/null 2>&1; then state='agent running'; break; fi
    done < <(tmux list-panes -s -t "=$s" -F '#{pane_tty}' 2>/dev/null)
    if [[ -z "$(tmux list-clients -t "=$s" 2>/dev/null)" ]]; then state="$state, detached"; fi
  fi
  printf '%s' "$state"
}

tmux_agent() { # tmux_agent <session> — 0 for a running agent, 1 for absent or idle, 2 for unreadable status.
  local err panes t rc=0
  err=$(LC_ALL=C tmux has-session -t "=$1" 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then
    case "$err" in
      "can't find session: =$1"|"can't find session: $1") return 1 ;;
      'no server running on '*|'error connecting to '*'(No such file or directory)') return 1 ;;
      *) printf '%s\n' "$err" >&2; return 2 ;;
    esac
  fi
  panes=$(tmux list-panes -s -t "=$1" -F '#{pane_tty}' 2>&1) || { printf '%s\n' "$panes" >&2; return 2; }
  [[ -n "$panes" ]] || return 2
  while IFS= read -r t; do
    [[ "$t" =~ ^/dev/(pts/[0-9]+|tty[[:alnum:]]+)$ ]] || return 2
    rc=0
    pgrep -t "${t#/dev/}" -x 'claude|codex' >/dev/null || rc=$?
    case $rc in 0) return 0 ;; 1) ;; *) return 2 ;; esac
  done <<<"$panes"
  return 1
}

# ---------------------------------------------------------------- status
wt_status_line() { # prints: name<US>branch<US>base<US>ahead<US>behind<US>dirty<US>last<US>merged<US>why
  local n="$1" p b base ahead behind dirty last merged='?' why=""
  p=$(wt_path "$n"); b=$(wt_branch "$n")
  base=$(meta_get "$n" base 2>/dev/null || true); [[ -n "$base" ]] || base=$(default_base)
  # Count against the BRANCH, not HEAD, because the column is labeled with the branch. In a worktree that is
  # mid-bisect or on a detached checkout, the two differ. That is the shape of the bug that wt rm had.
  ahead=$(git -C "$p" rev-list --count "$base..$b" 2>/dev/null || echo '?')
  behind=$(git -C "$p" rev-list --count "$b..$base" 2>/dev/null || echo '?')
  dirty=$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  last=$(git -C "$p" log -1 --format='%cr' 2>/dev/null || echo '-')
  local cur; cur=$(git -C "$p" branch --show-current 2>/dev/null || true)   # empty, exit 0, on a detached HEAD
  [[ -n "$cur" ]] || cur="$b (HEAD detached)"
  # merged, judged the way `wt rm` will judge it:
  # - "yes" when every commit is in the base (an ahead of 0 is exactly that);
  # - "squash" when the commits are not in the base but their work is (branch_landed, the check rm makes);
  # - "no", with the reason, otherwise;
  # - "?" when there is no base to compare with.
  # A squash-merged branch used to show as 2 ahead here, which reads as unmerged work. The worktree-show
  # skill also told agents to judge merged by a 0. This never fetches, because `wt list` is offline. So
  # right after a PR merges, the column says "no" until something refreshes the base. `wt rm`, `wt prune`
  # and `wt new` all refresh it. The AHEAD and BEHIND columns have always carried the same caveat. The
  # literal HEAD as a base resolves to the worktree's own tip and would read as 0 ahead. So a HEAD base
  # shows "?" here, as it is a refusal in rm_reasons.
  if [[ "$base" != HEAD && "$ahead" =~ ^[0-9]+$ ]]; then
    if [[ "$ahead" -eq 0 ]]; then merged=yes
    elif branch_landed "$b" "$base" why; then merged=squash
    else merged=no; fi
  fi
  printf '%s\n' "$n$WT_FS$cur$WT_FS$base$WT_FS$ahead$WT_FS$behind$WT_FS$dirty$WT_FS$last$WT_FS$merged$WT_FS$why"
}

list_names() { # registered worktrees under the wt root
  local root p; root=$(wt_root)
  while IFS= read -r p; do          # the prefix is stripped here, not by sed: a repo path may hold '#'
    [[ "$p" == "$root/"* ]] || continue
    p=${p#"$root/"}
    case "$p" in */*) continue ;; esac
    printf '%s\n' "$p"
  done < <(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')
  return 0
}

