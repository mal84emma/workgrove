# shellcheck shell=bash
# Reads globals: HOME.
# Requires no functions from other modules.
# shellcheck disable=SC2153
# ---------------------------------------------------------------- wt task
task_exit() { # the launcher row closes on exit, so give the user time to read a message first
  local rc=$1
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
