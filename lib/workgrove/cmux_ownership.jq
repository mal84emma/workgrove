# Each stage retains its existing JSON stream result.
def run($documents; transform; $truth):
  [$documents[] | [try (transform | {value:.}) catch {error:true}]] as $runs
  | [$runs[][] | select(has("value")) | .value] as $values
  | {values:$values, valid:(($runs[-1][-1].error != true)
      and (if $truth then ($values | length > 0) and ($values[-1] != false and $values[-1] != null) else true end))};
def csv: map(tostring) | join(",") | sub(",+$"; "");
def chain($parents; $pid; $seen):
  if $parents[$pid] == null then true
  elif ($seen | length) >= 128 or ($seen | index($pid)) != null then false
  else chain($parents; $parents[$pid]; $seen + [$pid]) end;
def agent_counts: .coding_agents | type == "array"
    and all(.[]; .resources.process_count | type == "number" and . >= 0);
def agent_pids: all(.coding_agents[];
    (.resources.pids | type == "array") and (.resources.pids | length) == .resources.process_count
    and all(.resources.pids[]; type == "number" and . > 1 and floor == .)
    and (.resources.pids | unique | length) == (.resources.pids | length));
def row_resources: [.windows[].workspaces[] | select(.id == $id)] as $rows
    | ($rows | length) == 1 and ($rows[0].resources as $r
      | ($r.pids | type == "array") and ($r.pids | length) == $r.process_count
      and all($r.pids[]; type == "number" and . > 1 and floor == .)
      and ($r.pids | unique | length) == ($r.pids | length)
      and (($r.missing_pids // []) | type == "array" and length == 0));
def active: any(.coding_agents[]; .resources.process_count > 0);
def provider_pids: [.windows[].workspaces[] | select(.id == $id) | .resources.pids] as $rows
    | (if ($rows | length) != 1 or ($rows[0] | type) != "array" then error("missing row PIDs") else $rows[0] end) as $row
    | [.coding_agents[].resources.pids[] | select(. as $p | $row | index($p))] | unique
    | if any(.[]; type != "number" or . <= 1 or floor != .) then error("invalid agent PIDs")
      elif length == 0 then empty else .[] end;
def row_pids: .windows[].workspaces[] | select(.id == $id) | .resources.pids[]
    | if type == "number" and . > 1 and floor == . then . else error("invalid PID") end;
def extra_pids: [.windows[].workspaces[] | select(.id == $id)] as $ids
    | select(($ids | length) == 1)
    | select(($ids[0] | has("panes") | not) or ($ids[0].panes | type == "array"))
    | select(all($ids[0].panes[]?; (.surfaces | type == "array")))
    | [$ids[0].panes[]?.surfaces[]] as $surfaces
    | select(all($surfaces[];
      ((has("tty_process_pids") | not) or (.tty_process_pids | type == "array"))
      and ((has("unattributed_tty_process_pids") | not) or (.unattributed_tty_process_pids | type == "array"))
      and ((.unattributed_resources.pids // []) | type == "array")
      and ((.unattributed_resources.missing_pids // []) | length) == 0
      and (if has("unattributed_resources") then .unattributed_resources as $u
        | ($u.process_count | type == "number" and . >= 0 and floor == .)
        and ($u.pids | length) == $u.process_count
        and ($u.pids | unique | length) == $u.process_count else true end)
      and ((has("tty_ownership_reasons") | not) or (.tty_ownership_reasons | type == "object"))))
    | [$surfaces[] | (.unattributed_tty_process_pids // [])[], (.unattributed_resources.pids // [])[]] as $unattributed
    | $ids[0].resources.pids as $attributed
    | select(all($unattributed[]; . as $pid | ($attributed | index($pid)) == null))
    | [$surfaces[] | (.tty_process_pids // [])[], (.unattributed_tty_process_pids // [])[],
        (.unattributed_resources.pids // [])[], ((.tty_ownership_reasons // {}) | keys[] | tonumber)] | unique
    | select(all(.[]; type == "number" and . > 1 and floor == .))
    | . - $attributed
    | if length == 0 then "" else .[] end;
def graph_records: select(.include_processes == true)
    | [.windows[].workspaces[] | select(.id == $id)] as $ids
    | select(($ids | length) == 1)
    | $ids[0] as $r
    | [$r.panes[].surfaces[].processes[] | recurse(.children[]?)] as $nodes
    | select(all($nodes[]; .kind == "process" and (.pid | type == "number" and . > 1 and floor == .)
      and (.ppid | type == "number" and . >= 0 and floor == .)))
    | select(($nodes | map(.pid) | unique | length) == ($nodes | length))
    | select(($nodes | map(.pid) | sort) == ($r.resources.pids | sort))
    | $nodes[] | "\(.pid):\(.ppid)";
def graph($documents):
  run($documents; graph_records; true) as $result
  | if $result.valid and all($result.values[]; test("^[0-9]+:[0-9]+$")) then
      ($result.values | map(split(":") | {key:.[0], value:.[1]}) | from_entries) as $parents
      | if all($parents | keys[]; chain($parents; .; [])) then $result.values | csv else "invalid" end
    else "invalid" end;
def refuse($reason): ["1", $reason, "", "", "", "invalid", "end"];
def assess:
. as $documents
| if length == 0 or (run($documents; agent_counts; true).valid | not) then refuse("agents")
  elif (run($documents; agent_pids; true).valid | not) then refuse("agent-pids")
  elif (run($documents; row_resources; true).valid | not) then refuse("row")
  else run($documents; extra_pids; true) as $extra
    | if ($extra.valid | not) then refuse("extras")
      else (if run($documents; active; true).valid then run($documents; provider_pids; false) else {values:[],valid:true} end) as $providers
        | if ($providers.valid | not) then refuse("ownership") else
        run($documents; row_pids; false) as $row
        | ($providers.values | csv) as $pids
        | ($extra.values | csv) as $unattributed
        | ["1", (if $pids != "" then "live" elif $unattributed != "" then "attribution" else "idle" end),
            $pids, ($row.values | csv), $unattributed, graph($documents), "end"]
      end
  end end;
if $mode == "extras" then extra_pids else assess | join("\u0000") + "\u0000" end
