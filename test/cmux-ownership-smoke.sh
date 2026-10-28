#!/usr/bin/env bash
# Check native process snapshots without opening or closing real rows.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
source "$REPO/test/lib.sh"
source "$REPO/lib/workgrove/common.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-cmux-ownership.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
STATE="$ROOT/state.json"
cmux_call() { cat "$STATE"; }
begin_scenario 'native process ownership and idle launch binding'
MODE=gone
ps() {
  local pid=$2 field=${4:-}
  case $field in
    comm=) [[ $pid != 100 ]] || { echo claude; return; }; [[ $MODE != ssh ]] || { echo /usr/bin/ssh; return; }; echo bash ;;
    command=) echo claude ;;
    lstart=) echo 'fixed identity' ;;
    tty=) echo ttys999 ;;
    ppid=) case $pid in 90) echo 1 ;; 100) echo 90 ;; 101|102) [[ $MODE == live ]] && echo 90 || return 1 ;; *) echo 100 ;; esac ;;
    pid=) if [[ $MODE == unreadable ]]; then echo denied >&2; return 1; fi
          [[ $MODE == live ]] && echo "$pid" || return 1 ;;
    *) return 1 ;;
  esac
}
write_sample() {
  python3 - "$STATE" "$1" <<'PY'
import json,sys
path,mode=sys.argv[1:]
pids=[90,100,101]
nodes=[dict(kind='process',pid=p,ppid=parent,children=[]) for p,parent in ((90,1),(100,90),(101,100))]
if mode=='sibling': nodes[2]['ppid']=90
if mode=='missing': nodes.pop()
if mode=='cycle':
 pids.append(102);nodes[2]['ppid']=102;nodes.append(dict(kind='process',pid=102,ppid=101,children=[]))
if mode=='duplicate':nodes.append(nodes[2])
surface=dict(processes=nodes,tty_process_pids=pids,unattributed_tty_process_pids=[],tty_ownership_reasons={})
row=dict(id='target',resources=dict(pids=pids,process_count=len(pids),missing_pids=[]),panes=[dict(surfaces=[surface])])
agents=[dict(resources=dict(pids=[100],process_count=1))]
if mode=='idle':
 row['resources'].update(pids=[90],process_count=1);surface['processes']=nodes[:1];surface['tty_process_pids']=[90]
 surface['tty_ownership_reasons']={'90':'tty-session-root'};agents=[]
if mode in ('unattributed','incomplete'):
 row['resources'].update(pids=[],process_count=0);surface['processes']=[];surface['tty_process_pids']=[555]
 surface['unattributed_tty_process_pids']=[555]
 surface['unattributed_resources']=dict(pids=[555],process_count=1,missing_pids=[])
 agents=[dict(resources=dict(pids=[555],process_count=1))]
 if mode=='incomplete':
  surface['tty_process_pids']=[];surface['unattributed_tty_process_pids']=[];surface['unattributed_resources']['pids']=[];agents=[]
json.dump(dict(include_processes=True,coding_agents=agents,windows=[dict(workspaces=[row])]),open(path,'w'))
PY
}
row_result() {
  local rc=0
  row_agent target || rc=$?
  printf '%s %s' "$rc" "$ROW_AGENT"
}
write_sample owned
assert_eq 'expired owned sampler descendants remain removable' '0 self' "$(row_result)"
for sample in sibling missing cycle duplicate; do
  write_sample "$sample"
  assert_eq 'unproven expired processes refuse' '1 busy' "$(row_result)"
done
write_sample owned
MODE=live
assert_eq 'live independent PID reuse cannot use old ancestry' '0 busy' "$(row_result)"
MODE=unreadable
assert_eq 'unreadable process state cannot establish absence' '0 busy' "$(row_result)"
MODE=gone
write_sample unattributed
assert_eq 'an unattributed provider cannot become an idle row' '1 busy' "$(row_result)"
write_sample incomplete
assert_eq 'an incomplete unattributed count refuses' '1 busy' "$(row_result)"
write_sample idle
assert_eq 'normal attributed terminal PIDs permit idle rows' '0 idle' "$(row_result)"
for invalid_pids in '[null]' '["unknown"]' '[0]' '[1]' '[-2]' '[2.5]' '[90,90]'; do
  write_sample idle
  python3 - "$STATE" "$invalid_pids" <<'PY'
import json,sys
path=sys.argv[1];sample=json.load(open(path));pids=json.loads(sys.argv[2])
row=sample['windows'][0]['workspaces'][0]
row['resources'].update(pids=pids,process_count=len(pids))
json.dump(sample,open(path,'w'))
PY
  assert_eq 'malformed idle row PIDs cannot authorize removal' '1 busy' "$(row_result)"
  MODE=ssh
  rc=0; remote_row_idle target || rc=$?
  assert_eq 'malformed relay row PIDs cannot authorize closure' 1 "$rc"
  MODE=gone
done
write_sample idle
MODE=ssh
rc=0; remote_row_idle target || rc=$?
assert_eq 'normal attributed SSH transport remains closable' 0 "$rc"

CMUX_SURFACE_ID='surface-id'
cat >"$STATE" <<'JSON'
{"windows":[{"workspaces":[{"id":"target","panes":[{"surfaces":[{"id":"surface-id","type":"terminal","tty":"ttys999"}]}]}]}]}
JSON
rc=0; codex_launch_row target "$BASHPID" '{"windows":[{"workspaces":[{"id":"target","resources":{"pids":[]}}]}]}' || rc=$?
assert_eq 'a unique physical terminal can bind an idle launcher' 0 "$rc"
python3 - "$STATE" <<'PY'
import json,sys
p=sys.argv[1];x=json.load(open(p));x['windows'][0]['workspaces'].append(dict(id='other',panes=[dict(surfaces=[dict(id='other-surface',type='terminal',tty='ttys999')])]))
json.dump(x,open(p,'w'))
PY
rc=0; codex_launch_row target "$BASHPID" '{"windows":[]}' || rc=$?
assert_eq 'duplicate terminal ownership refuses launch binding' 1 "$rc"
line=$(local_run_line '/candidate with space/wt' own '/fixture repo')
result=$(python3 - "$line" <<'PYCODE'
import shlex,sys
outer=shlex.split(sys.argv[1])
assert outer[:2]==['bash','-c'] and len(outer)==3
inner=shlex.split(outer[2])
assert inner==['exec','/candidate with space/wt','run','own','-r','/fixture repo']
print('valid')
PYCODE
)
assert_eq 'local launch prevents sibling watchers without changing provider arguments' valid "$result"
tmux() {
  case $1 in
    has-session) return 0 ;;
    list-panes) [[ $4 == '=target:' ]] && echo /dev/pts/111 || echo /dev/pts/222 ;;
    display-message)
      [[ $4 == '=target:' ]] || return 0
      case $5 in '#{session_id}') echo "\$7" ;; '#{session_created}') echo 123 ;;
        '#{socket_path}') echo /tmp/fake-tmux ;; '#{pid}') echo 88 ;; esac ;;
    *) return 1 ;;
  esac
}
pgrep() { [[ $2 == pts/111 ]] && echo 100 || return 1; }
rc=0; tmux_agent target || rc=$?
assert_eq 'a same-named window cannot hide the actual task provider' 0 "$rc"
identity=$(task_tmux_identity target)
assert_eq 'session identity uses a qualified pane target' "\$7" "$(jq -r .id <<<"$identity")"
end_scenario
lib_summary
