# Keep public contract names. Replace free text, identities, and unknown map keys.
def public_keys: [
  "rows","windows","notifications","top","automation","capabilities","event",
  "workspaces","id","title","description","remote","enabled","destination","state","backend",
  "persistent_daemon_slot","current_directory","index","key","caller","workspace_id","coding_agents",
  "resources","process_count","body","subtitle","surface_id","window_id","pane_id","payload",
  "notification_id","name","type","version","protocol","seq","source","boot_id","occurred_at",
  "created_at","is_read","rule_id","when","then","action","command","timeout_seconds",
  "rate_limit","interval_seconds","maximum","methods","access_mode","redacted_fields",
  "body_length","title_length","subtitle_length","delivery","replaced_notification_ids"
];
def public_values: [
  "cmux-tui","connected","disconnected","suspended","connecting","local","event",
  "notification.created","wt-native-relay","run","store","title","subtitle","body",
  "~/.local/bin/cmux-hook --event"
];
def methods: ["workspace.list","workspace.create","workspace.action","workspace.close","workspace.select",
  "workspace.remote.reconnect","notification.list","notification.dismiss","system.top","surface.read_text"];
. as $input
| [paths(strings) as $p | getpath($p)
    | select(test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))] | unique as $ids
| def scrub($key):
    if type == "object" then
      to_entries | to_entries | map(.key as $index | .value
        | .key as $field | .value |= scrub($field)
        | .key |= (if . as $k | public_keys | index($k) then . else "<field-\($index)>" end))
      | from_entries
    elif type == "array" then map(scrub($key))
    elif type == "string" then
      . as $value
      | if ($ids | index($value)) != null then
          (($ids | index($value)) + 1 | tostring) as $n
          | "00000000-0000-4000-8000-" + (("000000000000" + $n)[-12:])
        elif (public_values | index($value)) != null then .
        elif $key == "methods" and (methods | index($value)) != null then .
        elif $key == "destination" then "<test-vm>"
        elif $key == "description" then "@<test-vm> · <repo>"
        elif $key == "title" then "<title>"
        elif $key == "current_directory" then "<path>"
        else "<redacted>" end
    else . end;
$input | scrub("")
