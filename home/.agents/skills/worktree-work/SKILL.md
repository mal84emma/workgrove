---
name: worktree-work
description: How to behave when working inside a task worktree — staying isolated, committing, syncing with the base branch, and handing work back. Use whenever the session's cwd is under a `.worktrees/` directory, or the user asks to update/rebase/push a worktree or hand it back.
---

# Working inside a task worktree

Use this skill when you work inside a task worktree. You are inside one when both of these are true:

- The cwd is `<repo>/.worktrees/<name>`.
- `git rev-parse --abbrev-ref HEAD` prints `wt/<name>`.

Working in a task worktree is a convention, not a sandbox. Nothing isolates the session for you, so you must keep the rules below yourself.

## Rules while in a worktree

1. **Stay inside for task work.** Edit only files under this worktree. Do not work in the main checkout or in sibling worktrees.
   If the user asks you to remove this worktree, follow `worktree-teardown`: change to the main checkout only for `wt rm`.
2. **Commit as you go**, on the worktree's own branch (`wt/<name>`). Make small commits, and describe each one. The user reviews branches, not working trees.
3. **Do not switch branches** or run `git checkout <other-branch>` inside a worktree, because the branch is the task's identity. Do not create nested worktrees.
4. **Dependencies and env** are separate in each worktree. If something is missing, install it here, or suggest a `.wt-setup` script for the repo. Do not point at the main checkout.
5. **Remove the worktree only when the user asks.** You may remove your own worktree if you follow `worktree-teardown`.
6. **No interactive `wt attach`, `wt task` or `wt driver` from here.** Those commands belong to the user's own session on the Mac.

## Syncing with the base

The sidecar (the task's files under `<repo>/.git/wt/`) records the base branch, and `wt show <name>` prints it. Start from a clean tree.
The command below uses `origin/main`. If the recorded base is different, use the recorded base in its place:

```bash
git fetch origin && git rebase origin/main      # or the recorded base
```

If conflicts occur, resolve them inside the worktree. Then run `git rebase --continue`.

## Handing back

Report the branch `wt/<name>` and what is on it.

Never do these actions unless the user explicitly asked for that action in this conversation:

- `git push`
- `wt pr`
- `gh pr create`
- create a remote repository
- publish

Run `wt pr <name>` only when the user explicitly asked for it in this conversation.

Some briefs count as an explicit request for some of these actions:

- A brief to work on an open pull request counts as asking to push to its branch. It also counts as asking to reply to its review comments, edit the ones that you wrote, and resolve them.
- A brief to work on an issue counts as asking to comment on it, and to edit what this login wrote there.

AGENTS.md lists the command forms that the `github-guard` hook approves without a prompt.

## Finishing a task

End with a short summary. Include:

- What changed (files or areas).
- The commits that you made.
- The tests that you ran, and their results.
- Anything left undone.
- The branch: the work is on `wt/<name>`, and the user can inspect it with `wt show <name>`.

Then stop.
