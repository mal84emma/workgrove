#!/usr/bin/env bash
# Exercise remote creation failures with scratch ssh and cmux stubs. The suite contacts no real host.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-remote-new.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
case "$TEST_ROOT" in */wt-remote-new.*) ;; *) echo "unsafe test root: $TEST_ROOT" >&2; exit 1 ;; esac
case "$TEST_ROOT/" in "$HOME/"*) echo "test root is inside HOME" >&2; exit 1 ;; esac
# shellcheck source=test/lib.sh
# shellcheck disable=SC1091
source "$REPO/test/lib.sh"
# shellcheck disable=SC2034
KEEP_LABEL='remote task test files'
trap lib_cleanup EXIT
mkdir -p "$TEST_ROOT/local/bin" "$TEST_ROOT/remote/.local/bin" "$TEST_ROOT/remote/repo"

cat >"$TEST_ROOT/local/bin/uname" <<'UNAME'
#!/bin/sh
echo Darwin
UNAME
# The row modes: "existing" has this task's row, "legacy" has it with the title of an older wt, and
# "other-repo" has a row of another repo's task with the same name. "no-ref" is "other-repo" with a create
# that prints no workspace ref; the row that the create adds shows up in the next list. "no-ref-blind" is
# "no-ref" with a row list that fails until the create, so wt has no list of the rows from before it.
# "no-ref-own" has the user's own row with the task's title and no repo, and a create that prints no ref.
# "race" lists no row the first time and this task's row after that. "tag-fail" and "race" make every
# description write fail.
cat >"$TEST_ROOT/local/bin/cmux" <<'CMUX'
#!/bin/sh
printf '%s\n' "$*" >>"$CMUX_LOG"
row() { printf '{"id":"%s","title":"%s","description":"%s","remote":{"enabled":true,"destination":"fakevm"}}' "$1" "$2" "$3"; }
case "$1" in
  ping) [ "$CMUX_MODE" != down ] ;;
  list-windows) ;;
  workspace) case "$CMUX_MODE" in
               existing) printf '{"workspaces":[%s]}\n' "$(row workspace:123 task '@fakevm · repo')" ;;
               legacy) printf '{"workspaces":[%s]}\n' "$(row workspace:123 repo:task @fakevm)" ;;
               other-repo) printf '{"workspaces":[%s]}\n' "$(row other-row task '@fakevm · other')" ;;
               no-ref) if [ -e "$CMUX_LOG.created" ]; then
                         printf '{"workspaces":[%s,%s]}\n' "$(row other-row task '@fakevm · other')" \
                           '{"id":"new-row","title":"task","remote":{"enabled":true,"destination":"fakevm"}}'
                       else printf '{"workspaces":[%s]}\n' "$(row other-row task '@fakevm · other')"; fi ;;
               no-ref-blind) [ -e "$CMUX_LOG.created" ] || exit 1
                             printf '{"workspaces":[%s,%s]}\n' "$(row other-row task '@fakevm · other')" \
                               '{"id":"new-row","title":"task","remote":{"enabled":true,"destination":"fakevm"}}' ;;
               no-ref-own) if [ -e "$CMUX_LOG.created" ]; then
                             printf '{"workspaces":[%s,%s]}\n' "$(row user-row task '')" \
                               '{"id":"new-row","title":"task","remote":{"enabled":true,"destination":"fakevm"}}'
                           else printf '{"workspaces":[%s]}\n' "$(row user-row task '')"; fi ;;
               race) if [ -e "$CMUX_LOG.listed" ]; then printf '{"workspaces":[%s]}\n' "$(row race-row task '@fakevm · repo')"
                     else : >"$CMUX_LOG.listed"; printf '{"workspaces":[]}\n'; fi ;;
               *) printf '{"workspaces":[]}\n' ;;
             esac ;;
  ssh) [ "$CMUX_MODE" != ssh-fail ] || { echo 'row connection failed' >&2; exit 1; }
       case "$CMUX_MODE" in no-ref*) : >"$CMUX_LOG.created"; echo OK ;; *) echo 'workspace:123' ;; esac ;;
  workspace-action) case "$CMUX_MODE" in tag-fail|race) exit 1 ;; esac ;;
esac
CMUX
cat >"$TEST_ROOT/local/bin/ssh" <<'SSH'
#!/usr/bin/env bash
cmd="${@: -1}"
printf '%s\n' "$cmd" >>"$SSH_LOG"
if [[ "$SSH_MODE" == lost && "$cmd" == *' new '* ]]; then
  HOME="$REMOTE_HOME" WT_AGENT="$REMOTE_DEFAULT_AGENT" PATH="$REMOTE_HOME/.local/bin:/usr/bin:/bin" \
    REMOTE_REPO="$REMOTE_REPO" REMOTE_NEW_MARKER="$REMOTE_NEW_MARKER" bash -c "$cmd" >/dev/null
  exit 255
fi
if [[ "$SSH_MODE" == refuse && "$cmd" == *' new '* ]]; then
  echo "worktree 'task' already exists" >&2
  exit 1
fi
HOME="$REMOTE_HOME" WT_AGENT="$REMOTE_DEFAULT_AGENT" PATH="$REMOTE_HOME/.local/bin:/usr/bin:/bin" \
  REMOTE_REPO="$REMOTE_REPO" REMOTE_NEW_MARKER="$REMOTE_NEW_MARKER" \
  REMOTE_OUTPUT_MODE="${REMOTE_OUTPUT_MODE:-normal}" bash -c "$cmd"
SSH
cat >"$TEST_ROOT/remote/.local/bin/wt" <<'WT'
#!/bin/sh
case "$1" in
  repos) [ "$2" = wt-demo ] || { echo 'repo not found' >&2; exit 1; }
         printf '%s\n' "$REMOTE_REPO" ;;
  new) if [ "$REMOTE_OUTPUT_MODE" = old ]; then
         for arg in "$@"; do
           case "$arg" in -m|--model) echo "wt: new: unknown option $arg" >&2; exit 1 ;; esac
         done
       fi
       mkdir -p "$REMOTE_REPO/.worktrees/task" "$REMOTE_REPO/.git/wt"
       cat >"$REMOTE_REPO/.git/wt/task.prompt"
       printf '%s\n' "$@" >"$REMOTE_NEW_MARKER.args"
       agent=claude model=
       while [ "$#" -gt 0 ]; do
         case "$1" in
           -a|--agent) agent=$2; shift ;;
           -m|--model) model=$2; shift ;;
         esac
         shift
       done
       printf '{"agent":"%s","model":"%s"}\n' "$agent" "$model" >"$REMOTE_REPO/.git/wt/task.json"
       : >"$REMOTE_NEW_MARKER"
       [ "$REMOTE_OUTPUT_MODE" != bad ] || { echo 'created ???'; exit 0; }
       printf 'created task\n  path:   %s/.worktrees/task\n  branch: wt/task (from main)\n  repo:   %s\n  session: wt-repo-task\n' "$REMOTE_REPO" "$REMOTE_REPO" ;;
  list) case "$2" in -r|--repo) printf 'scoped: %s\n' "$3" ;; *) echo 'all repos' ;; esac ;;
  show) [ -e "$REMOTE_NEW_MARKER" ] || exit 1
        printf '  repo: %s\n  session: wt-repo-task (none)\n' "$REMOTE_REPO" ;;
esac
WT
cat >"$TEST_ROOT/remote/.local/bin/tmux" <<'TMUX'
#!/bin/sh
if [ "$1" = has-session ]; then echo 'no server running on /tmp/fake' >&2; exit 1; fi
TMUX
for tool in claude codex; do
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/remote/.local/bin/$tool"
done
printf '#!/bin/sh\nexit 1\n' >"$TEST_ROOT/local/bin/fzf"   # wt task needs fzf only for the pickers that --where and -a skip
chmod +x "$TEST_ROOT/local/bin/"* "$TEST_ROOT/remote/.local/bin/"*

CMUX_MODE=alive SSH_MODE=ok REMOTE_DEFAULT_AGENT=claude
WT_OUT='' WT_RC=0
invoke_wt() {
  WT_RC=0
  WT_OUT=$(env -u CMUX_SSH_ATTEMPT_ID -u CMUX_SOCKET_PATH -u WT_HOST -u WT_AGENT \
    HOME="$TEST_ROOT/local" PATH="$TEST_ROOT/local/bin:$PATH" \
    CMUX_BUNDLED_CLI_PATH="$TEST_ROOT/local/bin/cmux" CMUX_LOG="$TEST_ROOT/cmux.log" \
    SSH_LOG="$TEST_ROOT/ssh.log" CMUX_MODE="$CMUX_MODE" SSH_MODE="$SSH_MODE" \
    REMOTE_OUTPUT_MODE="${REMOTE_OUTPUT_MODE:-normal}" \
    REMOTE_HOME="$TEST_ROOT/remote" REMOTE_REPO="$TEST_ROOT/remote/repo" \
    REMOTE_NEW_MARKER="$TEST_ROOT/remote-new" REMOTE_DEFAULT_AGENT="$REMOTE_DEFAULT_AGENT" \
    "${WT_BASH:-bash}" "$REPO/bin/wt" "$@" 2>&1) || WT_RC=$?
}
run_wt() {
  local args=(-H fakevm new task -r "$1")
  [[ -z "$2" ]] || args+=(-a "$2")
  [[ -z "${3:-}" ]] || args+=(-m "$3")
  args+=(-p 'test brief')
  invoke_wt "${args[@]}"
}
check() { if [[ "$1" ]]; then pass; else fail "$2; output: $WT_OUT"; fi; }

begin_scenario 'remote preflight and recovery'

# A local cmux failure must stop creation before the first SSH command.
CMUX_MODE=down
run_wt wt-demo codex
check "$([[ $WT_RC -ne 0 && ! -e "$TEST_ROOT/ssh.log" ]] && echo yes)" 'cmux refusal made an SSH call'

# If the requested agent or repo is missing, creation must stop before remote new.
CMUX_MODE=alive
rm "$TEST_ROOT/remote/.local/bin/codex"
run_wt wt-demo codex
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'remote agent is missing: codex'* && ! -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'missing agent did not stop creation'
REMOTE_DEFAULT_AGENT=codex
run_wt wt-demo ''
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'remote agent is missing: codex'* && ! -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'remote default agent was not checked'
REMOTE_DEFAULT_AGENT=claude
run_wt missing-repo claude
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'repo not found'* && ! -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'missing repo did not stop creation'

# A deferred task keeps its saved choices and does not touch cmux.
# The first attach starts its saved command.
CMUX_MODE=down
: >"$TEST_ROOT/cmux.log"
invoke_wt -H fakevm new task -r wt-demo -a claude -m 'opus[1m]' -p 'deferred brief' --no-workspace
check "$([[ $WT_RC -eq 0 && -d "$TEST_ROOT/remote/repo/.worktrees/task" && "$WT_OUT" == *'start later: wt -H fakevm attach -r'* ]] && echo yes)" 'deferred remote task was not created'
check "$([[ $(cat "$TEST_ROOT/remote/repo/.git/wt/task.prompt") == 'deferred brief' && $(jq -r .agent "$TEST_ROOT/remote/repo/.git/wt/task.json") == claude && $(jq -r .model "$TEST_ROOT/remote/repo/.git/wt/task.json") == 'opus[1m]' ]] && echo yes)" 'deferred task lost its brief, agent or model'
check "$([[ ! -e "$TEST_ROOT/remote/repo/.git/wt/task.started" ]] && ! grep -q '^ssh ' "$TEST_ROOT/cmux.log" && echo yes)" 'deferred task started an agent or row'
CMUX_MODE=alive
: >"$TEST_ROOT/cmux.log"
invoke_wt -H fakevm attach -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == *'row: task @fakevm · repo'* ]] && grep -qF 'run\ task' "$TEST_ROOT/cmux.log" && echo yes)" 'first attach did not start the saved agent command'
: >"$TEST_ROOT/remote/repo/.git/wt/task.started"
invoke_wt -H fakevm attach -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'has no agent pane (none)'* && "$WT_OUT" == *'--restart-agent'* ]] && echo yes)" 'lost started task did not require restart-agent'
rm "$TEST_ROOT/remote/repo/.git/wt/task.started" "$TEST_ROOT/remote-new"

# A row failure leaves the remote task intact and tells the caller how to recover it.
CMUX_MODE=ssh-fail
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'the worktree was created'* && "$WT_OUT" == *'wt -H fakevm attach --restart-agent -r'* ]] && echo yes)" 'row failure lost recovery information'
CMUX_MODE=alive
invoke_wt -H fakevm attach -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == *'row: task @fakevm · repo'* ]] && echo yes)" 'plain attach did not recover a never-started task'
invoke_wt -H fakevm attach --restart-agent -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == *'row: task @fakevm · repo'* ]] && echo yes)" 'restart-agent did not recover after row failure'
cat >"$TEST_ROOT/remote/.local/bin/tmux" <<'TMUX'
#!/bin/sh
echo 'error connecting to tmux socket (Operation not permitted)' >&2
exit 1
TMUX
invoke_wt -H fakevm attach --restart-agent -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'cannot check the agent in tmux session'* && -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'restart-agent did not refuse unreadable session status'
cat >"$TEST_ROOT/remote/.local/bin/tmux" <<'TMUX'
#!/bin/sh
if [ "$1" = has-session ]; then echo 'no server running on /tmp/fake' >&2; exit 1; fi
TMUX
rm "$TEST_ROOT/remote-new"

# SSH can drop after remote creation but before its output reaches the Mac.
CMUX_MODE=alive SSH_MODE=lost
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'could not confirm whether a worktree was created'* && "$WT_OUT" == *'wt -H fakevm list -r wt-demo'* ]] && echo yes)" 'ambiguous SSH outcome was treated as safe to retry'
SSH_MODE=ok
invoke_wt -H fakevm list -r "$TEST_ROOT/remote/repo"
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == "scoped: $TEST_ROOT/remote/repo" ]] && echo yes)" 'remote list ignored a repo outside WT_REPOS_DIR'
rm "$TEST_ROOT/remote-new"

# A healthy path still creates and reports the row. The row's title is the task name, and its description
# names the host and the repo.
SSH_MODE=ok
: >"$TEST_ROOT/cmux.log"
run_wt wt-demo claude 'opus[1m]'
check "$([[ $WT_RC -eq 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'row: task @fakevm · repo'* ]] && echo yes)" 'healthy remote creation failed'
check "$(grep -qF -- 'ssh fakevm --name task --no-focus ' "$TEST_ROOT/cmux.log" && grep -qxF -- 'workspace-action --workspace workspace:123 --action set-description --description @fakevm · repo' "$TEST_ROOT/cmux.log" && echo yes)" 'new row did not get the task name as its title and the host and repo as its description'
check "$([[ $(grep -xcF -- '-m' "$TEST_ROOT/remote-new.args") -eq 1 && $(grep -xcF -- 'opus[1m]' "$TEST_ROOT/remote-new.args") -eq 1 ]] && echo yes)" 'remote model flag or value was not forwarded intact'
rm "$TEST_ROOT/remote-new"

# An old VM parser rejects the -m option before it makes a task, and the Mac names the update command.
REMOTE_OUTPUT_MODE=old
run_wt wt-demo claude fable
check "$([[ $WT_RC -ne 0 && ! -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'wt -H fakevm update'* ]] && echo yes)" 'old remote wt did not give a safe update path'
run_wt wt-demo claude
check "$([[ $WT_RC -eq 0 && -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'old remote fake rejected a task without -m'
rm "$TEST_ROOT/remote-new"
REMOTE_OUTPUT_MODE=normal

run_wt wt-demo claude 'two words'
check "$([[ $WT_RC -ne 0 && ! -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'invalid model'* ]] && echo yes)" 'invalid remote model reached task creation'

# The VM parser does not accept combined spellings, so the Mac rejects them before any SSH call.
rm -f "$TEST_ROOT/ssh.log"
invoke_wt -H fakevm new task -r wt-demo --model=fable
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'use -m <model>'* && ! -e "$TEST_ROOT/ssh.log" && ! -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'combined long model option reached SSH'
invoke_wt -H fakevm new task -r wt-demo -mfable
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'use -m <model>'* && ! -e "$TEST_ROOT/ssh.log" && ! -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'combined short model option reached SSH'

# With the Mac hook installed, task creation enables the bridge and does not reload all cmux settings.
mkdir -p "$TEST_ROOT/local/.local/bin" "$TEST_ROOT/local/.config/cmux"
printf 'CMUX_NOTIFICATION_SUBTITLE\n' > "$TEST_ROOT/local/.local/bin/cmux-hook"
printf '{"notifications":{"hooks":[{"id":"wt","command":"~/.local/bin/cmux-hook"}]}}\n' > "$TEST_ROOT/local/.config/cmux/cmux.json"
: > "$TEST_ROOT/cmux.log"
run_wt wt-demo claude
check "$([[ $WT_RC -eq 0 ]] && grep -qF 'WT_STATUS_BRIDGE=1' "$TEST_ROOT/cmux.log" && ! grep -qF 'reload-config' "$TEST_ROOT/cmux.log" && echo yes)" 'installed hook did not enable bridge cleanly'
rm "$TEST_ROOT/remote-new" "$TEST_ROOT/local/.local/bin/cmux-hook" "$TEST_ROOT/local/.config/cmux/cmux.json"

# A normal remote refusal is definite and should not claim an uncertain SSH outcome.
SSH_MODE=refuse
run_wt wt-demo claude
check "$([[ $WT_RC -eq 1 && "$WT_OUT" == *"worktree 'task' already exists"* && "$WT_OUT" != *'could not confirm'* && ! -e "$TEST_ROOT/remote-new" ]] && echo yes)" 'VM refusal was described as a disconnect'
SSH_MODE=ok

# A success with malformed output may still have created the task, so the Mac prints an inspection path.
REMOTE_OUTPUT_MODE=bad
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'inspect with: wt -H fakevm list -r wt-demo'* ]] && echo yes)" 'malformed success omitted inspection advice'
REMOTE_OUTPUT_MODE=normal
rm "$TEST_ROOT/remote-new"

# A row that remains after an older task was removed must not make the new task look started.
CMUX_MODE=existing
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'row for this task is already open'* && "$WT_OUT" == *'attach --restart-agent'* ]] && echo yes)" 'leftover row falsely reported success'
rm "$TEST_ROOT/remote-new"

# A row that an older wt titled "<repo>:<name>" is still this task's row.
CMUX_MODE=legacy
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'row for this task is already open'* ]] && echo yes)" 'leftover row with the old title was not found'
rm "$TEST_ROOT/remote-new"

# A task of another repo can have the same name. Its row does not block this task, which gets a row of its own.
CMUX_MODE=other-repo
: >"$TEST_ROOT/cmux.log"
run_wt wt-demo claude
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == *'row: task @fakevm · repo'* ]] && grep -qF -- 'ssh fakevm --name task ' "$TEST_ROOT/cmux.log" && echo yes)" 'a same-named task of another repo blocked the row'
check "$(grep -qxF -- 'workspace-action --workspace workspace:123 --action set-description --description @fakevm · repo' "$TEST_ROOT/cmux.log" && ! grep -qF -- 'other-row' "$TEST_ROOT/cmux.log" && echo yes)" 'the new row did not get its own description'
# attach does not take the other repo's row either.
: >"$TEST_ROOT/cmux.log"
invoke_wt -H fakevm attach -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == *'row: task @fakevm · repo'* && "$WT_OUT" != *'already open'* ]] && grep -qF -- 'ssh fakevm --name task ' "$TEST_ROOT/cmux.log" && ! grep -qF -- 'other-row' "$TEST_ROOT/cmux.log" && echo yes)" 'attach took the row of a same-named task in another repo'
rm "$TEST_ROOT/remote-new"

# When the create prints no workspace ref, wt describes the row that the create added, not the other repo's row.
CMUX_MODE=no-ref
: >"$TEST_ROOT/cmux.log"
run_wt wt-demo claude
check "$([[ $WT_RC -eq 0 ]] && grep -qxF -- 'workspace-action --workspace new-row --action set-description --description @fakevm · repo' "$TEST_ROOT/cmux.log" && ! grep -qF -- 'other-row' "$TEST_ROOT/cmux.log" && echo yes)" 'the description went to a row that the create did not add'
rm -f "$TEST_ROOT/remote-new" "$TEST_ROOT/cmux.log.created"

# An older row with the task's title and no repo, such as the user's own `cmux ssh` row, is not the new one.
CMUX_MODE=no-ref-own
: >"$TEST_ROOT/cmux.log"
run_wt wt-demo claude
check "$([[ $WT_RC -eq 0 ]] && grep -qxF -- 'workspace-action --workspace new-row --action set-description --description @fakevm · repo' "$TEST_ROOT/cmux.log" && ! grep -qF -- 'user-row' "$TEST_ROOT/cmux.log" && echo yes)" 'the description went to an older row with the same title'
rm -f "$TEST_ROOT/remote-new" "$TEST_ROOT/cmux.log.created"

# With no list from before the create, any row could look new. So wt does not guess, and writes no description.
CMUX_MODE=no-ref-blind
: >"$TEST_ROOT/cmux.log"
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'row list from before the create was unreadable'* && "$WT_OUT" == *'wt -H fakevm attach -r'* ]] && ! grep -qF -- 'workspace-action' "$TEST_ROOT/cmux.log" && echo yes)" 'with no list from before the create, wt guessed which row was new'
rm -f "$TEST_ROOT/remote-new" "$TEST_ROOT/cmux.log.created"

# The description holds the repo, so a new row without it would be found by no later lookup. wt closes the
# row and fails, and the recovery advice applies to the task as it is.
CMUX_MODE=tag-fail
: >"$TEST_ROOT/cmux.log"
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'so wt closed that row'* && "$WT_OUT" == *'wt -H fakevm attach -r'* ]] && grep -qxF -- 'workspace close workspace:123' "$TEST_ROOT/cmux.log" && echo yes)" 'a new row without its description was left open'
rm "$TEST_ROOT/remote-new"
# A shell row has no repo, and a lookup finds it by its title and host. So a failed write leaves it open.
: >"$TEST_ROOT/cmux.log"
invoke_wt task --where fakevm -a vm-shell </dev/null
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'cmux workspace-action failed; run:'* ]] && grep -qF -- 'ssh fakevm --name shell ' "$TEST_ROOT/cmux.log" && ! grep -qF -- 'workspace close' "$TEST_ROOT/cmux.log" && echo yes)" 'a new shell row was closed for a failed description'

# A row that a lookup found is never closed, even when its description cannot be rewritten. Here attach's
# own lookup finds no row, and remote_row's lookup finds the row that appeared since.
CMUX_MODE=alive
run_wt wt-demo claude
CMUX_MODE=race
: >"$TEST_ROOT/cmux.log"
invoke_wt -H fakevm attach -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'cmux workspace-action failed; run:'* ]] && grep -qF -- 'workspace-action --workspace race-row ' "$TEST_ROOT/cmux.log" && ! grep -qF -- 'workspace close' "$TEST_ROOT/cmux.log" && echo yes)" 'a row that a lookup found was closed for a failed description'
rm -f "$TEST_ROOT/remote-new" "$TEST_ROOT/cmux.log.listed"
CMUX_MODE=alive
end_scenario

begin_scenario 'interrupted setup retains the brief, agent and model'
SCRATCH_REPO="$TEST_ROOT/local-repo"
git init -q "$SCRATCH_REPO"
git -C "$SCRATCH_REPO" config user.name Test
git -C "$SCRATCH_REPO" config user.email test@example.invalid
git -C "$SCRATCH_REPO" commit -q --allow-empty -m initial
cat >"$SCRATCH_REPO/.wt-setup" <<'SETUP'
#!/bin/sh
printf 'setup began\n'
sleep .2
printf 'setup output after reader closes\n'
SETUP
chmod +x "$SCRATCH_REPO/.wt-setup"
set +o pipefail
printf 'the brief' | env HOME="$TEST_ROOT/local" PATH="$TEST_ROOT/local/bin:$PATH" \
  "${WT_BASH:-bash}" "$REPO/bin/wt" new task -r "$SCRATCH_REPO" -a codex -m gpt-5.3-codex --no-workspace --prompt-stdin 2>&1 | head -n 1 >/dev/null || true
set -o pipefail
check "$([[ -d "$SCRATCH_REPO/.worktrees/task" && -f "$SCRATCH_REPO/.git/wt/task.json" && -f "$SCRATCH_REPO/.git/wt/task.prompt" ]] && echo yes)" 'interrupted setup lost task metadata'
check "$([[ $(cat "$SCRATCH_REPO/.git/wt/task.prompt") == 'the brief' && $(jq -r .agent "$SCRATCH_REPO/.git/wt/task.json") == codex && $(jq -r .model "$SCRATCH_REPO/.git/wt/task.json") == gpt-5.3-codex ]] && echo yes)" 'interrupted setup lost brief, agent or model choice'
end_scenario

lib_summary 39
