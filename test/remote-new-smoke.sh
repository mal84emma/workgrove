#!/usr/bin/env bash
# Exercise remote creation failures through scratch ssh/cmux stubs; no real host is contacted.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wt-remote-new.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
case "$TEST_ROOT" in */wt-remote-new.*) ;; *) echo "unsafe test root: $TEST_ROOT" >&2; exit 1 ;; esac
case "$TEST_ROOT/" in "$HOME/"*) echo "test root is inside HOME" >&2; exit 1 ;; esac
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/local/bin" "$TEST_ROOT/remote/.local/bin" "$TEST_ROOT/remote/repo"

cat >"$TEST_ROOT/local/bin/uname" <<'UNAME'
#!/bin/sh
echo Darwin
UNAME
cat >"$TEST_ROOT/local/bin/cmux" <<'CMUX'
#!/bin/sh
printf '%s\n' "$*" >>"$CMUX_LOG"
case "$1" in
  ping) [ "$CMUX_MODE" != down ] ;;
  list-windows) ;;
  workspace) printf '{"workspaces":[]}\n' ;;
  ssh) [ "$CMUX_MODE" != ssh-fail ] || { echo 'row connection failed' >&2; exit 1; }
       echo 'workspace:123' ;;
  workspace-action) ;;
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
HOME="$REMOTE_HOME" WT_AGENT="$REMOTE_DEFAULT_AGENT" PATH="$REMOTE_HOME/.local/bin:/usr/bin:/bin" \
  REMOTE_REPO="$REMOTE_REPO" REMOTE_NEW_MARKER="$REMOTE_NEW_MARKER" bash -c "$cmd"
SSH
cat >"$TEST_ROOT/remote/.local/bin/wt" <<'WT'
#!/bin/sh
case "$1" in
  repos) [ "$2" = wt-demo ] || { echo 'repo not found' >&2; exit 1; }
         printf '%s\n' "$REMOTE_REPO" ;;
  new) cat >/dev/null
       : >"$REMOTE_NEW_MARKER"
       printf 'created task\n  path:   %s/.worktrees/task\n  branch: wt/task (from main)\n  repo:   %s\n  session: wt-repo-task\n' "$REMOTE_REPO" "$REMOTE_REPO" ;;
  list) case "$2" in -r|--repo) printf 'scoped: %s\n' "$3" ;; *) echo 'all repos' ;; esac ;;
  show) [ -e "$REMOTE_NEW_MARKER" ] || exit 1
        printf '  repo: %s\n  session: wt-repo-task (none)\n' "$REMOTE_REPO" ;;
esac
WT
for tool in tmux claude codex; do
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/remote/.local/bin/$tool"
done
chmod +x "$TEST_ROOT/local/bin/"* "$TEST_ROOT/remote/.local/bin/"*

CMUX_MODE=alive SSH_MODE=ok REMOTE_DEFAULT_AGENT=claude
WT_OUT='' WT_RC=0
invoke_wt() {
  WT_RC=0
  WT_OUT=$(env -u CMUX_SSH_ATTEMPT_ID -u CMUX_SOCKET_PATH -u WT_HOST -u WT_AGENT \
    HOME="$TEST_ROOT/local" PATH="$TEST_ROOT/local/bin:$PATH" \
    CMUX_BUNDLED_CLI_PATH="$TEST_ROOT/local/bin/cmux" CMUX_LOG="$TEST_ROOT/cmux.log" \
    SSH_LOG="$TEST_ROOT/ssh.log" CMUX_MODE="$CMUX_MODE" SSH_MODE="$SSH_MODE" \
    REMOTE_HOME="$TEST_ROOT/remote" REMOTE_REPO="$TEST_ROOT/remote/repo" \
    REMOTE_NEW_MARKER="$TEST_ROOT/remote-new" REMOTE_DEFAULT_AGENT="$REMOTE_DEFAULT_AGENT" \
    "${WT_BASH:-bash}" "$REPO/bin/wt" "$@" 2>&1) || WT_RC=$?
}
run_wt() {
  local args=(-H fakevm new task -r "$1")
  [[ -z "$2" ]] || args+=(-a "$2")
  args+=(-p 'test brief')
  invoke_wt "${args[@]}"
}
check() { [[ "$1" ]] || { echo "FAIL: $2; output: $WT_OUT" >&2; exit 1; }; }

# Local cmux failure must stop before the first SSH command.
CMUX_MODE=down
run_wt wt-demo codex
check "$([[ $WT_RC -ne 0 && ! -e "$TEST_ROOT/ssh.log" ]] && echo yes)" 'cmux refusal made an SSH call'

# A missing requested agent or repo must stop before remote new.
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

# A row failure leaves the remote task intact and tells the caller how to recover it.
CMUX_MODE=ssh-fail
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'the worktree was created'* && "$WT_OUT" == *'wt -H fakevm attach --restart-agent -r'* ]] && echo yes)" 'row failure lost recovery information'
CMUX_MODE=alive
invoke_wt -H fakevm attach -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -ne 0 && "$WT_OUT" == *'has no agent pane'* ]] && echo yes)" 'plain attach unexpectedly recovered a task with no agent'
invoke_wt -H fakevm attach --restart-agent -r "$TEST_ROOT/remote/repo" task
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == *'row: repo:task @fakevm'* ]] && echo yes)" 'restart-agent did not recover after row failure'
rm "$TEST_ROOT/remote-new"

# SSH can drop after remote creation but before its output reaches the Mac.
CMUX_MODE=alive SSH_MODE=lost
run_wt wt-demo claude
check "$([[ $WT_RC -ne 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'could not confirm whether a worktree was created'* && "$WT_OUT" == *'wt -H fakevm list -r wt-demo'* ]] && echo yes)" 'ambiguous SSH outcome was treated as safe to retry'
SSH_MODE=ok
invoke_wt -H fakevm list -r "$TEST_ROOT/remote/repo"
check "$([[ $WT_RC -eq 0 && "$WT_OUT" == "scoped: $TEST_ROOT/remote/repo" ]] && echo yes)" 'remote list ignored a repo outside WT_REPOS_DIR'
rm "$TEST_ROOT/remote-new"

# A healthy path still creates and reports the row.
SSH_MODE=ok
run_wt wt-demo claude
check "$([[ $WT_RC -eq 0 && -e "$TEST_ROOT/remote-new" && "$WT_OUT" == *'row: repo:task @fakevm'* ]] && echo yes)" 'healthy remote creation failed'
echo 'remote new smoke test: ok'
