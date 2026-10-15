#!/usr/bin/env bash
# Check and clear one stale relay on a VM.
slot=$1
case "$slot" in ssh-[A-Za-z0-9-]*) ;; *) echo 'invalid relay slot' >&2; exit 1 ;; esac
# Without a keepalive a stale session holds its port for hours; the Mac warns. These files are world-readable.
if [ -r /etc/ssh/sshd_config ] && ! grep -qisE '^[[:space:]]*ClientAliveInterval[[:space:]=]+0*[1-9]' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then echo 'keepalive missing'; fi
port=''
for file in "$HOME"/.cmux/relay/*.slot; do
  [ -f "$file" ] || continue
  [ "$(cat "$file")" = "$slot" ] || continue
  candidate=${file##*/}; candidate=${candidate%.slot}
  case "$candidate" in *[!0-9]*|'') echo 'invalid relay port' >&2; exit 1 ;; esac
  [ -z "$port" ] || { echo 'multiple ports for relay slot' >&2; exit 1; }
  port=$candidate
done
[ -n "$port" ] || { echo 'relay slot file not found' >&2; exit 1; }
on_port() { # every listener on $port at any local address: field 4 after a State column, else field 3
  awk -v port="$port" '{ o = ($1 ~ /^[0-9]+$/) ? 0 : 1; n = split($(3 + o), a, ":"); if (n > 1 && a[n] == port) print }'
}
lines=$(ss -H -ltnp "sport = :$port") || { echo 'ss failed' >&2; exit 1; }
held=$(printf '%s\n' "$lines" | on_port)
if [ -z "$held" ]; then printf 'free %s\n' "$port"; exit 0; fi
if printf '%s\n' "$held" | grep -qv 'pid='; then
  # Some VMs hide even this user's sshd PID from unprivileged ss. Sudo is only for inspection.
  lines=$(sudo -n ss -H -ltnp "sport = :$port") || { echo "cannot inspect listener PID on $port" >&2; exit 1; }
  held=$(printf '%s\n' "$lines" | on_port)
fi
if [ -z "$held" ] || printf '%s\n' "$held" | grep -qv 'pid='; then echo "cannot identify one listener on $port" >&2; exit 1; fi
# One sshd may hold the port on IPv4 and IPv6 at once: one PID across every line, never one line.
pids=$(printf '%s\n' "$held" | grep -oE 'pid=[0-9]+' | sort -u)
[ "$(printf '%s\n' "$pids" | grep -c .)" -eq 1 ] || { echo "multiple listeners on $port" >&2; exit 1; }
pid=${pids#pid=}
# OpenSSH 9.8 and later run each session as sshd-session.
if printf '%s\n' "$held" | grep -qvF -e "\"sshd\",pid=$pid," -e "\"sshd-session\",pid=$pid,"; then
  echo "listener on $port is not sshd" >&2; exit 1
fi
case "$(ps -o comm= -p "$pid" | tr -d ' ')" in sshd|sshd-session) ;; *) echo "listener on $port is not a user-owned sshd" >&2; exit 1 ;; esac
[ "$(ps -o uid= -p "$pid" | tr -d ' ')" = "$(id -u)" ] || { echo "listener on $port is not a user-owned sshd" >&2; exit 1; }
# Stale means connected from an address the Mac no longer has. This call's own SSH_CONNECTION is the
# Mac's current address; a session from it may be live (a ControlMaster VS Code shares) and is refused.
[ -n "${SSH_CONNECTION:-}" ] || { echo "SSH_CONNECTION is empty, so sshd $pid holding relay port $port cannot be shown to be stale" >&2; exit 1; }
client_ip=${SSH_CONNECTION%% *}; server_port=${SSH_CONNECTION##* }
case "$server_port" in *[!0-9]*|'') echo "unexpected SSH_CONNECTION: $SSH_CONNECTION" >&2; exit 1 ;; esac
bare_ip() { a=${1#\[}; a=${a%\]}; printf '%s\n' "${a#::ffff:}"; }   # [addr], ::ffff:v4 and v4 compare equal
conns=$(ss -H -tnp state established "( sport = :$server_port )") || { echo 'ss failed' >&2; exit 1; }
conn=$(printf '%s\n' "$conns" | grep -F ",pid=$pid,")
if [ -z "$conn" ]; then   # hidden PIDs again; sudo only reads
  conns=$(sudo -n ss -H -tnp state established "( sport = :$server_port )") || conns=''
  conn=$(printf '%s\n' "$conns" | grep -F ",pid=$pid,")
fi
# `state established` drops ss's State column, so the peer is field 4, or 5 when a State column is there.
peer=$(printf '%s\n' "$conn" | awk '{ o = ($1 ~ /^[0-9]+$/) ? 0 : 1; print $(4 + o) }')
[ "$(printf '%s\n' "$conn" | grep -c .)" -eq 1 ] && [ -n "$peer" ] \
  || { echo "cannot find sshd $pid's SSH connection on port $server_port, so it cannot be shown to be stale" >&2; exit 1; }
peer=$(bare_ip "${peer%:*}"); here=$(bare_ip "$client_ip")
[ "$peer" != "$here" ] || { echo "sshd $pid holding relay port $port is connected from this Mac's current address ($here); it may still be live" >&2; exit 1; }
env kill -TERM "$pid" || { echo "could not stop sshd $pid on $port" >&2; exit 1; }
# shellcheck disable=SC2034
for attempt in 1 2 3 4 5; do
  lines=$(ss -H -ltnp "sport = :$port") || { echo 'ss failed after signal' >&2; exit 1; }
  held=$(printf '%s\n' "$lines" | on_port)
  [ -z "$held" ] && break
  sleep 1
done
[ -z "$held" ] || { echo "relay port $port is still held after signal" >&2; exit 1; }
printf 'stopped %s %s\n' "$port" "$pid"
