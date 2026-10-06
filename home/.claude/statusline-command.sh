#!/bin/sh
# Claude Code status line: "HH:MM  Model (effort) [NN%]  .../last/three/path/components".
# One jq call, not four, because this runs on every refresh. The old cat/date/4×jq/awk pipeline
# measured 18.4 ms, against 10.7 ms for this one. It also printed four identical parse errors into
# Claude Code's log whenever stdin was not JSON. Now 2>/dev/null discards the one that is left.
input=$(cat)
time=$(date +%H:%M)
fields=$(printf '%s' "$input" | jq -j '
  [ (.workspace.current_dir // "" | split("/")
      | if length > 3 then ".../" + (.[-3:] | join("/")) else join("/") end),
    (.model.display_name // ""),
    (.effort.level // ""),
    (.context_window.used_percentage // 0 | round | tostring + "%")
  ] | join("\u001f")' 2>/dev/null)
# \u001f (unit separator), not @tsv: tab is an IFS whitespace character, so runs of tabs collapse
# and empty fields vanish. With @tsv and `{}` as input, the percentage would land in the cwd slot.
# \u001f also leaves any tab or newline inside a value as it is, not escaped. `jq -j` prints no
# trailing newline, so there is none to strip. `tostring + "%"` stays inside jq, so non-JSON
# input still prints "[]" and not "[%]".
# A heredoc, not <<<, because /bin/sh is dash on the Ubuntu VMs.
IFS=$(printf '\037') read -r cwd model effort ctx <<EOF
$fields
EOF
[ -n "$effort" ] && model="$model ($effort)"
printf "%s  %s [%s]  %s" "$time" "$model" "$ctx" "$cwd"
