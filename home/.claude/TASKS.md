# Task-management reference

Read the relevant section when [the shared conventions](AGENTS.md) direct you here.
Use the linked skills for procedures that they already contain.
Read this file on demand.

## Worktree rules

- Inside `.worktrees/<name>`, stay there for task work and commit on `wt/<name>`.
  Make small commits and describe each one.
  Never edit the main checkout or sibling worktrees, switch branches, or create nested worktrees.
  Keep dependencies and environment settings inside the worktree. Do not use the main checkout's copies.
  These conventions provide no sandbox or Claude worktree isolation.
- Split work only when the parts touch different files. Give each part its own worktree and agent session.
- Do not code in a driver session. Start a task session for that work.
- Remove worktrees only with `wt rm` or `wt prune`, and only when the user asks.
- Never use `--force` or `--discard-commits` unless the user authorizes that flag in this conversation.
- Add `.wt-include` and `.wt-setup` only when the user asks.

## Task lifecycle

- For an explicitly requested quick edit in the main checkout, use the [core exception](AGENTS.md#tasks-run-in-worktrees).
- For other tasks, features, fixes, or experiments, choose the skill for your current location.
  If you are inside a worktree, use the [worktree-work skill](../.agents/skills/worktree-work/SKILL.md) and work there.
  Otherwise, use the [worktree-create skill](../.agents/skills/worktree-create/SKILL.md) to run `wt new <name> -p "<brief>"` first.
- For several independent tasks, create one worktree per task with `wt new ... -p ...`.
  Each worktree gets its own agent session in cmux.
  Use the [task-driver skill](../.agents/skills/task-driver/SKILL.md) to drive several tasks, or VM tasks, from one session.
- For "show me the code", "open the worktree", or "let me see it", use the [worktree-show skill](../.agents/skills/worktree-show/SKILL.md).
  Run `wt open`, which opens the worktree in VS Code.
- For task status or changes, run `wt list` and `wt show <name>`.
  Examples include "what changed" and "how far is it".
  Give a short summary, as the worktree-show skill describes.
- For "what tasks are running" or "list the worktrees", run `wt list` and summarize.
- For authorized cleanup, use the [worktree-teardown skill](../.agents/skills/worktree-teardown/SKILL.md).
  To remove your own worktree, change to the main checkout and run `wt rm` from there.

## GitHub writes and publishing

Follow the [core prohibitions](AGENTS.md#github-writes-and-publishing).
These briefs count as requests for only the listed GitHub writes:

| Brief | Authorized actions |
|---|---|
| Work on an open pull request, such as addressing its review or fixing its continuous integration (CI) | Push to that pull request's branch. Reply to its review comments. Edit your own review comments on it. Resolve its review comments. |
| Review a pull request | Post the review. |
| Work on an issue | Comment on the issue. Edit the issue and your comments on it, but only where this login wrote them. |

"This login" means the account that `gh` is logged in as.
Each brief authorizes only its listed actions, and nothing more.

## Run approved GitHub commands

Claude's `github-guard` hook approves the forms below without a prompt, in this repository only.
The hook denies other GitHub writes with a reason that names the approved form.
Read that reason and retry.

Write each command so that the hook can approve it:

- Run each one as its own command, with no pipe, `&&`, `$(…)` or `cd … &&` in front.
- To filter output, use `--jq '<expr>'`.
- To pass long text, use `--body-file <file in the repo or a temp dir>`.
- Quote an endpoint that contains `?` or `&`.

The approved forms are:

- **Read:**
  - `gh api <endpoint>`
  - `gh api graphql -f query='…'`
  - `gh pr view|diff|checks|list|status`
  - `gh issue view|list|status`
- **Push:** `git push [-u] origin HEAD[:<branch>]`
  - The form also accepts a local branch by name instead of `HEAD`, but never a tag.
  - The hook always denies `main`, `master`, and the default branch.
  - The form is never forced, and it never pushes more than one branch.
- **Open a pull request or an issue:**
  - `gh pr create --title '…' --body '…'` (or `--fill`)
  - `wt pr <name>`
  - `gh issue create --title '…' --body '…' [--label …]`
  - Do not use `--template`. Read the repository's template and pass the filled-in text.
- **Comment and review:**
  - `gh pr comment <n> --body '…'` or `gh issue comment <n> --body '…'`.
    Add `--edit-last` to fix your latest comment.
  - `gh pr review <n> --comment|--request-changes --body '…'`
  - Through `gh api -X POST repos/{owner}/{repo}/pulls/<n>/…`:
    - To reply: `comments/<id>/replies -f body=…`
    - For one inline comment: `comments -f body= -f commit_id= -f path= -F line=`
    - For a review with inline comments: `reviews -f event=COMMENT -f body=… -f 'comments[][path]=…' -F 'comments[][line]=…' -f 'comments[][body]=…'`
- **Edit your own:**
  - On an issue that this login opened: `gh issue edit <n> --title|--body|--add-label …`
  - `gh api -X PATCH repos/{owner}/{repo}/pulls/comments/<id>` or `…/issues/comments/<id>`, with `-f body=…`
  - The hook does not approve closing or reopening an issue. Those commands still ask for approval.
- **Resolve:**
  - `gh api graphql -F threadId=<id> -f query='mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } } }'`
  - Thread ids come from a `reviewThreads` query.

## Layout and naming

- Worktrees live at `<repo>/.worktrees/<name>`. This path is git-ignored globally.
- Task branches are `wt/<name>`.
- The base branch defaults to the repository's default branch, unless `wt new` receives `--head` or `-b <ref>`.
  To find it, `wt` uses `origin/HEAD`, then `origin/main` or `origin/master`.
  It then tries local `main`/`master`, then the current branch.
- Use short kebab-case slugs that describe the task, without `.`.
- Each task has a cmux row titled `<name>`.
  Its second line reads `@<host> · <repo>`, for example `@local · workgrove`.
- On a VM, each task also has a tmux session named `wt-<repo>-<name>`.
- `wt show <name>` reports the row and tmux session.
- `.wt-include` lists ignored files to copy in. `.wt-setup` runs in each new worktree.
  Use the [per-repo setup procedure](../.agents/skills/worktree-create/SKILL.md#per-repo-setup-once-on-request) only when the user asks.

## Local and remote

Before remote commands, read and follow [remote setup limits](#remote-setup-limits).

`wt` handles local and remote work through the same subcommands:

- Run them locally.
- Run them inside a VM session.
- Send them from the Mac with `wt -H <vm> <sub> …`.
  In this form, `show`, `rm`, `path`, `open`, and `attach` need `-r <repo>`.

Every row's second line starts with `@local` or `@<host>`, so the sidebar shows where each session runs.

## Choose a VM by hardware

Before creating a task with hardware requirements, get a fresh inventory with `wt hosts --json`.
Use that inventory and the [task-driver selection procedure](../.agents/skills/task-driver/SKILL.md#driving-tasks-from-a-driver-session) to select an SSH-reachable match.
If no suitable machine is available, report that.

## Add a supplied SSH host

Before host preparation or repair, read and follow [remote setup limits](#remote-setup-limits).
Use the [ssh-host skill](../.agents/skills/ssh-host/SKILL.md) for a supplied fragment or portable host preparation.
Use existing usable aliases without new registration.
Keep compute lifecycle and credentials with the SSH supplier.
Before full preparation, confirm the persistent root, storage policy, public revision, and personal identity.
Before deciding whether setup repair is needed, run `wt -H <host> doctor --json`.
After explicit environment repair, use the [existing VM attachment procedure](../.agents/skills/task-driver/SKILL.md#driving-tasks-from-a-driver-session).
For restore-only without asking, follow [Portable restore-only](#portable-restore-only).

## VM task recovery

Before recovery, read and follow [remote setup limits](#remote-setup-limits).
Run task recovery, `--reattach`, or `--restart-agent` only when the user asks.
Use the [task-driver recovery procedure](../.agents/skills/task-driver/SKILL.md#driving-tasks-from-a-driver-session).
Restore-only without asking is permitted only under [Portable restore-only](#portable-restore-only).

## Portable restore-only

Before restoration, read and follow [remote setup limits](#remote-setup-limits).
An agent may run restore-only without asking only when all six conditions hold:

1. SSH to the alias works without an unknown-host-key or changed-host-key error.
2. `wt -H <host> doctor --json`, without `--root`, reports `issues` exactly equal to `["profile-missing","remote-wt-missing"]`.
3. Use a root from `root_discovery` with status `found`, or the user's root for this alias in this session.
   If both sources exist and differ, stop.
4. `root_discovery.same_machine` is `true`, or the user said in this session that this host restarted.
   Otherwise, ask whether the host restarted.
   Name the alias and the root in that one question.
5. `wt -H <host> doctor --root <root> --json` reports no issue outside this allowlist:
   `compatibility-links-missing`, `remote-wt-missing`, and `environment-incomplete`.
   Any other code needs the user, including `missing-prerequisites`, conflict codes, and the warning `agent-command-unavailable`.
   Report `agent-command-unavailable` and stop before starting or restarting a task.
6. Run exactly `wt -H <host> setup --root <root> --restore-only`, with no other option.
   Restore ignores options such as `--git-identity` and `--persist-agents`.

After restore, run `wt -H <host> doctor --json` again.
Report the root, the restore summary, every backup line, and the doctor result to the user.
If `persist_agents` is not set, report that and stop before starting or restarting any task.
If either sign-in file is absent, report that and stop before starting or restarting any task.
The user signs in.

## Remote setup limits

If doctor reports `agent-command-unavailable`, report it and stop before starting or restarting a task.
These steps stay with the user:

- Full setup and any change of `--storage`, `--mount`, `--trust-personal-volume`, `--strict-permissions`, or the alias.
- `--reattach` and `--restart-agent`.
- Signing in an agent or `gh`.
- Accepting a host key.
- Choosing a root when discovery reports `ambiguous`, `none`, or `incomplete`.
- Restoring a host whose root comes only from a `WT_REMOTE_ROOT` export.
  There, doctor finds the profile without naming the root.

After any refusal, stop and ask the user.
After an unknown or changed host key, stop.
Never accept a host key or sign in an agent or `gh` yourself.

## Opening apps

When the user requests an app launch on the Mac, use `wt open` for worktrees and `/usr/bin/open` for other files.
When the user wants to look at a worktree's code, run `wt open`; do not print files instead.
For status or changes, run `wt list` and `wt show <name>`; never open VS Code for this.
In a task session, "the worktree" means this task's worktree, not the `wt` tool.

For worktree launch checks, use the [worktree-show skill](../.agents/skills/worktree-show/SKILL.md#check-the-result-of-wt-open).
Codex's sandbox blocks app launches.
A blocked launch can look like a missing app: `Unable to find application`, `-10661`, or `-10827`.
Before reporting a missing app or inability to open it, rerun the same command with escalation.

The `wt open` exit status depends on where it runs:

- On the Mac, exit 0 reports a launch.
- On a VM, exit 0 reports only that cmux on the Mac accepted the request.
  Describe the result as "requested", not as a launch.
  Only if no window appears, run the manual command that `wt open` prints.

## Reporting

- When you create tasks, list them.
  For each task, give its name, row title, branch, path, and the brief that you gave it.
  For a VM task, also give the tmux session.
- After task creation, do not wait on or poll the new session.
- For deferred creation, report the row only after attach succeeds.
- When you finish a task, summarize the changes, commits, tests run, and anything left undone. Then stop.
