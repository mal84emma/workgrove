#!/bin/sh
# Claude Code status line: "HH:MM  Model (effort) [NN%]  .../last/three/path/components".
# One jq call, not four: this runs on every refresh, and the old cat/date/4×jq/awk pipeline measured
# 18.4 ms against 10.7 ms for this — and printed four identical parse errors into Claude Code's log
# whenever stdin was not JSON. 2>/dev/null now swallows the one that is left.
input=$(cat)
time=$(date +%H:%M)
fields=$(printf '%s' "$input" | jq -j '
  [ (.workspace.current_dir // "" | split("/")
      | if length > 3 then ".../" + (.[-3:] | join("/")) else join("/") end),
    (.model.display_name // ""),
    (.effort.level // ""),
    (.context_window.used_percentage // 0 | round | tostring + "%")
  ] | join("\u001f")' 2>/dev/null)
# \u001f (unit separator), not @tsv: tab is an IFS whitespace character, so runs of tabs collapse and
# empty fields vanish — on `{}` the percentage would land in the cwd slot. It also leaves any tab or
# newline inside a value literal rather than escaped. `jq -j` so there is no trailing newline to strip,
# and `tostring + "%"` stays inside jq so non-JSON input still prints "[]" and not "[%]".
# A heredoc, not <<<: /bin/sh is dash on the Ubuntu VMs.
IFS=$(printf '\037') read -r cwd model effort ctx <<EOF
$fields
EOF
[ -n "$effort" ] && model="$model ($effort)"
printf "%s  %s [%s]  %s" "$time" "$model" "$ctx" "$cwd"
