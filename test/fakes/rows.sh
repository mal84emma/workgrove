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

fake_identity_root() {
  if [[ -n ${FAKE_CMUX_STATE:-} ]]; then printf '%s' "$FAKE_CMUX_STATE"
  elif [[ -n ${TEST_ROOT:-} ]]; then printf '%s/cmux-identities' "$TEST_ROOT"
  else printf 'fake identities need FAKE_CMUX_STATE or TEST_ROOT\n' >&2; return 64; fi
}

fake_identity_records() {
  local root document rows='[]' references='{}'
  local documents=()
  root=$(fake_identity_root) || return
  for document in "$root/rows.json" "$root/rows/"*.json; do
    [[ -f $document ]] && documents+=("$document")
  done
  if ((${#documents[@]})); then
    rows=$(jq -sc '[.[].workspaces[] | {id,ref}]' "${documents[@]}") || return
  fi
  if [[ -f $root/references.json ]]; then references=$(cat "$root/references.json"); fi
  jq -cn --argjson rows "$rows" --argjson references "$references" \
    '$rows + ($references | to_entries | map({id:.key,ref:.value}))'
}

# Keep each seed's reference stable. An explicit reference must be unused by other seeds.
fake_ref() {
  local id=$1 requested=${2:-} root registry existing records ref registry_json='{}'
  root=$(fake_identity_root) || return
  registry=$root/references.json
  records=$(fake_identity_records) || return
  existing=$(jq -cer --arg id "$id" '[.[] | select(.id == $id) | .ref | strings
    | select(test("^workspace:[1-9][0-9]*$"))] | unique
    | if length > 1 then error("conflicting workspace references") else (.[0] // "") end' <<<"$records") || return 64
  if [[ -n $existing ]]; then
    if [[ -n $requested && $requested != "$existing" ]]; then
      printf 'fake workspace reference cannot change for an existing row: %s\n' "$id" >&2
      return 64
    fi
    ref=$existing
  elif [[ -n $requested ]]; then
    [[ $requested =~ ^workspace:[1-9][0-9]*$ ]] || return 64
    ref=$requested
  else
    ref=$(jq -r '[.[].ref | strings | select(test("^workspace:[1-9][0-9]*$")) | split(":")[1] | tonumber]
      | "workspace:" + (((max // 0) + 1) | tostring)' <<<"$records") || return
  fi
  if jq -e --arg id "$id" --arg ref "$ref" 'any(.[]; .id != $id and .ref == $ref)' <<<"$records" >/dev/null; then
    printf 'fake workspace reference already belongs to another row: %s\n' "$ref" >&2
    return 64
  fi
  mkdir -p "$root"
  if [[ -f $registry ]]; then registry_json=$(cat "$registry") || return; fi
  jq --arg id "$id" --arg ref "$ref" '.[$id]=$ref' <<<"$registry_json" >"$registry.tmp" || return
  mv "$registry.tmp" "$registry"
  printf '%s' "$ref"
}

# Supply a host to enable the remote fields of a recorded row.
fake_row() {
  local ref
  ref=$(fake_ref "$1" "${8:-}") || return
  jq -c --arg ref "$ref" --arg id "$1" --arg title "$2" --arg description "$3" \
    --arg host "${4:-}" --arg state "${5:-connected}" --arg backend "${6:-cmux-tui}" \
    --argjson slot "${7:-null}" '
    [.workspaces[] | select(.remote.enabled == ($host != ""))][0]
    | .id=$id | .ref=$ref | .title=$title | .description=$description
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
    '$ids | to_entries | map(. as $entry | $template[0][0] | .id=$entry.value | .index=$entry.key
      | .key=($entry.key == 0) | .workspace_count=0 | .selected_workspace_id=null)'
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

fake_top() {
  jq -c --arg caller "$1" --argjson count "$2" '
    .caller.workspace_id=$caller
    | .coding_agents=[.coding_agents[0] | .resources.process_count=$count]' "$FAKE_CMUX_FIXTURES/top.json"
}

fake_window_rows() {
  local window=$1 index
  shift
  index=$(jq -r --arg id "$window" 'map(select(.id == $id))[0].index // 0' "$FAKE_CMUX_STATE/windows.json")
  fake_rows "$@" | jq --arg ref "window:$((index + 1))" '. + {window_ref:$ref}'
}
