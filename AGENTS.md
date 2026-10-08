# Instructions for agents that work on this repository

These instructions apply to work on the workgrove repository itself.
Put rules that apply only to this repository in this file.

`home/.claude/AGENTS.md` holds the working conventions for every repository.
`install.sh` links it to `~/.claude/AGENTS.md` and `~/.codex/AGENTS.md` on each machine.

## Documentation

When you write or edit prose, follow [docs/documentation-style.md](docs/documentation-style.md).
Prose includes the README, the pages in `docs/`, agent instructions, skills, and code comments.

Before you finish a change that edits prose, do the steps in "Check a change" in that guide.

## Public information

Before publishing repository text or GitHub content, remove personal usernames, machine-specific runtime paths, and VM aliases.
This rule covers documentation, commit messages, pull requests, issues, comments, reviews, and attached logs or command output.

Use consistent placeholders such as `<user>`, `<repo>`, and `<test-vm>`.
Keep public repository paths, commands, and technical findings when they do not expose these details.
Mark sanitized logs and command output as redacted.
Check the complete text, including code blocks and links, before posting or committing it.
