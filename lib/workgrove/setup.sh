# shellcheck shell=bash
# Prepare hosts through ordinary SSH without requiring a remote wt executable.
host_setup() {
  local host=$1; shift
  local -A opts=()
  wt_opts "$(wt_spec setup)" opts "$@"
  [[ -n ${opts[root]:-} && ${opts[root]} == /* ]] || die 'setup: --root needs an absolute remote path'
  local args=() bootstrap policy=${opts[storage]:-} mount=${opts[mount]:-}
  wt_opt_args opts args
  # Python receives standard input. The shell bootstrap never reads the uploaded source.
  bootstrap=$(cat "$WG_LIB_DIR/vm/python-runtime.sh")$'\n'
  # shellcheck disable=SC2016
  bootstrap+='if ! wg_select_python; then
    [ "$1" != restore ] || { echo "workgrove: Python 3 is missing; run full setup with an explicit storage policy" >&2; exit 1; }
    case "$2" in /*) ;; *) exit 1;; esac
    if [ -f "$2/.config/workgrove/profile.json" ]; then
      [ -n "$3" ] || { echo "workgrove: Python 3 is missing; pass --storage volume --mount <mount>, or --storage os-disk, to use the saved root" >&2; exit 1; }
      if [ "$3" = volume ] && [ -z "$4" ]; then
        command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$2" || { echo "workgrove: Python 3 is missing; pass --mount <mount> with --storage volume when the root is below the mount" >&2; exit 1; }
      fi
    fi
    if [ "${3:-volume}" = volume ]; then
      [ -d "$2" ] && command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "${4:-$2}" || { echo "workgrove: persistent-mount-missing" >&2; exit 1; }
    else [ "$3" = os-disk ] || exit 1; fi
    . /etc/os-release
    [ "$ID" = ubuntu ] && { [ "$VERSION_ID" = 22.04 ] || [ "$VERSION_ID" = 24.04 ]; } || { echo "workgrove: unsupported-package-adapter" >&2; exit 1; }
    if [ "$(id -u)" = 0 ]; then set -- env DEBIAN_FRONTEND=noninteractive apt-get;
    else command -v sudo >/dev/null 2>&1 && sudo -n true || { echo "workgrove: package-install-privilege-required" >&2; exit 1; }; set -- sudo -n env DEBIAN_FRONTEND=noninteractive apt-get; fi
    "$@" update </dev/null >/dev/null 2>&1 && "$@" install -y python3 </dev/null >/dev/null 2>&1 || { echo "workgrove: Python-install-failed" >&2; exit 1; }
    wg_select_python || { echo "workgrove: supported-Python-unavailable" >&2; exit 1; }
  fi
  exec "$wg_python" -B - '
  local mode=full
  [[ ! -v opts[restore] ]] || mode=restore
  # Keep bootstrap positional parameters separate from the Python arguments after its command text.
  bootstrap+="$(shell_join bootstrap --host "$host" "${args[@]}")"
  local error_file consent status=0
  error_file=$(mktemp "${TMPDIR:-/tmp}/wt-setup-error.XXXXXX") || die 'setup: cannot create a private diagnostic file'
  wt_register_tmpfile "$error_file"
  remote_sh_raw "$host" "/bin/sh -c $(shell_join "$bootstrap" wt-setup "$mode" "${opts[root]}" "$policy" "$mount")" \
    <"$WG_LIB_DIR/portable.py" 2>"$error_file" || status=$?
  if ((status != 0)) && [[ ! -v opts[trust] && ! -v opts[strict] && ! -v opts[restore] && -t 0 && -t 2 ]] &&
      LC_ALL=C grep -F '"error": "personal-volume-trust-required"' "$error_file" >/dev/null &&
      command -v python3 >/dev/null 2>&1; then
    if consent=$(python3 -B "$WG_LIB_DIR/portable.py" confirm-volume-trust --request-file "$error_file"); then
      local -a approved=()
      mapfile -t approved <<<"$consent"
      rm -f "$error_file"
      wt_opt_args opts args root mount trust
      host_setup "$host" --root "${approved[0]}" --mount "${approved[1]}" --trust-personal-volume "${args[@]}"
      return
    fi
  fi
  cat "$error_file" >&2
  rm -f "$error_file"
  [[ $status != 255 ]] || die "host unreachable: is the VM running? (ssh $host)"
  return "$status"
}

host_environment_doctor() {
  local host=$1; shift
  local -A opts=()
  wt_opts "$(wt_spec doctor)" opts "$@"
  local args=()
  wt_opt_args opts args
  local bootstrap
  bootstrap=$(cat "$WG_LIB_DIR/vm/python-runtime.sh")$'\n'
  # shellcheck disable=SC2016
  bootstrap+='wg_select_python || { wg_python_readiness_error; exit 1; }; exec "$wg_python" -B - '
  remote_sh "$host" "$bootstrap$(shell_join doctor "${args[@]}")" <"$WG_LIB_DIR/portable.py"
}

cmd_setup() {
  local -A opts=()
  wt_opts "$(wt_spec setup)" opts "$@"
  die 'setup: use wt -H <host> setup --root <persistent-root>'
}
cmd_environment_doctor() {
  local -A opts=()
  wt_opts "$(wt_spec doctor)" opts "$@"
  local args=()
  wt_opt_args opts args
  # shellcheck source=lib/workgrove/vm/python-runtime.sh
  source "$WG_LIB_DIR/vm/python-runtime.sh"
  wg_select_python || { wg_python_readiness_error; return 1; }
  "$wg_python" -B "$WG_LIB_DIR/portable.py" doctor "${args[@]}"
}
