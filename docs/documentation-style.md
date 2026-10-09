# Documentation writing guide

Use ASD-STE100 Simplified Technical English to make documentation clear and
easy to read. Apply it to new documents and prose that you edit.
This includes `docs/`, READMEs, contributor guides, design documents, runbooks,
templates, API documentation, and agent instructions throughout the repository.
Apply it to docstrings and code comments too.

Use the current issue of
[ASD-STE100](https://www.asd-ste100.org/STE_downloads.html) as the reference.
It contains writing rules and a controlled dictionary.
Check the complete rules, approved vocabulary, meanings, and word-count rules in
the official standard.
This guide summarizes selected rules and defines their use in this repository.
Do not claim full conformity based only on this guide or an automated check.

## Write clear sentences

- Limit instruction sentences to 20 words and descriptive sentences to 25 words.
- Put one subject in each sentence and one subject in each paragraph.
  Keep paragraphs to six sentences or fewer.
- Use active voice. Name the person or component that performs the action.
  Use passive voice in descriptions only when the actor is unknown.
- Give instructions as commands. Put a required condition before its action.
  Give one instruction per sentence unless actions must occur together.
- Keep articles and other words needed for complete, correct sentences.
- Use American English spelling in prose. Preserve existing names and identifiers.

## Use consistent words

- Use the STE dictionary for general words, their meanings, and parts of speech.
- For domain vocabulary, follow the standard's categories for technical names
  and technical verbs. Define unfamiliar terms and abbreviations on first use.
- Use the same term for the same concept throughout a document.
  Match product, component, and interface names to their source definitions.
- Remove promotional language, vague claims, filler, and repeated explanations.
  State the behavior, condition, or result that the reader needs.

## Keep documents useful

- Keep each document focused on one task or subject.
  Start with its purpose and the facts needed to use it.
- Provide only the context needed to complete the task or understand the behavior.
  Omit unrelated background and technical detail.
- Put prerequisites before numbered steps. State how to check the result.
  Keep instructions out of notes. Notes provide supporting information.
- Put warnings before the action that can cause harm or data loss.
- Preserve requirements, limits, failure conditions, and evidence when simplifying
  prose. Distinguish implemented behavior from plans and missing capabilities.
- Preserve commands, code examples, paths, URLs, configuration keys, and API names.
  Keep quotations and legal text exact when required. Simplify surrounding prose.
- Retain headings and link targets that other documents use.
  Update affected links if a heading must change.

For example, replace:

> It is important to note that users should ensure that the configuration has
> been updated prior to initiating the service.

With:

> Update the configuration before you start the service.

## Write useful docstrings and comments

- Apply the sentence, vocabulary, and context rules above to docstrings and comments.
- Explain non-obvious intent, constraints, or decisions.
  Do not restate operations that the code already makes clear.
- Retain API contracts: parameters, return values, shapes, units, side effects,
  and failure conditions.
  Preserve invariants and scientific assumptions that affect correctness.
- Preserve required documentation formats, such as NumPy-style docstrings,
  Rustdoc, and JSDoc.
  Keep annotations, doctests, code examples, and machine-readable directives exact.

## Review changed prose

- [ ] The purpose, prerequisites, actions, and expected results are clear.
- [ ] Sentences and paragraphs meet the limits above.
- [ ] Instructions use commands, and conditions appear before their actions.
- [ ] Terms are consistent, and unfamiliar terms are defined.
- [ ] General vocabulary and technical terms follow the official standard.
- [ ] The edit removes filler without losing facts, warnings, or requirements.
- [ ] Context supports the task or behavior without unrelated background.
- [ ] Docstrings and comments explain useful intent and preserve required
  contracts and formats.
- [ ] Commands, identifiers, examples, and links remain correct.

Use this checklist when reviewing documentation changes.
An automated checker can help find issues. It cannot establish full conformity.

## Apply the guide in this repository

This section adds the rules that are specific to workgrove.
It lists where the guide applies, the text that other files depend on,
the terms to use, and how to check a change.

### Where the guide applies

Apply the guide to the prose that you write or edit in these files:

- `README.md` and the pages in `docs/`
- the `#` comments in `docs/ssh-config.example`
- `AGENTS.md` and `CLAUDE.md` at the repository root
- `home/.claude/AGENTS.md` and the skills in `home/.agents/skills/`
- the code comments in `bin/`, `install.sh`, `test/`, the files in `home/`, `Brewfile`, `.gitignore`,
  and `vscode/settings-snippet.jsonc`
- the help text of `wt` and `azml-ssh-host` (see [Edit comments and help text](#edit-comments-and-help-text))

### Keep code and literals exact

- Do not change a command, flag, argument, quote, or line order in a code block.
  In a `bash` block, you may rewrite a `#` comment, but keep its facts.
- Keep program output, error text, and config samples exact.
- Change the Layout tree in `README.md` only to match the files in the repository.
- Keep quoted error messages and quotations from other documents exact.
- Keep the quoted trigger phrases in skill descriptions and in the README's skills table exact.

### Keep the text that other files cite

Code and other documents cite the items below.
If you must change one, update every file that cites it in the same change.

| Item | Cited by |
|---|---|
| `## Security` in `README.md` | `bin/github-guard` ("the README's Security section") |
| Blocks `# 1.` to `# 4.` in `docs/new-vm.md`, in the same order. Block 1's keepalive lines start at its `sshd_config.d` comment. | `bin/wt` warnings ("docs/new-vm.md block 1's keepalive lines") |
| The file names `docs/new-mac.md` and `docs/new-vm.md` | `install.sh`, which builds the path `docs/new-$page.md` |
| `## Install` and the sync table in `## Keeping machines in sync` in `README.md` | `docs/new-mac.md` and `docs/new-vm.md` |
| `## Notes` in `docs/new-vm.md`, with its rsync line | `README.md` ("the notes of docs/new-vm.md") |
| `## Agents` and the "Rows are found by title, repo and host, in every window" bullet in `README.md` | The README's Security section |
| `### Recover a VM row` in `README.md` | The README's Daily use table, and `docs/azml-compute.md` (`../README.md#recover-a-vm-row`) |
| `## Opening apps` in `home/.claude/AGENTS.md` | The worktree-show skill ("`AGENTS.md`, Opening apps") |
| The `name:` of each skill | `home/.claude/AGENTS.md`, the other skills, and the README's skills table |

### Edit comments and help text

- Change only the comment text. A heredoc body and a quoted string are code, also when they hold
  an embedded awk, perl, or jq program or a script for a VM. Do not change their comments.
- Keep `# shellcheck` directives exact, and keep each one directly above the line that it applies to.
  Keep commented-out code and settings exact, for example `# brew "azure-cli"` in `Brewfile`.
- Do not change lines 2–121 of `home/.zshrc`. They are the stock oh-my-zsh template, which is kept close
  to upstream so that upstream changes are easy to compare.
- `usage()` in `bin/wt` and `bin/azml-ssh-host` prints the file's leading `#` block as the help text.
  Keep that block contiguous, and keep the syntax and alignment of each usage line.
  `test/wt-smoke.sh` checks for the text `wt new  [name]`, with two spaces.
- `test/wt-smoke.sh` compares `tmux_cmd` in `bin/wt` and in `bin/cmux-hook` with the full-line
  comments removed. So a trailing comment inside `tmux_cmd` must be the same in both files.
- `test/wt-smoke.sh` reads the `jq -s -c '…'` program and the `grep -Ex '…'` pattern out of
  `bin/cmux-hook` with `sed`. Do not put a `'` in a trailing comment on those lines.

### Edit agent instructions with care

`home/.claude/AGENTS.md` and the skills steer the coding agents on every machine.
`install.sh` links `home/.claude/AGENTS.md` to `~/.claude/AGENTS.md` and `~/.codex/AGENTS.md`,
so its rules apply in every repository.
Put rules that apply only to workgrove in the root `AGENTS.md`.

When you edit an agent instruction file:

- Keep the scope, conditions, and exceptions of each rule.
  Do not make a rule weaker or stronger unless that is the purpose of the change.
  Words such as "never", "only when", and "unless the user asked" carry the rule.
- Keep the exact command forms that the `github-guard` hook approves.
- In skill front matter, keep `name:` unchanged.
  Keep every quoted and listed trigger in `description:`.

### Simplify without losing facts

- Keep the logical links when you split a sentence:
  "because", "only when", "unless", "until", "so", and "otherwise".
- Keep each requirement, limit, warning, default, number, version, and timing.
  Keep each design decision with its reason.
- Keep statements of evidence, such as "Measured on cmux 0.64" and "**UNVERIFIED**".
- When you only rewrite text, do not add claims.
  When you add a claim, check it against the code first.

### Use these terms

| Term | Meaning |
|---|---|
| task | One unit of work: one git worktree at `<repo>/.worktrees/<name>` on branch `wt/<name>`, with one cmux row |
| row | One cmux workspace, shown as one entry in the cmux sidebar. Say "workspace" only in cmux's own names, such as `cmux workspace list` and `--no-workspace`. |
| second line | The description line of a row in the sidebar. It reads `@<host> · <repo>` for a task row and `@<host>` for other rows. `<host>` is `local` or the VM's alias. |
| main checkout | The primary working tree of a repository, not a worktree |
| base branch, base ref | What a task branch starts from and is compared with |
| brief | The task prompt that the agent gets (`-p`, `--prompt-stdin`) |
| sidecar | The per-task files under `<repo>/.git/wt/` |
| driver session, driver row | The agent session in the row titled `driver` (⌃⌥⌘D). It starts and watches tasks. |
| task picker | `wt task`, opened with ⌃⌥⌘T |
| the Mac | The local macOS machine where cmux runs |
| VM | A remote Ubuntu machine that the Mac reaches with `ssh <vm>`. `<vm>` is its alias in the Mac's `~/.ssh/config`. |
| relay | The channel of cmux from a VM row back to cmux on the Mac |
| Mac hook | `bin/cmux-hook`, the cmux notification hook on the Mac |
| core setup | What a bare `install.sh` run installs |
| opt-in config | The seven optional pieces that the `--with-…` flags or `--opinionated-config` install |
| machine-local copy | `~/.claude/settings.json`, `~/.codex/config.toml`, or `~/.codex/hooks.json`, made from a `.base` file |
| Claude, Codex, agent | Claude is Claude Code. An agent is Claude or Codex, running in a task row. |

### Check a change

1. Review the changed prose with the checklist in [Review changed prose](#review-changed-prose).
2. From the repository root, run these commands. Each command must print at least one line.

   ```bash
   grep -n '^## Security$' README.md
   grep -n '^## Install$' README.md
   grep -n '^## Keeping machines in sync$' README.md
   grep -n '^## Agents$' README.md
   grep -n 'Rows are found by title, repo and host, in every window' README.md
   grep -n '^### Recover a VM row$' README.md
   grep -n '^## Notes$' docs/new-vm.md
   grep -n 'sshd_config.d' docs/new-vm.md
   grep -n '^## Opening apps$' home/.claude/AGENTS.md
   ```

3. Make sure that each relative link and `#anchor` in the changed files still goes to a file or heading.
