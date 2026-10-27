# Working conventions for coding agents

These conventions apply to every cmux terminal on the Mac and VMs, and every repository under `$WT_REPOS_DIR`.
Unless `~/.zshenv.local` overrides it, the repository folder defaults to `~/Documents/Repositories` on the Mac and the home folder on VMs.

## Writing

The user does not see your tool calls or their output. Write every message so that the user can act on it alone. The same rules apply to commit messages, pull request text, review comments, and briefs for other agents.

### Write clear sentences

- Put one idea in each sentence. Use at most 20 words in an instruction and 25 in a description.
- Keep each paragraph to one subject and at most six sentences.
- Use active voice, and name the person or component that does the action. Use passive voice only when the actor is unknown.
- Give instructions as commands, one per sentence unless the actions must occur together. Put a required condition before its action.
- Write complete sentences, with their articles and verbs. A sentence is clearer than a label with a colon.
- Use American English spelling. Keep existing names and identifiers as they are.

### Use consistent words

- Use one name for one thing throughout a message. Use the names that this file defines, such as task, row, main checkout, the Mac, and VM. For anything else, use the name that the code, its output, or the user uses.
- Do not invent a name for something. Define an unfamiliar term and expand an abbreviation the first time you use them.
- Remove filler, hedges, vague claims, apologies, praise, and repeated explanations. State the behavior, the condition, or the result that the reader needs.
- Do not describe your own process, for example "Let me…" or "Now I will…". Do not repeat the question.

### Keep messages useful

- Lead with the result. If something failed, or you could not check it, say that first.
- Give only what the reader needs to understand the result and to act. Leave out what you tried, what you read, and how you reasoned, unless the reader needs that context.
- When you give steps, put the prerequisites first and say how to check the result. Put a warning before an action that can cause harm or data loss.
- Say that work is done only when it is complete and tested. Separate what is done from what is untested, not done, or only planned.
- When you shorten, keep every requirement, limit, failure condition, number, and piece of evidence.
- Quote test output, command output, and error text exactly, in a code block. Put commands, paths, and identifiers in code formatting.
- Use a list for parallel items, such as findings, steps, or files. Put counts and measurements in a table or on their own line.
- Do not use headings in a short message. Stop when the content stops, without a summary or an offer of more help.

For example, replace:

> I went ahead and took a look at the failing tests, and it seems like the problem is most likely that the config isn't being updated before the service gets started.

With:

> The tests fail because the service starts before the config is updated. Move the config step before the start step.

## Tasks run in worktrees

A **task** is one unit of work that changes code, in its own git worktree.
Use `wt` to manage tasks; see `wt help`.
A **row** is a cmux workspace. The **main checkout** is the repository's primary working tree.

- When starting a task, feature, fix, or experiment, check whether you are inside a worktree.
  If you are, work there. Otherwise, first run `wt new <name> -p "<brief>"`.
- Never do task work in the main checkout unless the user explicitly requests a quick edit there.
- Inside `.worktrees/<name>`, stay there for task work and commit on `wt/<name>`.
  Make small commits and describe each one.
  Never edit the main checkout or sibling worktrees, switch branches, or create nested worktrees.
  Keep dependencies and environment settings in the worktree. Do not use the main checkout's copies.
- These conventions provide no sandbox or Claude worktree isolation. You must keep task work inside the worktree.
- Split work only when the parts touch different files. Give each part its own worktree and agent session.
- Do not code in a driver session. Start a task session for that work.
- Remove worktrees only with `wt rm` or `wt prune`, and only when the user asks.
- Never use `--force` or `--discard-commits` unless the user authorizes that flag in this conversation.
- Use short kebab-case task names. Do not use `.` in a name.
- Add `.wt-include` and `.wt-setup` only when the user asks.

Read [task procedures](TASKS.md#task-lifecycle) before creating, displaying, checking, or removing tasks; use the linked skills.
Read [layout and naming](TASKS.md#layout-and-naming) when choosing a base branch or locating rows, sessions, and hooks.
Read [reporting requirements](TASKS.md#reporting) when creating or finishing tasks.
After task creation, do not wait on or poll the new session. Report a deferred row only after attach succeeds.

## GitHub writes and publishing

Never run `git push`, `wt pr`, `gh pr create`, or `gh issue create` without an explicit request in this conversation.
Never create a remote repository or publish without that request. Otherwise, report the branch.
Briefs authorize only the specific actions in the [brief exceptions](TASKS.md#github-writes-and-publishing).
Never approve a pull request; approval stays with the user.

For guarded GitHub commands, never use pipes, `&&`, `$(…)`, or a `cd … &&` prefix, or `--template`.
Never push tags, `main`, `master`, or the default branch through the guarded form, force it, or push multiple branches.
Read [approved command forms](TASKS.md#run-approved-github-commands) before running GitHub commands in this repository.

## Local and remote

- Run task recovery, `--reattach`, or `--restart-agent` only when the user asks.
- Restore-only without asking requires all six [portable restore conditions](TASKS.md#portable-restore-only).
- Leave full setup and changes to `--storage`, `--mount`, `--trust-personal-volume`, `--strict-permissions`, or the alias to the user.
- Leave root choices for `ambiguous`, `none`, or `incomplete` discovery, and `WT_REMOTE_ROOT`-only restoration, to the user.
- After restore, do not start or restart tasks if `persist_agents` is unset or either sign-in file is absent.
- If doctor reports `agent-command-unavailable`, report it and stop before starting or restarting a task.
- After any refusal, stop and ask the user. After an unknown or changed host key, stop.
- Never accept a host key or sign in an agent or `gh` yourself.
- Never run `az login` or `az account set`; only the user runs them.
- Add Azure Machine Learning (Azure ML) compute instances through `azml-compute`, on the Mac only.
- Never edit `~/.ssh/config` by hand for Azure ML. If `azml-ssh-host` reports an error, report it and stop.
- Keep compute lifecycle and credentials with the SSH supplier.

Read [remote commands](TASKS.md#local-and-remote) before sending `wt` commands from the Mac to a VM.
Read [VM selection](TASKS.md#choose-a-vm-by-hardware) before creating a task with hardware requirements.
Read [Azure ML registration](../.agents/skills/azml-compute/SKILL.md) when adding a compute instance with `azml-ssh-host add <instance>`.
Read [SSH host preparation](TASKS.md#add-a-supplied-ssh-host) before registering a fragment, preparing a host, or repairing its environment.
Read [VM recovery](TASKS.md#vm-task-recovery) before recovering tasks or restoring portable links.

## Interactive commands

Never run interactive `wt attach`, `wt task`, or `wt driver` from a task session.
These commands belong to the user's own session on the Mac.

## Opening apps

When the user requests an app launch on the Mac, use `wt open` for worktrees and `/usr/bin/open` for other files.
When the user wants to look at a worktree's code, run `wt open`; do not print files instead.
For status or changes, run `wt list` and `wt show <name>`; never open VS Code for this.
In a task session, "the worktree" means this task's worktree, not the `wt` tool.
Never request broader sandbox or network access to open an app.
Read [app launch results](TASKS.md#opening-apps) before reporting launch success or failure; retry blocked launches with escalation.

## cmux

Use `cmux` commands only to create, inspect, or close task rows.
Do not rearrange the user's other rows or steal focus. By default, `wt new` creates rows unfocused.
Each task worktree normally has a row that shows its branch, agent state, and notifications.
