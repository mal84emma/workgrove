# Keep projected contract names. Replace free text and identities.
def public_keys: [
  "rows","rows_by_window","windows","notifications","top","automation","capabilities","event",
  "workspaces","id","title","description","remote","enabled","destination","state","backend",
  "persistent_daemon_slot","current_directory","index","key","caller","workspace_id","coding_agents",
  "resources","process_count","body","subtitle","surface_id","window_id","pane_id","payload",
  "notification_id","name","type","version","protocol","seq","source","boot_id","occurred_at",
  "created_at","is_read","rule_id","when","then","action","command","timeout_seconds",
  "rate_limit","interval_seconds","maximum","methods","access_mode","redacted_fields",
  "body_length","title_length","subtitle_length","delivery","replaced_notification_ids",
  "ref","window_ref","workspace_ref","has_custom_title","terminal_transport","selected_workspace_id","workspace_count",
  "pids","missing_pids","remote_workspace_id","active_terminal_sessions"
];
def public_value($key; $value):
  {backend:["cmux-tui"], state:["connected","disconnected","suspended","connecting","reconnecting"],
   type:["event"], name:["notification.created"], event:["notification.created"],
   id:["wt-native-relay"], rule_id:["wt-native-relay"], action:["run"], delivery:["store"],
   redacted_fields:["title","subtitle","body"], command:["~/.local/bin/cmux-hook --event"]}
  | (.[$key] // []) | index($value) != null;
def methods: ["workspace.list","workspace.create","workspace.action","workspace.close","workspace.select",
  "notification.list","notification.dismiss","system.top","surface.read_text"];
. as $input
| ([paths(strings) as $p | getpath($p)] + [.. | objects | keys[]]
    | map(select(test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))) | unique) as $ids
| ([.. | objects | to_entries[] | select(.key == "ref" or .key == "window_ref") | .value
    | strings | select(test("^workspace:[1-9][0-9]*$"))]
    + [.. | objects | .workspace_ref? | strings] | unique) as $workspace_refs
| ([.. | objects | to_entries[] | select(.key == "ref" or .key == "window_ref") | .value
    | strings | select(test("^window:[1-9][0-9]*$"))] | unique) as $window_refs
| ([.. | objects | (.pids? // [])[], (.missing_pids? // [])[]] | unique) as $pids
| def reference($value):
    if ($workspace_refs | index($value)) != null then
      "workspace:" + (($workspace_refs | index($value)) + 1 | tostring)
    elif ($window_refs | index($value)) != null then
      "window:" + (($window_refs | index($value)) + 1 | tostring)
    else "<redacted>" end;
  def identity($value):
    (($ids | index($value)) + 1 | tostring) as $n
    | "00000000-0000-4000-8000-" + (("000000000000" + $n)[-12:]);
  def scrub($key; $full):
    if type == "object" then
      to_entries | to_entries | map(.key as $index | .value
        | .key as $field
        | select($full or (public_keys | index($field)) != null or ($ids | index($field)) != null)
        | .value |= scrub($field; ($full or $field == "automation"))
        | .key |= (. as $k | if ($ids | index($k)) != null then identity($k)
            elif (public_keys | index($k)) != null then . else "<field-\($index)>" end))
      | from_entries
    elif type == "array" then map(scrub($key; $full))
    elif type == "string" then
      . as $value
      | if $value == "" then .
        elif $key == "destination" then "<test-vm>"
        elif $key == "description" then "@<test-vm> · <repo>"
        elif $key == "title" then "<title>"
        elif $key == "body" or $key == "subtitle" then "<redacted>"
        elif $key == "current_directory" then "<path>"
        elif $key == "ref" or $key == "window_ref" or $key == "workspace_ref" then reference($value)
        elif ($ids | index($value)) != null then identity($value)
        elif public_value($key; $value) then .
        elif $key == "methods" and (methods | index($value)) != null then .
        else "<redacted>" end
    elif type == "number" and ($key == "pids" or $key == "missing_pids") then
      . as $pid | ($pids | index($pid)) + 2
    else . end;
$input | scrub(""; false)
