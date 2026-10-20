# shellcheck shell=bash
# These helpers use install.sh's stash function and TMPFILES cleanup list.

# Create a tracked temporary file beside the destination.
# The caller receives its path in INSTALL_TMP.
install_temp() {
  mkdir -p "${1%/*}" || return 1
  INSTALL_TMP=$(mktemp "$1.XXXXXX") || return 1
  TMPFILES+=("$INSTALL_TMP")
}

# Preserve the original before replacing it with the completed file.
install_replace() {
  if [[ -e $2 || -L $2 ]]; then stash "$2" || return 1; fi
  mv "$1" "$2"
}

# json_merge <destination> <validate jq> <merge jq> [jq arguments...]
# Validate existing JSON before merging. Missing destinations start with an empty object.
# Return 2 for invalid input. Validation and jq failures leave the destination untouched.
json_merge() {
  local destination=$1 validate=$2 merge=$3 tmp
  shift 3
  if [[ -e $destination ]] && ! jq "$@" -e "$validate" "$destination" >/dev/null 2>&1; then
    return 2
  fi
  install_temp "$destination" || return 1
  tmp=$INSTALL_TMP
  if [[ -e $destination ]]; then
    jq "$@" "$merge" "$destination" > "$tmp" || return 1
  else
    printf '{}\n' | jq "$@" "$merge" > "$tmp" || return 1
  fi
  chmod 600 "$tmp" || return 1
  install_replace "$tmp" "$destination"
}
