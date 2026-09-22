#!/bin/sh
input=$(cat)
time=$(date +%H:%M)
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' | awk -F/ '{n=NF; if (n>3) printf ".../%s/%s/%s", $(n-2), $(n-1), $n; else print $0}')
model=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
effort=$(printf '%s' "$input" | jq -r '.effort.level // empty')
[ -n "$effort" ] && model="$model ($effort)"
ctx=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // 0 | round | tostring + "%"')
printf "%s  %s [%s]  %s" "$time" "$model" "$ctx" "$cwd"
