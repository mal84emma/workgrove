# shellcheck shell=bash
probe_host() { # one SSH login proves remote-command access and gathers Linux hardware
  local out_file err_file ssh_pid rc=0 tick
  out_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-stdout.XXXXXX") || return 1
  err_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-stderr.XXXXXX") || { rm -f "$out_file"; return 1; }
  # The remote timeout limits an nvidia-smi that ignores TERM. The client deadline also limits a remote
  # command that is stuck in uninterruptible I/O: SSH may stay connected and answer keepalives forever.
  # Redirect SSH to files, so that an unkillable child cannot hold this function's output pipes open.
  ssh -T -o BatchMode=yes -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=2 "$1" 'sh -s' >"$out_file" 2>"$err_file" <"$WG_LIB_DIR/vm/probe-host.sh" &
  ssh_pid=$!
  for ((tick=0; tick<200; tick++)); do
    kill -0 "$ssh_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$ssh_pid" 2>/dev/null; then
    kill -KILL "$ssh_pid" 2>/dev/null || true
    printf 'SSH probe timed out after 20 seconds\n' >&2
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
  local host="$1" report="" rc=0 err_file err=""
  if ! valid_host "$host"; then
    jq -nc --arg host "$host" '{host:$host,status:"unavailable",cpu_logical:null,memory_mib:null,gpu_status:"unknown",gpus:[],error:"invalid SSH alias"}'
    return
  fi
  err_file=$(mktemp "${TMPDIR:-/tmp}/wt-host-error.XXXXXX") || return 1
  report=$(probe_host "$host" 2>"$err_file") || rc=$?
  if [[ $rc -ne 0 ]]; then
    err=$(sed -n '1p' "$err_file" | LC_ALL=C tr -d '\r' | cut -c1-180)
    rm -f "$err_file"
    jq -nc --arg host "$host" --arg error "SSH probe failed (exit $rc)${err:+: $err}" \
      '{host:$host,status:"unavailable",cpu_logical:null,memory_mib:null,gpu_status:"unknown",gpus:[],error:$error}'
    return
  fi
  rm -f "$err_file"
  printf '%s' "$report" | jq -Rsc --arg host "$host" '
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
    | {host:$host,status:"available",cpu_logical:(if $cpu != null and $cpu > 0 then $cpu else null end),
       memory_mib:(if $mem != null and $mem > 0 then ($mem / 1024 | floor) else null end),
       gpu_status:$gpu_status,gpus:$gpus,
       error:(if $cpu == null or $cpu == 0 or $mem == null or $mem == 0 then "incomplete CPU/RAM report" else null end)}'
}

cmd_hosts() {
  mac_only hosts
  local format=table records host f pid failed=0 files=() pids=()
  case "${1:-}" in
    "") ;;
    --json) format=json; shift ;;
    -h|--help) usage; return 0 ;;
    *) die "hosts: usage: wt hosts [--json]" ;;
  esac
  [[ $# -eq 0 ]] || die "hosts: usage: wt hosts [--json]"
  while IFS= read -r host; do
    f=$(mktemp "${TMPDIR:-/tmp}/wt-host-record.XXXXXX") || die "hosts: could not create a temporary file"
    files+=("$f")
    WT_TMPFILES+=("$f")
    (host_record "$host" >"$f") &
    pids+=("$!")
  done < <(ssh_hosts)
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  if [[ $failed -ne 0 ]]; then
    rm -f "${files[@]}"
    die "hosts: one or more probes could not be recorded"
  fi
  records=""
  if [[ ${#files[@]} -gt 0 ]]; then records=$(cat "${files[@]}"); fi
  rm -f "${files[@]}"
  if [[ $format == json ]]; then
    printf '%s\n' "$records" | jq -s '.'
  else
    printf '%s\n' "$records" | jq -sr '
      (["HOST","SSH","CPU","RAM GiB","GPU","ERROR"],
       (.[] | [ .host, .status, (.cpu_logical // "?" | tostring),
         (if .memory_mib == null then "?" else (.memory_mib / 1024 * 10 | round / 10 | tostring) end),
         (if .gpu_status == "none" then "none" elif .gpu_status != "ok" then "unknown"
          elif (.gpus | length) == 0 then "none"
          else (.gpus | map(if .memory_mib == null then "\(.name) (memory unknown)"
                            else "\(.name) (\(.memory_mib) MiB)" end) | join("; ")) end),
         (.error // "") ])) | @tsv' \
      | { if have column; then column -t -s $'\t'; else cat; fi; }
  fi
}
