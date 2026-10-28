#!/usr/bin/env bash
# Exercise command metadata and parsing without contacting SSH hosts or opening rows.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-options.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
SCRATCH_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
[[ $TEST_ROOT == "$SCRATCH_BASE"/* && $TEST_ROOT != "$HOME"/* ]] || exit 1
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"
# shellcheck source=lib/workgrove/common.sh
source "$REPO/lib/workgrove/common.sh"
# shellcheck source=lib/workgrove/remote.sh
source "$REPO/lib/workgrove/remote.sh"
trap lib_cleanup EXIT
mkdir -p "$TEST_ROOT/home"

invoke() {
  STATUS=0
  OUTPUT=$(HOME="$TEST_ROOT/home" bash "$REPO/bin/wt" "$@" 2>&1) || STATUS=$?
}
contains() {
  if [[ $2 == *"$3"* ]]; then pass; else fail "$1: missing $3"; fi
}
absent() {
  if [[ $2 != *"$3"* ]]; then pass; else fail "$1: found $3"; fi
}

begin_scenario 'each command and alias selects its own help'
while IFS='|' read -r command aliases mode rest; do
  [[ $command != help ]] || continue
  invoke "$command" -h
  assert_eq "$command help status" 0 "$STATUS"
  contains "$command usage" "$OUTPUT" "wt $command"
  [[ $command == new ]] || absent "$command excludes new" "$OUTPUT" 'wt new  [name]'
  names=()
  IFS=',' read -r -a names <<<"$aliases"
  for alias in "${names[@]}"; do
    invoke "$alias" --help
    assert_eq "$alias help status" 0 "$STATUS"
    contains "$alias canonical usage" "$OUTPUT" "wt $command"
  done
  if [[ $mode != local ]]; then
    invoke -H example.invalid "$command" --help
    assert_eq "$command remote help status" 0 "$STATUS"
    contains "$command remote usage" "$OUTPUT" "wt $command"
  fi
done <<<"$WT_COMMANDS"
for command in hosts task; do
  OUTPUT=$(CMUX_SSH_ATTEMPT_ID=help-only bash "$REPO/bin/wt" "$command" -h)
  contains "$command help works inside a VM" "$OUTPUT" "wt $command"
done
invoke help
contains 'global help keeps new alignment' "$OUTPUT" 'wt new  [name]'
contains 'global remote usage' "$OUTPUT" "wt -H <host> <$(wt_remote_commands '|')>"
invoke attach -h
contains 'direct attach rejects recovery flags' "$OUTPUT" 'Direct attach rejects --reattach and --restart-agent.'
contains 'remote attach requires its repository option' "$OUTPUT" 'wt -H <host> attach <name> -r REPO [--reattach|--restart-agent]'
absent 'remote attach does not mark repo optional' "$OUTPUT" '[-r REPO]'
contains 'remote attach rejects updates' "$OUTPUT" 'With -H, attach rejects -a/--agent and -p/--prompt.'
end_scenario

begin_scenario 'each command help names every declared option'
while IFS='|' read -r command aliases mode rest; do
  invoke "$command" -h
  assert_eq "$command help status" 0 "$STATUS"
  help_options=$(grep -oE -- '--?[[:alnum:]][[:alnum:]_-]*\*?' <<<"$OUTPUT" || true)
  for form in direct remote; do
    mapfile -t rows <<<"$(wt_spec "$command" "$form")"
    for row in "${rows[@]:1}"; do
      IFS='|' read -r aliases key rest <<<"$row"
      [[ $key != @error ]] || continue
      names=()
      IFS=',' read -r -a names <<<"$aliases"
      found=0
      for alias in "${names[@]}"; do
        if grep -Fxq -- "$alias" <<<"$help_options"; then found=1; break; fi
      done
      assert_eq "$command $form help names one of $aliases" 1 "$found"
    done
  done
done <<<"$WT_COMMANDS"
invoke update -h
contains 'update names opinionated config' "$OUTPUT" '--opinionated-config'
contains 'update names installer config flags' "$OUTPUT" '--with-*'
contains 'update names portable flags' "$OUTPUT" 'Portable hosts accept only --refresh-config and --with-tmux-conf.'
invoke doctor -h
absent 'doctor excludes its internal host option' "$OUTPUT" '--host'
end_scenario

begin_scenario 'shared parsing preserves values, repetitions, and positional boundaries'
declare -A parsed=()
wt_opts "$(wt_spec new)" parsed --repo='a path=one' --prompt=-r --agent none --agent=codex --head --head -- -task
assert_eq 'equals value preserves spaces and equals' 'a path=one' "${parsed[repo]}"
assert_eq 'an option-looking value stays a value' -r "${parsed[prompt]}"
assert_eq 'last repeated value wins' codex "${parsed[agent]}"
assert_eq 'repeated flag stays set' 1 "${parsed[from_head]}"
assert_eq 'delimiter permits option-looking positional value' -task "${parsed[name]}"
wt_opts "$(wt_spec repos)" parsed --table --porcelain
assert_eq 'last mutually exclusive flag wins' porcelain "${parsed[mode]}"
wt_opts "$(wt_spec new)" parsed --prompt=
assert_eq 'empty equals value is present' '' "${parsed[prompt]}"
for command in current driver hosts list prune task update; do
  wt_opts "$(wt_spec "$command")" parsed --
  assert_eq "$command accepts empty delimiter" 0 "${parsed[@count]}"
done
WT_OPT_HOST=ambient wt_opts "$(wt_spec new)" parsed --repo=relative/path
assert_eq 'generic parsing has no ambient remote policy' relative/path "${parsed[repo]}"
STATUS=0
OUTPUT=$(wt_opts $'probe|name\n-x*|@error|use --value' parsed -xlegacy 2>&1) || STATUS=$?
assert_eq 'declared rejection status' 1 "$STATUS"
contains 'declared rejection keeps its hint' "$OUTPUT" 'probe: unknown option -xlegacy (use --value)'
wt_opts "$(wt_spec new remote)" parsed -- -mfable
assert_eq 'declared rejection respects the positional boundary' -mfable "${parsed[name]}"
invoke diff --bad
contains 'diff keeps show error text' "$OUTPUT" 'show: unknown option --bad'
invoke diff --repo
contains 'diff reports missing option values' "$OUTPUT" 'show: --repo needs a repo'
invoke show --help=value
assert_eq 'help flag rejects a value' 1 "$STATUS"
invoke new --repo
assert_eq 'missing value status' 1 "$STATUS"
contains 'missing value error' "$OUTPUT" 'new: --repo needs a repo'
invoke attach --reattach
contains 'direct recovery flag stays rejected' "$OUTPUT" 'attach: unknown option --reattach'
invoke -H example.invalid attach --prompt=test
contains 'remote brief stays rejected' "$OUTPUT" 'attach: unknown option --prompt'
invoke -H example.invalid attach --agent=codex
contains 'remote agent stays rejected' "$OUTPUT" 'attach: unknown option --agent'
invoke -H example.invalid show -- -r
contains 'positional repo flag cannot satisfy scope' "$OUTPUT" 'show: -r <repo> is required with -H'
end_scenario

begin_scenario 'every option spec accepts delimiters and valued long equals syntax'
while IFS='|' read -r command aliases mode rest; do
  for form in direct remote; do
    spec=$(wt_spec "$command" "$form")
    wt_opts "$spec" parsed --
    assert_eq "$command $form accepts a delimiter" 0 "${parsed[@count]}"
    mapfile -t rows <<<"$spec"
    for row in "${rows[@]:1}"; do
      IFS='|' read -r aliases key kind _ <<<"$row"
      [[ $kind != =* ]] || continue
      names=()
      IFS=',' read -r -a names <<<"$aliases"
      for alias in "${names[@]}"; do
        [[ $alias == --* ]] || continue
        wt_opts "$spec" parsed "$alias=first" "$alias=last" --
        assert_eq "$command $form $alias accepts repeated equals values" last "${parsed[$key]}"
      done
    done
  done
done <<<"$WT_COMMANDS"
end_scenario

begin_scenario 'remote normalization and removal retain complete options'
args=()
wt_remote_args example.invalid new args --repo='/a path/' --prompt=-r --model='family:model' -- --name
wt_opts "$(wt_spec new)" parsed "${args[@]}"
assert_eq 'remote repo loses trailing slash' '/a path' "${parsed[repo]}"
assert_eq 'remote prompt is not a repo flag' -r "${parsed[prompt]}"
assert_eq 'remote model keeps colon' family:model "${parsed[model]}"
assert_eq 'remote positional boundary survives' --name "${parsed[name]}"
# A future valued rm flag must reach the VM with its value intact.
WT_COMMANDS=${WT_COMMANDS/'--keep-branch:keep:=1'/'--note:note:a note;--keep-branch:keep:=1'}
# shellcheck source=test/fakes/rows.sh
source "$REPO/test/fakes/rows.sh"
fake_cmux_init "$TEST_ROOT/cmux-state"
CMUX_BUNDLED_CLI_PATH="$REPO/test/fakes/cmux"
agent_on_vm() { return 1; }
vm_tmux() { :; }
remote_wt() { printf '%s\n' "$@" >"$TEST_ROOT/forwarded"; }
host_rm example.invalid task --repo='repo name' --note='a value' --keep-branch
mapfile -t forwarded <"$TEST_ROOT/forwarded"
assert_eq 'rm forwards complete argv' $'example.invalid\nrm\n--repo\nrepo name\n--note\na value\n--keep-branch\ntask\n--row-closed' "$(printf '%s\n' "${forwarded[@]}")"
end_scenario

begin_scenario 'one table row and one function make a command dispatchable'
mkdir -p "$TEST_ROOT/fixture/bin" "$TEST_ROOT/fixture/lib/workgrove"
cp "$REPO/bin/wt" "$TEST_ROOT/fixture/bin/wt"
cp "$REPO"/lib/workgrove/*.sh "$TEST_ROOT/fixture/lib/workgrove/"
cat >>"$TEST_ROOT/fixture/lib/workgrove/options.sh" <<'FIXTURE'
WT_COMMANDS+=$'\nprobe|inspect|forward|Inspect a probe.|name;--value:value:a value|'
cmd_probe() {
  local -A opts=()
  wt_opts "$(wt_spec probe)" opts "$@"
  printf 'probe: %s %s\n' "${opts[name]}" "${opts[value]}"
}
FIXTURE
OUTPUT=$(bash "$TEST_ROOT/fixture/bin/wt" inspect --value=hello -- -operand)
assert_eq 'new alias dispatches and parses' 'probe: -operand hello' "$OUTPUT"
OUTPUT=$(bash "$TEST_ROOT/fixture/bin/wt" probe -h)
contains 'new command gets fallback help' "$OUTPUT" 'wt probe    Inspect a probe.'
OUTPUT=$(bash "$TEST_ROOT/fixture/bin/wt" help)
contains 'new command appears in remote usage' "$OUTPUT" '|probe>'
# The SSH stub executes only the scratch wt, so the same row also proves remote dispatch.
mkdir -p "$TEST_ROOT/stubs" "$TEST_ROOT/home/.local/bin"
cp "$TEST_ROOT/fixture/bin/wt" "$TEST_ROOT/home/.local/bin/wt"
mkdir -p "$TEST_ROOT/home/.local/lib/workgrove"
cp "$TEST_ROOT/fixture/lib/workgrove/"*.sh "$TEST_ROOT/home/.local/lib/workgrove/"
make_fake_ssh "$TEST_ROOT/stubs/ssh"
OUTPUT=$(HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/stubs:$PATH" bash "$TEST_ROOT/fixture/bin/wt" -H example.invalid probe --value='a value' -- -operand)
assert_eq 'new command forwards with boundaries' 'probe: -operand a value' "$OUTPUT"
end_scenario
lib_summary
