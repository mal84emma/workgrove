#!/usr/bin/env bash
# Prove which tmux client the row shows.
session=$1 nonce=$2
clients=$(tmux list-clients -t "$session" -F '#{client_pid} #{client_tty}' 2>/dev/null) || exit 1
[ -n "$clients" ] || exit 2
[[ "$clients" =~ ^[0-9]+[[:space:]]+/dev/pts/[0-9]+$ ]] || exit 2
tmux display-message -d 5000 -t "$session:" "$nonce" || exit 1
printf '%s\n' "$clients"
