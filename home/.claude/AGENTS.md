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
Use `wt`; see `wt help`.
A **row** is a cmux workspace. The **main checkout** is the repository's primary working tree.

Never do task work in the main checkout unless the user explicitly requests a quick edit there.
When starting a task, feature, fix, or experiment, check your current location.
If you are already inside a worktree, work there.
Otherwise, create one first unless the quick-edit exception applies.

Read only the linked sections needed for your action, and follow their rules and skill links.

Before task work, read [worktree rules](TASKS.md#worktree-rules).
Inside `.worktrees/<name>`, use [worktree-work](../.agents/skills/worktree-work/SKILL.md).
Before creating, displaying, checking, removing, or splitting tasks, read [task procedures](TASKS.md#task-lifecycle); use the linked skills.
Before creation, read [layout and naming](TASKS.md#layout-and-naming).
Also read layout when choosing a base branch or locating rows, sessions, or hooks.
When creating or finishing tasks, read and follow [reporting requirements](TASKS.md#reporting).

## GitHub writes and publishing

Never run `git push`, `wt pr`, `gh pr create`, or `gh issue create` without an explicit request in this conversation.
Never create a remote repository or publish without that request. Otherwise, report the branch.
Never approve a pull request. Approval stays with the user.

Before assessing authorization, read the [brief exceptions](TASKS.md#github-writes-and-publishing).
Before GitHub commands in this repository, read and follow [approved forms](TASKS.md#run-approved-github-commands).

## Local and remote

Read and follow these procedures before their actions:

- For VM work or Mac-to-VM commands, use [remote commands](TASKS.md#local-and-remote).
- For hardware-based task placement, use [VM selection](TASKS.md#choose-a-vm-by-hardware).
- For SSH registration, host preparation, or environment repair, use [SSH host preparation](TASKS.md#add-a-supplied-ssh-host).
- For task recovery or portable-link restoration, use [VM recovery](TASKS.md#vm-task-recovery).
- For Azure Machine Learning (Azure ML) registration, use [azml-compute](../.agents/skills/azml-compute/SKILL.md) on the Mac only.

Keep compute lifecycle and credentials with the SSH supplier.
Never accept a host key, sign in an agent or `gh`, or run `az login` or `az account set`.
Never edit `~/.ssh/config` by hand for Azure ML. If `azml-ssh-host` reports an error, report it and stop.

## Interactive commands

Never run interactive `wt attach`, `wt task`, or `wt driver` from a task session.
These commands belong to the user's own session on the Mac.

## Opening apps

Before requested Mac launches or worktree display, read and follow [app launch rules and results](TASKS.md#opening-apps).
For task status or changes, read and follow [task procedures](TASKS.md#task-lifecycle); never open VS Code.
Never request broader sandbox or network access to open an app.

## cmux

Use `cmux` commands only to create, inspect, or close task rows.
Never rearrange the user's other rows or steal focus. By default, `wt new` creates rows unfocused.
Each task worktree normally has a row showing its branch, agent state, and notifications.
