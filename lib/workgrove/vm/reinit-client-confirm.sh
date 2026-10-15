#!/usr/bin/env bash
# Confirm the replacement tmux client.
session=$1 tty=$2 nonce=$3
clients=$(tmux list-clients -t "$session" -F '#{client_pid} #{client_tty}' 2>/dev/null) || exit 1
[[ "$clients" =~ ^[0-9]+[[:space:]]+/dev/pts/[0-9]+$ && "${clients#* }" == "$tty" ]] || exit 1
tmux display-message -d 5000 -t "$session" "$nonce"
