# shellcheck shell=bash
# Reads globals: TMPDIR, WG_HOST_PROBE_TIMEOUT, WG_LIB_DIR, VM_SSH_OPTIONS.
# Requires common.sh: valid_host. Requires task.sh: wt_register_tmpfile.
# Requires version.sh: wt_read_version.
# Send public probes inline so missing remote installation links cannot hide prerequisites.
host_probe_source() {
  cat "$WG_LIB_DIR/version.sh" "$WG_LIB_DIR/vm/probe-host.sh" "$WG_LIB_DIR/vm/python-runtime.sh"
  cat <<'WG_PROBE_HEADER'
if wg_select_python; then
wg_run_python - <<'WG_CAPACITY_SOURCE'
WG_PROBE_HEADER
  cat "$WG_LIB_DIR/vm/capacity.py"
  cat <<'WG_PROBE_MIDDLE'
WG_CAPACITY_SOURCE
wg_run_python - doctor --probe <<'WG_READINESS_SOURCE'
WG_PROBE_MIDDLE
  cat "$WG_LIB_DIR/portable.py"
  cat <<'WG_PROBE_END'
WG_READINESS_SOURCE
else
printf 'capabilities\t{"schema":1,"capacity_verified":false,"cpu_logical":null,"memory_mib":null,"capacity_issues":["%s"]}\n' "$wg_python_issue"
printf 'readiness\t{"schema":1,"ready":false,"status":"incomplete","issues":["%s"]}\n' "$wg_python_issue"
fi
WG_PROBE_END
}

probe_host() { # one SSH login proves remote-command access and gathers Linux hardware
  local out_file err_file ssh_pid rc=0 tick timeout=${WG_HOST_PROBE_TIMEOUT:-20}
  # Ten ticks per second must fit in signed 64-bit arithmetic.
  local timeout_max=922337203685477580
  # Compare decimal strings before arithmetic, so an oversized value cannot overflow.
  # shellcheck disable=SC2071
  if [[ ! $timeout =~ ^[1-9][0-9]*$ || ${#timeout} -gt ${#timeout_max} ||
        ( ${#timeout} -eq ${#timeout_max} && $timeout > $timeout_max ) ]]; then
    printf 'WG_HOST_PROBE_TIMEOUT must be a positive integer in seconds (maximum %s)\n' "$timeout_max" >&2
    return 1
  fi
  out_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-stdout.XXXXXX") || return 1
  wt_register_tmpfile "$out_file"
  err_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-stderr.XXXXXX") || { rm -f "$out_file"; return 1; }
  wt_register_tmpfile "$err_file"
  # The remote timeout limits an nvidia-smi that ignores TERM. The client deadline also limits a remote
  # command that is stuck in uninterruptible I/O: SSH may stay connected and answer keepalives forever.
  # Redirect SSH to files, so that an unkillable child cannot hold this function's output pipes open.
  ssh "${VM_SSH_OPTIONS[@]}" -T "$1" 'sh -s' >"$out_file" 2>"$err_file" < <(host_probe_source) &
  ssh_pid=$!
  for ((tick=0; tick<timeout*10; tick++)); do
    kill -0 "$ssh_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$ssh_pid" 2>/dev/null; then
    kill -KILL "$ssh_pid" 2>/dev/null || true
    # An uninterruptible SSH client can survive KILL. Do not wait after the deadline.
    printf 'SSH probe timed out after %s seconds\n' "$timeout" >&2
    rc=124
  else
    wait "$ssh_pid" || rc=$?
  fi
  cat "$out_file"
  cat "$err_file" >&2
  rm -f "$out_file" "$err_file"
  return "$rc"
}

host_record() { # stable JSON for agents; unknown hardware never becomes a false zero
  local host="$1" report="" rc=0 err_file err="" version capabilities readiness
  if ! valid_host "$host"; then
    jq -nc --arg host "$host" '{host:$host,status:"unavailable",wt_commit:null,wt_protocol:null,cpu_logical:null,memory_mib:null,capacity_verified:null,capacity_issues:[],environment:"unknown",workgrove_ready:null,readiness_status:"unknown",readiness_issues:[],gpu_allocation_verified:null,gpu_status:"unknown",gpus:[],error:"invalid SSH alias"}'
    return
  fi
  err_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-error.XXXXXX") || return 1
  wt_register_tmpfile "$err_file"
  if ssh_host_check "$host" 2>"$err_file"; then
    report=$(probe_host "$host" 2>"$err_file") || rc=$?
  else
    rc=1
  fi
  if [[ $rc -ne 0 ]]; then
    err=$(sed -n '1p' "$err_file" | LC_ALL=C tr -d '\r' | cut -c1-180)
    rm -f "$err_file"
    jq -nc --arg host "$host" --arg error "SSH probe failed (exit $rc)${err:+: $err}" \
      '{host:$host,status:"unavailable",wt_commit:null,wt_protocol:null,cpu_logical:null,memory_mib:null,capacity_verified:null,capacity_issues:[],environment:"unknown",workgrove_ready:null,readiness_status:"unknown",readiness_issues:[],gpu_allocation_verified:null,gpu_status:"unknown",gpus:[],error:$error}'
    return
  fi
  rm -f "$err_file"
  version=$(printf '%s\n' "$report" | sed -n $'s/^wt_version\t//p' | wt_read_version 2>/dev/null) ||
    version='{"commit":null,"protocol":null}'
  capabilities=$(printf '%s\n' "$report" | sed -n $'s/^capabilities\t//p' | jq -esc '
    if length == 1 and (.[0] | type == "object" and .schema == 1
      and (.capacity_verified | type == "boolean")
      and (.cpu_logical == null or (.cpu_logical | type == "number" and . >= 0 and floor == .))
      and (.memory_mib == null or (.memory_mib | type == "number" and . >= 0 and floor == .))
      and (if .capacity_verified then .cpu_logical != null and .memory_mib != null else true end)
      and (.capacity_issues == null or (.capacity_issues | type == "array" and all(.[]; type == "string" and test("^[a-z0-9-]+$"))))
      and (.environment == null or (.environment | IN("host", "container", "unknown")))
      and (.gpu_allocation_verified == null or (.gpu_allocation_verified | type == "boolean"))
      and (.gpu_indices == null or (.gpu_indices | type == "array" and all(.[]; type == "string" and test("^[0-9]+$")))))
    then .[0] else error("invalid capacity") end' 2>/dev/null) || capabilities='null'
  readiness=$(printf '%s\n' "$report" | sed -n $'s/^readiness\t//p' | jq -esc '
    if length == 1 and (.[0] | type == "object" and .schema == 1
      and (.ready == null or (.ready | type == "boolean"))
      and (.status | IN("ready", "incomplete", "legacy", "unknown"))
      and (.issues | type == "array" and all(.[]; type == "string" and test("^[a-z0-9.-]+$"))))
    then .[0] else error("invalid readiness") end' 2>/dev/null) || readiness='null'
  if [[ $report == *$'probe_schema\t2'* || $report == *$'capabilities\t'* || $report == *$'readiness\t'* ]]; then
    [[ $capabilities != null ]] || capabilities='{"schema":1,"capacity_verified":false,"cpu_logical":null,"memory_mib":null,"capacity_issues":["invalid-capacity-report"]}'
    [[ $readiness != null ]] || readiness='{"schema":1,"ready":false,"status":"incomplete","issues":["invalid-readiness-report"]}'
  fi
  printf '%s' "$report" | jq -Rsc --argjson capabilities "$capabilities" --argjson readiness "$readiness" --arg host "$host" --argjson version "$version" '
    def field($rows; $key): [ $rows[] | select(.[0] == $key) | .[1] ][0] // "";
    def unsigned: if type == "string" and test("^[0-9]+$") then tonumber else null end;
    [split("\n")[] | select(length > 0) | split("\t")] as $rows
    | (field($rows; "cpu") | unsigned) as $cpu
    | (field($rows; "mem_kib") | unsigned) as $mem
    | [ $rows[] | select(.[0] == "gpu") ] as $raw_gpus
    | [ $raw_gpus[] | select(length == 4 and (.[1] | gsub(" "; "") | unsigned) != null
           and (.[2] | gsub("^ +| +$"; "") | length > 0)
           and (.[3] | gsub(" "; "") | test("^[0-9]+$|^\\[N/A\\]$"))) ] as $valid_gpus
    | [ $valid_gpus[] | {name:(.[2] | gsub("^ +| +$"; "")),
           memory_mib:(.[3] | gsub(" "; "") | unsigned)} ] as $gpus
    | ([ $valid_gpus[] | .[1] | gsub(" "; "") ] | unique | length) as $unique_indices
    | (if field($rows; "gpu_status") == "ok" and ($raw_gpus | length) == ($gpus | length)
         and $unique_indices == ($gpus | length)
       then (if ($gpus | length) == 0 then "none" else "ok" end)
       elif field($rows; "gpu_status") == "none" and ($raw_gpus | length) == 0
       then "none" else "unknown" end) as $gpu_status
    | (if $capabilities.gpu_indices | type == "array" then
         [$gpus | to_entries[] | select(($valid_gpus[.key][1] | gsub(" "; "")) as $index
             | $capabilities.gpu_indices | index($index)) | .value]
       else $gpus end) as $allocated_gpus
    | {host:$host,status:"available",
       wt_commit:$version.commit,wt_protocol:$version.protocol,
       cpu_logical:(if $capabilities != null then $capabilities.cpu_logical else (if $cpu != null and $cpu > 0 then $cpu else null end) end),
       memory_mib:(if $capabilities != null then $capabilities.memory_mib else (if $mem != null and $mem > 0 then ($mem / 1024 | floor) else null end) end),
       capacity_verified:$capabilities.capacity_verified,capacity_issues:($capabilities.capacity_issues // []),
       environment:($capabilities.environment // "unknown"),workgrove_ready:$readiness.ready,
       readiness_status:($readiness.status // "unknown"),readiness_issues:($readiness.issues // []),
       gpu_allocation_verified:$capabilities.gpu_allocation_verified,
       gpu_status:(if $gpu_status == "ok" and $capabilities.gpu_indices == [] then "none" else $gpu_status end),gpus:$allocated_gpus,
       error:(if $capabilities.capacity_verified == false then "effective allocation unverified" elif $readiness.ready == false then "remote setup incomplete" elif $cpu == null or $cpu == 0 or $mem == null or $mem == 0 then "incomplete CPU/RAM report" else null end)}'
}
