# shellcheck shell=bash
# Reads globals: HOME, OS, R, TMPFILES.
# Requires stash from install.sh.
# Install the native notification rule without replacing the user's other automation rules.
hook_cmux_automation() {
  [[ $OS == Darwin ]] || return 0
  local dst=.cmuxterm/automations.json rc="$HOME/.cmuxterm/automations.json" tmp state
  if [[ -L $rc || ( -e $rc && ! -f $rc ) ]]; then
    echo "skipped ~/$dst: merge home/$dst's wt-native-relay rule into the managed file"
    return 0
  fi
  mkdir -p "${rc%/*}"
  tmp=$(mktemp "${rc}.new.XXXXXX") || return 1
  TMPFILES+=("$tmp")
  if [[ -e $rc ]]; then
    if ! jq -e 'type == "object" and .version == 1 and (.rules | type == "array") and all(.rules[]; type == "object" and (.id | type == "string"))' "$rc" >/dev/null 2>&1; then
      rm -f "$tmp"
      echo "skipped ~/$dst: expected a version-1 object with a rules array"
      return 0
    fi
    state=$(jq -r '[.rules[] | select(.id == "wt-native-relay")] | length' "$rc")
    if [[ $state != 0 ]]; then
      rm -f "$tmp"
      echo "kept ~/$dst's existing wt-native-relay rule"
      return 0
    fi
    jq --slurpfile rule "$R/home/.cmuxterm/automations.json" '.rules += $rule[0].rules' "$rc" > "$tmp" || { rm -f "$tmp"; return 1; }
    stash "$rc"
  else
    cp "$R/home/.cmuxterm/automations.json" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$rc"
  echo "installed the wt-native-relay rule in ~/$dst"
  echo "run 'cmux automation reload' to load the native notification rule"
}
