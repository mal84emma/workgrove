# Keep public contract names. Replace free text, identities, and unknown map keys.
def public_keys: [
  "rows","rows_by_window","windows","notifications","top","automation","capabilities","event",
  "workspaces","id","title","description","remote","enabled","destination","state","backend",
  "persistent_daemon_slot","current_directory","index","key","caller","workspace_id","coding_agents",
  "resources","process_count","body","subtitle","surface_id","window_id","pane_id","payload",
  "notification_id","name","type","version","protocol","seq","source","boot_id","occurred_at",
  "created_at","is_read","rule_id","when","then","action","command","timeout_seconds",
  "rate_limit","interval_seconds","maximum","methods","access_mode","redacted_fields",
  "body_length","title_length","subtitle_length","delivery","replaced_notification_ids",
  "ref","window_ref","has_custom_title","terminal_transport","selected_workspace_id","workspace_count"
];
def public_value($key; $value):
  {backend:["cmux-tui"], state:["connected","disconnected","suspended","connecting"],
   type:["event"], name:["notification.created"], event:["notification.created"],
   id:["wt-native-relay"], rule_id:["wt-native-relay"], action:["run"], delivery:["store"],
   redacted_fields:["title","subtitle","body"], command:["~/.local/bin/cmux-hook --event"]}
  | (.[$key] // []) | index($value) != null;
def methods: ["workspace.list","workspace.create","workspace.action","workspace.close","workspace.select",
  "workspace.remote.reconnect","notification.list","notification.dismiss","system.top","surface.read_text"];
. as $input
| ([paths(strings) as $p | getpath($p)] + [.. | objects | keys[]]
    | map(select(test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))) | unique) as $ids
| ([.. | objects | to_entries[] | select(.key == "ref" or .key == "window_ref") | .value
    | strings | select(test("^workspace:[1-9][0-9]*$"))] | unique) as $workspace_refs
| ([.. | objects | to_entries[] | select(.key == "ref" or .key == "window_ref") | .value
    | strings | select(test("^window:[1-9][0-9]*$"))] | unique) as $window_refs
| def reference($value):
    if ($workspace_refs | index($value)) != null then
      "workspace:" + (($workspace_refs | index($value)) + 1 | tostring)
    elif ($window_refs | index($value)) != null then
      "window:" + (($window_refs | index($value)) + 1 | tostring)
    else "<redacted>" end;
  def identity($value):
    (($ids | index($value)) + 1 | tostring) as $n
    | "00000000-0000-4000-8000-" + (("000000000000" + $n)[-12:]);
  def scrub($key):
    if type == "object" then
      to_entries | to_entries | map(.key as $index | .value
        | .key as $field | .value |= scrub($field)
        | .key |= (. as $k | if ($ids | index($k)) != null then identity($k)
            elif (public_keys | index($k)) != null then . else "<field-\($index)>" end))
      | from_entries
    elif type == "array" then map(scrub($key))
    elif type == "string" then
      . as $value
      | if $key == "destination" then "<test-vm>"
        elif $key == "description" then "@<test-vm> · <repo>"
        elif $key == "title" then "<title>"
        elif $key == "body" or $key == "subtitle" then "<redacted>"
        elif $key == "current_directory" then "<path>"
        elif $key == "ref" or $key == "window_ref" then reference($value)
        elif ($ids | index($value)) != null then identity($value)
        elif public_value($key; $value) then .
        elif $key == "methods" and (methods | index($value)) != null then .
        else "<redacted>" end
    else . end;
$input | scrub("")
