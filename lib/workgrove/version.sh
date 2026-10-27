# shellcheck shell=sh
# Reads globals: HOME.
# The Mac sends these functions before VM probes so older installations use the same validation.
wt_read_version() {
  # WT_COMPAT: Remove optional capability handling when every VM reports its capabilities.
  jq -esc '
    if length == 1 and (.[0] | type == "object"
        and (.commit | type == "string" and length > 0)
        and (.protocol | type == "number" and . >= 1 and floor == .))
    then .[0] | {commit,protocol} +
      (if (.capabilities | type == "array" and all(.[]; type == "string"))
       then {capabilities} else {} end)
    else error("invalid wt version") end'
}

wt_vm_version() (
  # WT_COMPAT: Remove the unsupported-command fallback when every VM supports wt version.
  reply=$("$HOME/.local/bin/wt" version 2>/dev/null) &&
    version=$(printf '%s\n' "$reply" | wt_read_version 2>/dev/null) ||
    version='{"commit":null,"protocol":null}'
  printf '%s\n' "$version"
)
