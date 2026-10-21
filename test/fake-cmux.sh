#!/usr/bin/env bash
# Serve recorded contract responses without a cmux socket.
set -euo pipefail
fixtures=${CMUX_FIXTURES:?set CMUX_FIXTURES to a recorded fixture folder}
case "$*" in
  version)
    if [[ -n ${FAKE_CMUX_VERSION:-} ]]; then printf 'cmux %s\n' "$FAKE_CMUX_VERSION"
    else cat "$fixtures/version.txt"; fi ;;
  capabilities)
    jq --arg method "${FAKE_CMUX_MISSING_METHOD:-}" '.methods -= [$method]' "$fixtures/capabilities.json" ;;
  '--json list-windows') cat "$fixtures/windows.json" ;;
  'workspace list --json --window '*)
    if [[ -f $fixtures/rows_by_window.json ]]; then
      jq -e --arg window "$5" 'if has($window) then .[$window] else error("unknown fixture window") end' "$fixtures/rows_by_window.json"
    else cat "$fixtures/rows.json"; fi ;;
  'workspace list --json') cat "$fixtures/rows.json" ;;
  'top --json') cat "$fixtures/top.json" ;;
  '--json list-notifications') cat "$fixtures/notifications.json" ;;
  'automation show wt-native-relay') cat "$fixtures/automation.json" ;;
  'events --after 0 --name notification.created --limit 1 --timeout 3 --no-ack --no-heartbeat') cat "$fixtures/event.json" ;;
  *) printf 'fake cmux: unexpected command: %s\n' "$*" >&2; exit 64 ;;
esac
