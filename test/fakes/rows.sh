#!/usr/bin/env bash
# Build scenario data from the recorded cmux response shapes.
# shellcheck disable=SC2119,SC2120
FAKE_CMUX_FIXTURES=$(cd "${BASH_SOURCE[0]%/*}/../fixtures/cmux-0.65.1" && pwd -P)

fake_cmux_init() {
  export FAKE_CMUX_STATE=$1
  mkdir -p "$FAKE_CMUX_STATE/rows" "$FAKE_CMUX_STATE/fail" "$FAKE_CMUX_STATE/queue"
  : >"$FAKE_CMUX_STATE/calls.log"
  fake_rows >"$FAKE_CMUX_STATE/rows.json"
  fake_windows >"$FAKE_CMUX_STATE/windows.json"
}

# Supply a host to enable the remote fields of a recorded row.
fake_row() {
  jq -c --arg id "$1" --arg title "$2" --arg description "$3" \
    --arg host "${4:-}" --arg state "${5:-connected}" --arg backend "${6:-cmux-tui}" \
    --argjson slot "${7:-null}" '
    .workspaces[0] | .id=$id | .title=$title | .description=$description
    | .current_directory="" | .has_custom_title=true
    | .remote.enabled=($host != "") | .remote.destination=(if $host == "" then null else $host end)
    | .remote.state=(if $host == "" then "disconnected" else $state end)
    | .remote.backend=(if $host == "" then null else $backend end)
    | .remote.persistent_daemon_slot=$slot' "$FAKE_CMUX_FIXTURES/rows.json"
}

fake_rows() {
  jq -cn --slurpfile template "$FAKE_CMUX_FIXTURES/rows.json" \
    --argjson rows "$(printf '%s\n' "$@" | jq -sc '.')" '$template[0] | .workspaces=$rows'
}

fake_windows() {
  jq -cn --slurpfile template "$FAKE_CMUX_FIXTURES/windows.json" \
    --argjson ids "$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '$ids | to_entries | map(. as $entry | $template[0][0] | .id=$entry.value | .index=$entry.key)'
}

fake_failure() {
  mkdir -p "$(dirname "$FAKE_CMUX_STATE/fail/$1")"
  printf '%s\n%s' "$2" "${3:-}" >"$FAKE_CMUX_STATE/fail/$1"
}

fake_queue() {
  local key=$1 output=$2 status=${3:-0} error=${4:-} entry count=0
  mkdir -p "$FAKE_CMUX_STATE/queue/$key"
  for entry in "$FAKE_CMUX_STATE/queue/$key/"*; do
    [[ -d $entry ]] || continue
    count=$((10#${entry##*/} + 1))
  done
  printf -v entry '%s/queue/%s/%06d' "$FAKE_CMUX_STATE" "$key" "$count"
  mkdir -p "$entry"
  printf '%s' "$output" >"$entry/stdout"
  printf '%s' "$error" >"$entry/stderr"
  printf '%s\n' "$status" >"$entry/status"
}
