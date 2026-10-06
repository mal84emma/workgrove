# Working conventions for coding agents

Coding agents follow these conventions. They apply in these places:

- Every repository in any folder that `$WT_REPOS_DIR` lists. The default folder is `~/Documents/Repositories` on the Mac and the home folder on a VM, unless `~/.zshenv.local` says otherwise.
- Every terminal inside cmux, on the Mac and on every VM.

## Tasks run in worktrees

A **task** is one unit of work that changes code. Each task lives in its own git worktree. Use the `wt` command to create and manage worktrees (see `wt help`).

Never do task work directly in a repository's main checkout unless the user explicitly asks for a quick edit there.

### What to do in each situation

- **You start work that the user describes as a task, feature, fix, or experiment.**
  - If you are already inside a worktree, work there.
  - Otherwise, create a worktree first: `wt new <name> -p "<brief>"`.
  - See the `worktree-create` skill.
- **Several independent things at once.**
  - Create one worktree per thing. Start each one with `wt new ... -p ...`, so that each worktree gets its own agent session in cmux.
  - Split work only when the parts will not touch the same files.
  - To drive several tasks, or tasks on a VM, from one session, see the `task-driver` skill.
- **You are inside a worktree** (your current working directory, or cwd, is under `.worktrees/<name>`).
  - Stay inside the worktree for task work.
  - Commit on its `wt/<name>` branch.
  - Never edit the main checkout or sibling worktrees.
  - When you are asked to remove your own worktree, change to the main checkout and run `wt rm` from there, as the `worktree-teardown` skill describes.
  - See the `worktree-work` skill.
- **The user wants to look at the code** ("show me the code", "open the worktree", "let me see it").
  - Run `wt open`, which opens the worktree in VS Code.
  - Do not print files instead.
- **The user wants status or changes** ("what changed", "how far is it").
  - Run `wt list` and `wt show <name>`, and give a short summary.
  - Never open VS Code for this.
  - In a task session, "the worktree" means this task's worktree, not the `wt` tool.
  - See the `worktree-show` skill.
- **You finish or clean up.**
  - Report the branch.
  - Remove worktrees only through `wt rm` / `wt prune`, and only when the user asks.
  - Never use `--force` or `--discard-commits` unless the user says so in this conversation.
  - See the `worktree-teardown` skill.

### Worktrees are not a sandbox

These rules are conventions, not a sandbox. A session that starts with its cwd inside `.worktrees/<name>` does not get Claude's own worktree isolation. You are responsible for staying inside the worktree.

### GitHub writes and publishing

Never do these actions unless the user explicitly asked for that action in this conversation:

- `git push`
- `wt pr`
- `gh pr create`
- `gh issue create`
- Create a remote repository.
- Publish.

Instead, report the branch.

Some briefs count as asking for GitHub writes:

- A brief to work on an open pull request (address its review, fix its CI) counts as asking for these actions:
  - Push to that pull request's branch.
  - Reply to its review comments.
  - Edit your own review comments on it.
  - Resolve its review comments.
- A brief to review a pull request counts as asking to post the review.
- A brief to work on an issue counts as asking to comment on the issue. It also counts as asking to edit the issue and your comments on it, but only where this login wrote them. "This login" is the account that `gh` is logged in as.

Each of these briefs counts as asking only for the actions listed with it, and nothing more.

Never approve a pull request. Approval stays with the user.

### Run approved GitHub commands

Claude's `github-guard` hook approves the forms below without a prompt, in this repository only. The hook denies other GitHub writes with a reason that names the approved form. Read that reason and retry.

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
  - The target can be any branch except the default one.
  - The form is never forced, and it never pushes more than one branch.
- **Open a pull request or an issue:**
  - `gh pr create --title '…' --body '…'` (or `--fill`)
  - `wt pr <name>`
  - `gh issue create --title '…' --body '…' [--label …]`
  - Do not use `--template`. Read the repository's template and pass the filled-in text.
- **Comment and review:**
  - `gh pr comment <n> --body '…'` or `gh issue comment <n> --body '…'`. Add `--edit-last` to fix your latest comment.
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

- **Worktrees:** `<repo>/.worktrees/<name>` (git-ignored globally).
- **Branches:** `wt/<name>`.
- **Base branch:** the default branch of the repository, unless you pass `--head` or `-b <ref>` to `wt new`. To find this base, `wt` uses `origin/HEAD`. It falls back to `origin/main` or `origin/master`, then a local `main`/`master`, then the current branch.
- **Names:** short kebab-case slugs that describe the task. Do not use `.` in a name.
- **Rows:** each task has a cmux row titled `<repo>:<name>`. The second line of the row reads `@local` or `@<host>`.
- **tmux sessions:** on a VM, each task also has a tmux session `wt-<repo>-<name>`.
- **Lookup:** `wt show <name>` reports the row and the tmux session.
- **Per-repo hooks:** `.wt-include` lists the ignored files to copy in. `.wt-setup` runs in each new worktree.

## Local and remote

`wt` handles the difference between local and remote work. The same subcommands work in three ways:

- They run locally.
- They run inside a VM session.
- You send them from the Mac to a VM as `wt -H <vm> <sub> …`. In this form, `show`, `rm`, `path`, `open`, and `attach` need `-r <repo>`.

The second line of every row reads `@local` or `@<host>`, so the sidebar always shows where a session runs.

### Choose a VM by hardware

When you are asked to choose a VM by hardware requirements, do these steps before you create the task:

1. Get a fresh inventory with `wt hosts --json`.
2. Use that inventory and the `task-driver` skill to select an SSH-reachable match.
3. If no suitable machine is available, report that.

### Add an Azure ML compute instance

On the Mac only, use the `azml-compute` skill (`azml-ssh-host add <instance>`) to add an Azure Machine Learning (Azure ML) compute instance to ssh. Never edit `~/.ssh/config` by hand for this.

Only the user runs `az login` and `az account set`. Do not run them yourself. When the `azml-ssh-host` helper gives an error, report the error and stop.

### Interactive commands

Never run interactive `wt attach`, `wt task` or `wt driver` from a task session. These commands belong to the user's own session on the Mac.

## Opening apps

When the user asks you to open something on the Mac, use these commands:

- For a worktree, use `wt open`.
- For any other file, use `/usr/bin/open`.

Codex's sandbox blocks app launches. A blocked launch reads like a missing app (`Unable to find application`, `-10661`, `-10827`). Before you say that the app is missing or that you cannot open it, rerun the same command with escalation. Never ask for broader sandbox or network access to open an app.

The exit status of `wt open` means different things on the Mac and on a VM:

- A Mac-local `wt open` that exits 0 reports a launch.
- A VM-side `wt open` that exits 0 reports only that cmux on the Mac accepted the request. So describe the result as "requested", not as a launch. Only if no window appears, run the manual command that `wt open` prints.

## cmux

Each task worktree normally has a cmux row that shows its branch, agent state, and notifications.

- Use `cmux` commands only to create, inspect, or close task rows.
- Do not rearrange the user's other rows.
- Never steal focus. By default, `wt new` creates rows unfocused.

## Reporting

- When you create tasks, list them. For each task, give the name, row title, branch, path, and the brief that you gave it. For a task on a VM, also give the tmux session.
- When you finish a task, summarize the changes, commits, tests run, and anything left undone. Then stop.
