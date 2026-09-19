#!/bin/sh
input=$(cat)
time=$(date +%H:%M)
cwd=$(echo "$input" | jq -r '.workspace.current_dir' | awk -F/ '{n=NF; if (n>3) printf ".../%s/%s/%s", $(n-2), $(n-1), $n; else print $0}')
model=$(echo "$input" | jq -r '.model.display_name')
effort=$(jq -r '.effortLevel // ""' ~/.claude/settings.json 2>/dev/null)
[ -n "$effort" ] && model="$model ($effort)"
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // 0 | round | tostring + "%"')
printf "%s  %s [%s]  %s" "$time" "$model" "$ctx" "$cwd"
