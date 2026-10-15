#!/usr/bin/env bash
# Replace the proven tmux client.
session=$1 expected=$2 line=$3
clients=$(tmux list-clients -t "$session" -F '#{client_pid} #{client_tty}' 2>/dev/null) || exit 1
[[ "$clients" == "$expected" ]] || exit 2
tmux detach-client -t "${clients#* }" -E "$line"
