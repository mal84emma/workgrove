# shellcheck shell=bash
# Reads globals: TMPDIR, WG_HOST_PROBE_TIMEOUT, WG_LIB_DIR.
# Requires common.sh: valid_host.
# Requires version.sh: wt_read_version.
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
  err_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-stderr.XXXXXX") || { rm -f "$out_file"; return 1; }
  # The remote timeout limits an nvidia-smi that ignores TERM. The client deadline also limits a remote
  # command that is stuck in uninterruptible I/O: SSH may stay connected and answer keepalives forever.
  # Redirect SSH to files, so that an unkillable child cannot hold this function's output pipes open.
  ssh -T -o BatchMode=yes -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=2 "$1" 'sh -s' >"$out_file" 2>"$err_file" < <(cat "$WG_LIB_DIR/version.sh" "$WG_LIB_DIR/vm/probe-host.sh") &
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
  local host="$1" report="" rc=0 err_file err="" version
  if ! valid_host "$host"; then
    jq -nc --arg host "$host" '{host:$host,status:"unavailable",wt_commit:null,wt_protocol:null,cpu_logical:null,memory_mib:null,gpu_status:"unknown",gpus:[],error:"invalid SSH alias"}'
    return
  fi
  err_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-error.XXXXXX") || return 1
  report=$(probe_host "$host" 2>"$err_file") || rc=$?
  if [[ $rc -ne 0 ]]; then
    err=$(sed -n '1p' "$err_file" | LC_ALL=C tr -d '\r' | cut -c1-180)
    rm -f "$err_file"
    jq -nc --arg host "$host" --arg error "SSH probe failed (exit $rc)${err:+: $err}" \
      '{host:$host,status:"unavailable",wt_commit:null,wt_protocol:null,cpu_logical:null,memory_mib:null,gpu_status:"unknown",gpus:[],error:$error}'
    return
  fi
  rm -f "$err_file"
  version=$(printf '%s\n' "$report" | sed -n $'s/^wt_version\t//p' | wt_read_version 2>/dev/null) ||
    version='{"commit":null,"protocol":null}'
  printf '%s' "$report" | jq -Rsc --arg host "$host" --argjson version "$version" '
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
    | {host:$host,status:"available",
       wt_commit:$version.commit,wt_protocol:$version.protocol,cpu_logical:(if $cpu != null and $cpu > 0 then $cpu else null end),
       memory_mib:(if $mem != null and $mem > 0 then ($mem / 1024 | floor) else null end),
       gpu_status:$gpu_status,gpus:$gpus,
       error:(if $cpu == null or $cpu == 0 or $mem == null or $mem == 0 then "incomplete CPU/RAM report" else null end)}'
}
