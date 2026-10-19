# shellcheck shell=bash
# shellcheck disable=SC2153
# ---------------------------------------------------------------- wt task
task_exit() { # the launcher row closes on exit, so give the user time to read a message first
  local rc=$?
  if [[ $rc -ne 0 && -t 0 ]]; then read -r -p 'press return' _ || true; fi
}

repo_menu() { # repo_menu [table] — lays out cmd_repos' "<name><tab><path>[<tab><tasks>]" lines.
              # Default: task picker rows "<name><tab><path><tab><display>". The display is the name padded
              # to the widest name, then a gray location. "table": the terminal listing. It has a gray header,
              # then name, task count ("-" for none) and location per repo. The location is "~" for this
              # home, then at most the three folders above the repo, never the repo itself.
  awk -F'\t' -v home="$HOME" -v table="${1:-}" -v grey=$'\033[90m' -v off=$'\033[0m' '
    function loc(p,   par, m, a) {   # the local home as "~", then the three folders above the repo, never the repo
      if (home != "" && index(p, home "/") == 1) p = "~" substr(p, length(home) + 1)
      par = p; sub(/\/[^\/]*$/, "", par)
      if (par == "") return "/"
      m = split(par, a, "/")
      if (m <= 3) return par
      return a[m-2] "/" a[m-1] "/" a[m]
    }
    { rn[NR] = $1; rp[NR] = $2; rt[NR] = $3; if (length($1) > w) w = length($1) }
    END {
      if (NR == 0) exit
      if (table != "") {
        if (w < 4) w = 4
        printf "%s%-" (w + 2) "s%-7s%s%s\n", grey, "NAME", "TASKS", "LOCATION", off
        for (j = 1; j <= NR; j++) {
          t = sprintf("%-7s", rt[j] == "0" ? "-" : rt[j]); if (rt[j] == "0") t = grey t off
          printf "%-" (w + 2) "s%s%s%s%s\n", rn[j], t, grey, loc(rp[j]), off
        }
        exit
      }
      fmt = "%s\t%s\t%-" (w + 2) "s%s%s%s\n"
      for (j = 1; j <= NR; j++) printf fmt, rn[j], rp[j], rn[j], grey, loc(rp[j]), off
    }
  '
}
pick() { # pick <prompt> [fzf args…] — a line of stdin, or whatever was typed (fzf --print-query: query, selection)
  local out rc=0 q s p="$1"; shift
  out=$(fzf --print-query --prompt "$p> " --height 40% --reverse "$@") || rc=$?
  [[ $rc -le 1 ]] || return 1                                   # 130: aborted
  q=$(printf '%s\n' "$out" | sed -n '1p'); s=$(printf '%s\n' "$out" | sed -n '2p')
  printf '%s' "${s:-$q}"
}

cmd_task() {
  mac_only task
  local where="" kind="" repo="" name="" brief="" asked=1 id out
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --where) [[ $# -ge 2 ]] || die "task: $1 needs local or a host"; where="$2"; shift 2 ;;
      -a|--agent) [[ $# -ge 2 ]] || die "task: $1 needs a kind"; kind="$2"; shift 2 ;;
      -r|--repo) [[ $# -ge 2 ]] || die "task: $1 needs a repo"; repo="$2"; shift 2 ;;
      -p|--prompt) [[ $# -ge 2 ]] || die "task: $1 needs a brief"; brief="$2"; asked=0; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "task: unknown option $1" ;;
    esac
  done
  trap task_exit EXIT
  have fzf || die "fzf not found (brew install fzf)"

  if [[ -z "$where" ]]; then where=$({ printf 'local\n'; ssh_hosts; } | pick where) || die "task: cancelled"; fi
  [[ -n "$where" ]] || die "task: no host picked"
  if [[ "$where" != local ]]; then
    valid_host "$where" || die "task: invalid host '$where' (an ssh alias: letters, digits, '.', '_' and '-')"
    if ! known_host "$where"; then
      warn "cmux will try '$where'; make sure 'ssh $where' works first. Requests from inside that VM (VS Code, new rows) need a Host entry."
    fi
  fi

  if [[ -z "$kind" ]]; then
    kind=$({ printf 'claude\ncodex\nrepo-shell\n'; [[ "$where" == local ]] || printf 'vm-shell\n'; } | pick kind) || die "task: cancelled"
  fi
  case "$kind" in
    claude|codex|repo-shell) ;;
    vm-shell) [[ "$where" != local ]] || die "task: vm-shell needs a VM; for a local shell pick repo-shell" ;;
    *) die "task: unknown kind '$kind' (claude, codex, repo-shell, vm-shell)" ;;
  esac

  if [[ "$kind" != vm-shell && -z "$repo" ]]; then
    local list sel                               # "<name><tab><path>": two folders can hold the same basename,
    if [[ "$where" == local ]]; then             # so the path column, not the name, starts the task
      list=$(cmd_repos) || exit 1                # cmd_repos has already said what is wrong; do not repeat it
      [[ -n "$list" ]] || die "task: no repos in WT_REPOS_DIR ($REPOS_PATH); clone one, or pass -r <path>"
    else
      list=$(remote_wt "$where" repos) || exit 1   # no flag: ssh gives the VM no terminal, so this is the plain form on any wt version
      [[ -n "$list" ]] || die "task: no repos on $where (see: wt -H $where repos)"
    fi
    sel=$(printf '%s\n' "$list" | repo_menu | pick repo --ansi --delimiter $'\t' --with-nth 3 --nth 1,3) \
      || die "task: cancelled"
    [[ -n "$sel" ]] || die "task: no repo picked"
    sel="${sel%$'\t'*}"; repo="${sel##*$'\t'}"   # the path column; a typed query has no tab and is taken as given
  fi
  if [[ "$kind" == claude || "$kind" == codex ]]; then       # the name is never known from the options
    read -r -p 'name (blank = from brief)> ' name || true
    name=$(tidy_name "$name"); [[ -z "$name" ]] || need_name "$name"   # a '-…' name would otherwise reach cmd_new as an option
    if [[ $asked -eq 1 ]]; then read -r -p 'brief> ' brief || true; fi
  fi

  case "$kind" in
    claude|codex)
      args=(-r "$repo" -a "$kind" -p "$brief")                # cmd_new validates the name and slugifies a blank one
      if [[ -n "$name" ]]; then args+=("$name"); fi
      if [[ "$where" == local ]]; then cmd_new "${args[@]}"
      else host_new "$where" "${args[@]}"; fi ;;
    repo-shell)
      if [[ "$where" == local ]]; then
        resolve_repo "$repo"; id=$(repo_id "$REPO")
        cmux_ok || die "cmux is not running; start cmux, then: wt task"
        out=$(cmux_create --name "$id shell" --description "$(row_tag)" --cwd "$REPO" 2>&1) \
          || die "cmux workspace create failed: $out"
        printf 'row: %s shell %s\n' "$id" "$(row_tag)"
      else
        id=$(repo_id "$repo")   # the VM's own wt resolves the name against its $WT_REPOS_DIR; on a failed
                                # lookup its error stays on screen and the pane keeps $HOME as its cwd
        remote_row "$where" "shell-$id" "$id shell" "" "d=\$(\"\$HOME/.local/bin/wt\" repos $(shell_join "$repo")) && cd \"\$d\"" shared
      fi ;;
    vm-shell) remote_row "$where" main shell "" "" shared ;;
  esac
}
