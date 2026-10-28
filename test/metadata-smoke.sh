#!/usr/bin/env bash
# Check sidecar compatibility, read counts, and the JSON status contract.
set -euo pipefail
SOURCE_REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/metadata-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
# shellcheck source=test/lib.sh
source "$SOURCE_REPO/test/lib.sh"
# shellcheck source=lib/workgrove/common.sh
source "$SOURCE_REPO/lib/workgrove/common.sh"
# shellcheck source=lib/workgrove/safety.sh
source "$SOURCE_REPO/lib/workgrove/safety.sh"
trap lib_cleanup EXIT

REPO="$TEST_ROOT/project" WT_DIRNAME=.worktrees
mkdir -p "$REPO" "$TEST_ROOT/bin"
git init -qb main "$REPO"
git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
REAL_JQ=$(command -v jq)
export REAL_JQ META_READS="$TEST_ROOT/reads"
cat >"$TEST_ROOT/bin/jq" <<'JQ'
#!/usr/bin/env bash
for arg in "$@"; do
  case $arg in */.git/wt/*.json) printf '%s\n' "$arg" >>"$META_READS" ;; esac
done
exec "$REAL_JQ" "$@"
JQ
chmod +x "$TEST_ROOT/bin/jq"
export PATH="$TEST_ROOT/bin:$PATH"

invoke() {
  local rc=0
  : >"$META_READS"
  WG_MACHINE_RESULT=1 bash "$SOURCE_REPO/bin/wt" "$@" -r "$REPO" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" || rc=$?
  printf '%s' "$rc" >"$TEST_ROOT/status"
}

begin_scenario 'metadata preserves typed values, delimiters, and legacy file records'
local_status=0
declare -A values=()
meta_load absent values || local_status=$?
assert_eq 'a missing sidecar returns one' 1 "$local_status"
meta_set typed 'base=main' 'false:=false' 'number:=7' 'empty:=null' $'text=line one\nline two\t="quoted"' \
  'includes:=[".env:abc","folder/other:def"]' 'setup:=["lock:123"]'
meta_load typed values
assert_eq 'a boolean survives' false "${values[false]}"
assert_eq 'a number survives' 7 "${values[number]}"
assert_eq 'null reads as empty' '' "${values[empty]}"
assert_eq 'text preserves delimiters' $'line one\nline two\t="quoted"' "${values[text]}"
assert_eq 'typed includes read as records' $'.env:abc\nfolder/other:def' "${values[includes]}"
assert_eq 'arrays remain typed on disk' array "$(jq -r '.includes | type' "$REPO/.git/wt/typed.json")"
meta_set typed 'agent=none'
assert_eq 'an update preserves an array' array "$(jq -r '.setup | type' "$REPO/.git/wt/typed.json")"
WT_META_FILE=''
meta_load typed values
assert_eq 'a fresh read preserves records' $'.env:abc\nfolder/other:def' "${values[includes]}"
meta_set legacy $'includes=.env:abc\nfolder/other:def' $'setup=lock:123\nother:456'
WT_META_FILE=''
meta_load legacy values
assert_eq 'legacy includes still read' $'.env:abc\nfolder/other:def' "${values[includes]}"
assert_eq 'legacy setup still reads' $'lock:123\nother:456' "${values[setup]}"
end_scenario

begin_scenario 'cache-output aliases preserve metadata on fresh and cached reads'
WT_META_FILE=''
meta_load typed WT_META
assert_eq 'a fresh cache output retains its base' main "${WT_META[base]}"
meta_load typed WT_META
assert_eq 'a cached output retains its base' main "${WT_META[base]}"
declare -n cache_alias=WT_META
meta_load typed cache_alias
assert_eq 'an indirect cache alias retains its fields' none "${cache_alias[agent]}"
meta_require typed
assert_eq 'requiring metadata preserves the cache' main "${WT_META[base]}"
end_scenario

begin_scenario 'large cached sidecars update without process argument limits'
jq -n '{base:"main", payload:("x" * 1100000)}' >"$REPO/.git/wt/large.json"
: >"$META_READS"
meta_set large title=updated
assert_eq 'a large sidecar is read once' 1 "$(wc -l <"$META_READS" | tr -d ' ')"
assert_eq 'the large payload remains intact' 1100000 "$(jq '.payload | length' "$REPO/.git/wt/large.json")"
assert_eq 'the update preserves other fields' true "$(jq '.base == "main" and .title == "updated"' "$REPO/.git/wt/large.json")"
assert_eq 'the cache receives the committed update' updated "${WT_META[title]}"
end_scenario

begin_scenario 'JSON status has stable fields and reads each sidecar once'
invoke new first --no-workspace -a none -p $'brief "quoted"\nsecond line'
assert_eq 'creation succeeds' 0 "$(cat "$TEST_ROOT/status")"
assert_eq 'new sidecars store arrays' '["array","array"]' "$(jq -c '[.includes|type] + [.setup|type]' "$REPO/.git/wt/first.json")"
invoke show first --json
assert_eq 'JSON show succeeds' 0 "$(cat "$TEST_ROOT/status")"
assert_eq 'show reads its sidecar once' 1 "$(wc -l <"$META_READS" | tr -d ' ')"
keys='["ahead","base","behind","branch","checkout_branch","comparison","dirty","last_commit_at","merged","model","name","path","repo","task","title","why"]'
assert_eq 'show pins the additive comparison shape' "$keys" "$(jq -c 'keys' "$TEST_ROOT/out")"
assert_eq 'comparison labels cached evidence' cached "$(jq -r .comparison.freshness "$TEST_ROOT/out")"
assert_eq 'show preserves paths and brief text' true "$(jq --arg repo "$REPO" '.repo == $repo and .path == ($repo + "/.worktrees/first") and .task == "brief \"quoted\"" and .title == "first" and .model == ""' "$TEST_ROOT/out")"
assert_eq 'common status fields use the documented values' true "$(jq '.name == "first" and .branch == "wt/first" and .checkout_branch == "wt/first" and .base == "main" and .ahead == 0 and .behind == 0 and .dirty == 0 and .merged == "yes" and .why == "" and (.last_commit_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$TEST_ROOT/out")"
cp "$TEST_ROOT/out" "$TEST_ROOT/show.json"
invoke list --json
assert_eq 'JSON list succeeds' 0 "$(cat "$TEST_ROOT/status")"
assert_eq 'list reads its sidecar once' 1 "$(wc -l <"$META_READS" | tr -d ' ')"
assert_eq 'list and show share the same status fields' true "$(jq --slurpfile show "$TEST_ROOT/show.json" '. == [($show[0] | del(.title,.task,.model))]' "$TEST_ROOT/out")"
git -C "$REPO/.worktrees/first" checkout -q --detach
invoke show first --json
assert_eq 'detached checkouts keep task identity' true "$(jq '.branch == "wt/first" and .checkout_branch == null' "$TEST_ROOT/out")"
git -C "$REPO/.worktrees/first" checkout -q wt/first
meta_set first base=gone
invoke show first --json
assert_eq 'unknown counts become null' true "$(jq '.ahead == null and .behind == null and .merged == "?"' "$TEST_ROOT/out")"
meta_set first base=main
invoke show first --json --diff
assert_eq 'JSON and diff conflict' 1 "$(cat "$TEST_ROOT/status")"
assert_eq 'the conflict produces no stdout' '' "$(cat "$TEST_ROOT/out")"
assert_eq 'the conflict reads no sidecar' '' "$(cat "$META_READS")"
end_scenario

begin_scenario 'failed metadata publication preserves the file and cache'
cp "$REPO/.git/wt/first.json" "$TEST_ROOT/before.json"
for failure in serialize rename invalid_json; do
  rc=0
  bash -c '
    source "$1/lib/workgrove/common.sh"
    REPO=$2 failure=$3
    meta_require first
    saved=$WT_META_JSON
    die() { builtin printf "%s\n" "$*" >&2; return 1; }
    printf() {
      if [[ $failure == serialize && $1 == "%s\n" && ${2:-} == \{* ]]; then return 1; fi
      builtin printf "$@"
    }
    mv() { [[ $failure != rename ]] || return 1; command mv "$@"; }
    update=base=changed
    [[ $failure != invalid_json ]] || update="base:=["
    if meta_set first "$update"; then exit 2; fi
    [[ $WT_META_JSON == "$saved" && ${WT_META[base]} == main ]] || exit 3
  ' bash "$SOURCE_REPO" "$REPO" "$failure" >"$TEST_ROOT/write-out" 2>"$TEST_ROOT/write-err" || rc=$?
  assert_eq "$failure reports failure and preserves the cache" 0 "$rc"
  assert_eq "$failure preserves the sidecar" "$(cat "$TEST_ROOT/before.json")" "$(cat "$REPO/.git/wt/first.json")"
done
end_scenario

begin_scenario 'human commands reuse metadata and retain their exit statuses'
for command in 'show first' 'list' 'run first'; do
  read -r -a args <<<"$command"
  invoke "${args[@]}"
  assert_eq "$command succeeds" 0 "$(cat "$TEST_ROOT/status")"
  assert_eq "$command reads its sidecar once" 1 "$(wc -l <"$META_READS" | tr -d ' ')"
done
printf 'unsaved\n' >"$REPO/.worktrees/first/scratch"
for command in 'rm first' 'prune --dry-run'; do
  read -r -a args <<<"$command"
  invoke "${args[@]}"
  assert_eq "$command reads its sidecar once across safety checks" 1 "$(wc -l <"$META_READS" | tr -d ' ')"
done
invoke rm first
assert_eq 'dirty removal keeps exit three' 3 "$(cat "$TEST_ROOT/status")"
rm "$REPO/.worktrees/first/scratch"
end_scenario

begin_scenario 'corrupt sidecars fail safely without partial JSON'
invoke new second --no-workspace -a none
for corrupt in '{' '' '[]' '{} {}' '{"base":"main\u0000suffix"}' '{"key\u0000suffix":"value"}' '{"includes":["a\u0000b"]}' '{"":"value"}'; do
  printf '%s' "$corrupt" >"$REPO/.git/wt/second.json"
  WT_META_FILE=''; local_status=0
  meta_load second values || local_status=$?
  assert_eq 'an unreadable sidecar returns two' 2 "$local_status"
  for command in 'show second' 'show second --json' 'rm second' 'rm second --force' 'list --json'; do
    read -r -a args <<<"$command"
    invoke "${args[@]}"
    assert_eq "$command stops on corrupt metadata" 1 "$(cat "$TEST_ROOT/status")"
    assert_eq "$command names the sidecar" "wt: could not read $REPO/.git/wt/second.json" "$(cat "$TEST_ROOT/err")"
    assert_eq "$command emits no partial output" '' "$(cat "$TEST_ROOT/out")"
  done
done
if [[ -d $REPO/.worktrees/second ]]; then pass; else fail 'corrupt metadata allowed removal'; fi
rm "$REPO/.git/wt/second.json"
invoke show second --json
assert_eq 'a missing sidecar uses defaults' 0 "$(cat "$TEST_ROOT/status")"
rm -rf "$REPO/.worktrees/second"
invoke show second --json
assert_eq 'missing worktree status does not invent clean counts' true "$(jq '.dirty == null and .last_commit_at == null' "$TEST_ROOT/out")"
end_scenario

begin_scenario 'legacy records still protect copied files and explain setup output'
p="$REPO/.worktrees/first"
printf 'copied\n' >"$p/.env"
printf 'setup\n' >"$p/lock"
# Legacy records predate typed copy completion metadata.
jq 'del(.metadata_version,.includes_status)' "$REPO/.git/wt/first.json" >"$TEST_ROOT/legacy.json"
mv "$TEST_ROOT/legacy.json" "$REPO/.git/wt/first.json"
WT_META_FILE=''
meta_set first "includes=.env:$(file_hash "$p/.env")" "setup=lock:$(file_hash "$p/lock")"
assert_eq 'legacy copies remain unchanged' '' "$(changed_includes first "$p")"
assert_eq 'legacy setup explains its own file' .env "$(unexplained_dirt first "$p")"
printf 'edited\n' >"$p/.env"
assert_eq 'legacy copies detect edits' .env "$(changed_includes first "$p")"
end_scenario

begin_scenario 'status preserves the merge cache and cleans isolated comparisons'
printf 'committed\n' >"$p/change"
git -C "$p" add change
git -C "$p" -c user.name=Test -c user.email=test@example.com commit -qm change
WT_MERGE_TREE=''
declare -A n=()
wt_status first n
# shellcheck disable=SC2031  # The associative array uses the literal key name.
assert_eq 'named status returns the task name' first "${n[name]}"
if [[ -n $WT_MERGE_TREE ]]; then pass; else fail 'status lost the merge capability cache'; fi
WT_MERGE_TREE=0
mkdir -p "$TEST_ROOT/proof-temp"
TMPDIR="$TEST_ROOT/proof-temp" wt_status first n
assert_eq 'isolated comparison leaves no temporary index or repository' '' "$(find "$TEST_ROOT/proof-temp" -mindepth 1 -print)"
assert_eq 'unmerged status includes its reason' no "${n[merged]}"
end_scenario

begin_scenario 'named JSON fields tolerate schema additions without shifting records'
saved_fields=$WT_STATUS_FIELDS
WT_STATUS_FIELDS+=' future'
n[future]=$'new value\nwith a newline'
n[title]=first n[task]='brief' n[model]=''
records=()
wt_status_args n records show
assert_eq 'new common fields preserve show fields' true "$(wt_status_json show "${records[@]}" | jq '.future == "new value\nwith a newline" and .title == "first" and .task == "brief" and .model == ""')"
records=()
wt_status_args n records
n[name]=other n[future]='' n[why]=''
wt_status_args n records
assert_eq 'empty values preserve record boundaries' true "$(wt_status_json list "${records[@]}" | jq 'length == 2 and .[0].name == "first" and .[1].name == "other" and .[1].future == "" and .[1].why == ""')"
records=()
n[model]=$'model\n'
wt_status_args n records show
assert_eq 'framing preserves a final value newline' true "$(wt_status_json show "${records[@]}" | jq '.model == "model\n"')"
WT_STATUS_FIELDS=$saved_fields
end_scenario

begin_scenario 'empty JSON lists remain arrays'
mkdir -p "$TEST_ROOT/empty"
git init -qb main "$TEST_ROOT/empty"
git -C "$TEST_ROOT/empty" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
assert_eq 'an empty repo returns an empty array' '[]' "$(bash "$SOURCE_REPO/bin/wt" list --json -r "$TEST_ROOT/empty" | jq -c .)"
end_scenario
begin_scenario 'all repositories produce one array with distinct task paths'
git -C "$TEST_ROOT/empty" worktree add -qb wt/first "$TEST_ROOT/empty/.worktrees/first"
WT_REPOS_DIR="$TEST_ROOT" bash "$SOURCE_REPO/bin/wt" ls --all --json >"$TEST_ROOT/all.json"
assert_eq 'all repos retain duplicate task names' 2 "$(jq '[.[] | select(.name == "first")] | length' "$TEST_ROOT/all.json")"
assert_eq 'repo and path distinguish tasks' 2 "$(jq '[.[] | select(.name == "first") | [.repo,.path]] | unique | length' "$TEST_ROOT/all.json")"
end_scenario

lib_summary
