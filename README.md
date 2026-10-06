# workgrove

workgrove lets you run many coding-agent tasks in parallel. It is a set of dotfiles plus `wt`, a small tool that runs the tasks.
Each Claude Code or Codex session gets its own git worktree and its own terminal row in [cmux](https://github.com/manaflow-ai/cmux).
A task runs on the Mac (the local macOS machine where cmux runs) or on an Ubuntu VM.
A VM is a remote machine that the Mac reaches with `ssh <vm>`, where `<vm>` is its alias in the Mac's `~/.ssh/config`.
VS Code opens only when you ask for it, through `wt open`.

`install.sh` installs everything into `$HOME` on a Mac or on a VM from one clone of this repo.

**The model:** one task = one worktree at `<repo>/.worktrees/<name>` on branch `wt/<name>` = one cmux row.

- A **task** is one unit of work.
- A **row** is one cmux workspace. The cmux sidebar shows each row as one entry.
- An **agent** is Claude Code (called Claude below) or Codex, running in a task row.

## How it works

This section describes how `wt` names and finds rows, where it keeps task data, and which repos it uses.
It also covers per-repo hooks and the logins that you supply.

- **Identity.** Each row that a task owns has the title `<repo>:<name>`.
  Each kind of row has its own title:

  | Row title | What the row holds |
  |---|---|
  | `<repo>:<name>` | a task |
  | `<repo> shell` | a shell in a repo |
  | `shell` | a shell on a VM |
  | `driver` | the driver session, that is, the agent session that starts and watches tasks |

  The description line of a task's row shows as the **second line** of its sidebar entry.
  The second line reads `@local` or `@<host>`, so you always know where a session runs.

  A task on a VM also has the tmux session `wt-<repo>-<name>`. This session keeps the agent alive across disconnects.
  The row itself is only a plain `cmux ssh` row, so the tmux session, not the row, gives this persistence.
  The shell that the row opens creates that tmux session, and the session runs the agent.
  If the session already exists, the shell takes it over instead.

- **Rows are found by title, in every window.**
  The **Mac hook** is `bin/cmux-hook`, the cmux notification hook on the Mac.
  `wt` and the Mac hook look for rows in every cmux window, not only in the caller's window.
  - *Why rows move between windows:* a cmux window shows one row at a time.
    To put two tasks side by side on screen, you need two windows, and you drag one task's row into the second window.
  - *The problem:* `cmux workspace list --json` answers for a single window, the caller's window.
    As a result, a row that you moved out of the caller's window looked like a closed row.
  - *What broke before the fix:*
    - `wt rm` removed the worktree and left the row behind.
    - `wt -H <vm> attach` made a second row next to the row that was already there.
    - `wt new` did not detect a row title that another repo already used.
    - The Mac hook could not prove that a VM's `wt open` came from that VM, so it did nothing.
  - *The evidence:* Measured on cmux 0.64, a row keeps its id, its title and its `workspace:N` ref when it moves.
    Every command that acts on a row (select, send, close, set-description) finds the row by id in any window.
    Only the listing is limited to the caller's window.
  - *The decision:* `rows_json` in `bin/wt` and `ws_load` in `bin/cmux-hook` enumerate the windows and merge their lists.
    Because the commands that act on a row already reach it in any window, no other code had to change.
    Both functions enumerate windows by window uuid, never by the index that `cmux list-windows` prints first, because opening a window renumbers the other windows.

- **Git owns the worktree; sidecar files own the launch metadata.**
  `wt` gets the worktrees from `git worktree list`.
  For each task, `wt` also keeps three **sidecar** files in `<repo>/.git/wt/`:

  | File | Contents |
  |---|---|
  | `<repo>/.git/wt/<name>.json` | The base ref, agent, model, row title, tmux session, copied files, and what `.wt-setup` left behind. The base ref is what the task branch starts from and is compared with |
  | `<name>.prompt` | The **brief** (the task prompt). `wt run` gives it to the agent |
  | `<name>.started` | A marker file. When this file exists, Claude resumes with `-c` |

  None of these files is ever committed.

- **Per-repo hooks.** A repo can have two hook files:
  - `.wt-include` lists gitignore-style patterns of *ignored* files (for example, `.env` and similar files). `wt` copies the matching files into each new worktree.
  - If `.wt-setup` is executable, `wt` runs it inside each new worktree.

- **Paths.**
  - Task repos are in the folders that `$WT_REPOS_DIR` lists. The default on the Mac is `~/Documents/Repositories`.
  - On a VM, `install.sh` records the home folder in `$WT_REPOS_DIR` instead.
    As a result, every git repo directly under the home folder is a task repo.
    `wt` excludes hidden folders, for example `~/.oh-my-zsh`.
  - This repo is at `~/repos/workgrove` on every machine, so the same commands work everywhere.

- **Auth is yours.** The repo contains only tools and config, so you must do the authentication (auth) yourself.
  Log in once per machine with `gh auth login`, `az login`, `claude auth login`, and `codex login`.
  Then run `claude auth status` and make sure that it reports `"loggedIn": true`.

## Layout

The tree below shows the files in this repo, with a short note on what most of them do.

```
workgrove/
├── README.md
├── AGENTS.md                  rules for agents that work on this repo
├── CLAUDE.md                  one line: @AGENTS.md
├── LICENSE
├── install.sh                 links this repo into $HOME (Mac and Ubuntu)
├── Brewfile                   fzf gh jq shellcheck (azure-cli commented out); casks cmux, VS Code, GCM
├── .gitignore
├── bin/
│   ├── wt                     the task tool: worktrees, cmux rows, the picker, the driver, VMs
│   ├── agent-notify           agent lifecycle hook, relays to cmux or posts a banner
│   ├── cmux-hook              Mac-side cmux notification hook: remote row requests and agent status
│   ├── github-guard           Claude PreToolUse hook: GitHub reads, pushes, PRs, issues, comments, reviews
│   └── azml-ssh-host          Azure ML compute instance -> a Host block in ~/.ssh/config
├── home/
│   ├── .zshenv .gitignore_global   always installed; .zshrc .gitconfig .tmux.conf are opt-in
│   ├── .oh-my-zsh/custom/themes/workgrove.zsh-theme   with the .zshrc opt-in
│   ├── .claude/
│   │   ├── AGENTS.md          the working conventions both agents read
│   │   ├── CLAUDE.md          one line: @AGENTS.md
│   │   └── settings.base.json; keybindings.json and statusline-command.sh are opt-in
│   ├── .agents/skills/        task-driver, worktree-create, worktree-work, worktree-show, worktree-teardown,
│   │                          azml-compute
│   ├── .codex/                config.base.toml, hooks.base.json
│   └── .config/cmux/cmux.json
├── vscode/
│   ├── settings-snippet.jsonc six keys to paste; Settings Sync owns the rest
│   └── extensions.txt
├── test/
│   ├── lib.sh                 the assertion vocabulary both suites speak
│   ├── install-smoke.sh       the install smoke test: the default install, the flags, stickiness
│   ├── wt-smoke.sh            the wt smoke test: sidecars, base pinning, every rm refusal
│   ├── hosts-smoke.sh         SSH inventory with scratch aliases and a fake ssh
│   ├── github-guard-smoke.sh  what the GitHub guard approves and denies, with a fake gh
│   ├── remote-new-smoke.sh    remote task preflight and recovery with fake ssh/cmux
│   ├── agent-status-smoke.sh  VM status relay and Mac row lifecycle with fake cmux
│   └── agent-status-linux-smoke.sh  Linux owner gate, heartbeat and Esc watcher
└── docs/
    ├── new-mac.md             set up a Mac
    ├── new-vm.md              set up an Ubuntu VM
    ├── azml-compute.md        Azure ML compute instances over ssh
    ├── documentation-style.md the writing rules for docs, agent instructions and comments
    └── ssh-config.example     the Host block a VM alias needs
```

## Install

This section tells you what `install.sh` needs, how to run it, and which parts are optional.
It also describes what a run changes, the repo's test suites, and how to remove an install.

### Requirements

- **Operating system:** macOS with Homebrew, or Ubuntu 22.04 to 24.04.
- **`git` and `jq`:** both must be on `PATH` before you start. When `jq` is missing, `install.sh` stops with a
  message that names `jq`. Without `git`, `install.sh` cannot get past its git-identity check.
- **Git identity:** set one before you run `install.sh`. `install.sh` looks in `~/.gitconfig.local` first, then
  in your global git config. Without an identity, it stops with a message.
- **oh-my-zsh (when `~/.zshrc` is opted in):** install it before you run `install.sh`. Without it, `install.sh`
  stops with a message.
- **`bash`:** version 3.2 is the minimum. That is macOS's own `/bin/bash`, and the smoke test (see Tests) passes
  under it, so nothing here needs a newer shell.
- **tmux:** the VMs have tmux 3.2a, and `home/.tmux.conf` is written for that version.
- **cmux:** the cmux integration assumes cmux 0.64 or newer, because `bin/cmux-hook` encodes the notification
  behavior of 0.64. `home/.config/cmux/cmux.json` is `schemaVersion: 1`.
- **Other tools:** on a Mac, `Brewfile` installs `gh`, `fzf`, cmux itself, Claude Code, and Codex. On a VM,
  [docs/new-vm.md](docs/new-vm.md) installs them.
- **`az` (optional on the Mac and on a VM):** only `azml-ssh-host` needs it. So on the Mac, its `Brewfile` line
  is commented out, and on a VM, `command -v az` guards its install block.

### Install command and dry run

For the full setup of a new machine, follow [docs/new-mac.md](docs/new-mac.md) or
[docs/new-vm.md](docs/new-vm.md). In short, clone this repo and run `install.sh`:

```bash
mkdir -p ~/repos && git clone https://github.com/mal84emma/workgrove ~/repos/workgrove
bash ~/repos/workgrove/install.sh
```

To check the result, read the run's output. It names every file that it links and every opt-in that it left
out, with the flag that would install each.

To see exactly what `install.sh` would do, run it with a throwaway home: `HOME=$(mktemp -d) bash install.sh`.
This run does not touch your own dotfiles. Every path that `install.sh` writes is relative to `$HOME`, so the
whole install lands in that directory, and you can read it there. The smoke test exercises this property.

To put an uncommitted local change on a machine, seed it with the `rsync` line instead of the clone. That line
is in the notes of [docs/new-vm.md](docs/new-vm.md). A seeded copy has no `.git`, so `wt update` refuses until
a clone replaces it.

### Core setup and opt-in config

A bare `install.sh` run installs the **core setup**. Apart from the fallback edits below, it leaves your own
shell, git, and tmux configuration alone.

Seven pieces are the author's personal preferences, not core setup. They are six files and one group of keys
inside a file that is installed either way. These seven pieces are the **opt-in config**. A task tool should
not give strangers the author's shell prompt, git config, tmux bindings, Claude keymap, status line, Claude UI,
and cmux layout. So `install.sh` installs each piece only when you give its flag.

`--opinionated-config` installs all seven at once. `--refresh-config` replaces the machine-local copies (see
File classes). It is independent of the opt-in flags, and all of these flags combine in any order.

The **relay** in the table below is cmux's channel from a VM row back to cmux on the Mac.

| Flag | Asks for | What arrives instead when you leave it out |
|---|---|---|
| `--with-zshrc` | `~/.zshrc`, with the oh-my-zsh theme, the oh-my-zsh prerequisite, and a clone of the two plugins that it enables | Nothing. Your `~/.zshrc` stays untouched. A default install therefore has no oh-my-zsh prerequisite and no network step at all. |
| `--with-gitconfig` | `~/.gitconfig`: `core.excludesFile`, the github.com credential helper, and the `~/.gitconfig.local` include | Its two core-setup settings only, written into your own `~/.gitconfig`. See the fallbacks below. |
| `--with-tmux-conf` | `~/.tmux.conf`: the relay line, plus tuning that makes Claude in tmux feel like a bare terminal (listed below the table) | Its one core-setup line, appended to your own `~/.tmux.conf`. See the fallbacks below. |
| `--with-keybindings` | `~/.claude/keybindings.json` | Nothing. Claude keeps its own keymap. |
| `--with-statusline` | `~/.claude/statusline-command.sh` | Nothing. Also, `install.sh` strips `statusLine` from the `~/.claude/settings.json` copy, because that key names a script that would not be there. |
| `--with-claude-ui` | No file of its own: the `tui`, `voice`, and `theme` keys and `env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS`, kept in the `~/.claude/settings.json` copy | `install.sh` deletes those keys from the copy, so Claude keeps its own full-screen setting, voice mode, theme, and mouse handling. The hooks and permissions in the same file arrive either way. |
| `--with-cmux-config` | `~/.config/cmux/cmux.json` (Mac only). It holds the palette, the sound overrides, the sidebar layout, the three ⌃⌥⌘ hotkeys, and the tab-bar buttons. It also holds the one entry that is core setup. | That one entry only, merged into your own `~/.config/cmux/cmux.json`. See the fallbacks below. |

The full `~/.tmux.conf` from `--with-tmux-conf` tunes tmux with true color, a 10 ms `escape-time`,
Shift+Enter, and focus events. It also makes the mouse wheel scroll instead of typing arrow keys.

`~/.zshenv` and `~/.gitignore_global` are not opt-in config. They are the contract that the tools rely on, not
personal preference:

- `~/.zshenv` puts `~/.local/bin` on `PATH` and carries `WT_HOST` and `WT_REPOS_DIR`.
- `~/.gitignore_global` is the file that git-ignores `.worktrees/`.

### Fallbacks that edit your own files

When you leave out `--with-gitconfig`, `--with-tmux-conf`, or `--with-cmux-config`, `install.sh` adds only the
core-setup part to your own file:

- **`~/.gitconfig`:** `install.sh` writes two settings with `git config --global`. `core.excludesFile` is what
  git-ignores `.worktrees/`. The `~/.gitconfig.local` include is where your identity lives. Every other line
  of your file stays as it is.
- **`~/.tmux.conf`:** `install.sh` appends one line, `set -ag update-environment`, and creates the file if you
  have none. Every line already there stays in place. That line is how cmux's relay variables reach a pane
  started in an already-running session.
- **`~/.config/cmux/cmux.json`:** `install.sh` merges the `notifications.hooks` entry that names
  `~/.local/bin/cmux-hook`, and creates the file if you have none. It appends the entry last, so any hook of
  yours that suppresses a notification still runs first. The merge is keyed on the entry's `id`, so a rerun
  changes nothing. `schemaVersion` and every other key stay as they are.

A running cmux does not read `cmux.json` again. So after the merge, or after you paste the JSON yourself (see
below), run `cmux reload-config` or relaunch cmux.

There is one deliberate exception to these fallbacks. If `core.excludesFile` already points at a file of your
own, `install.sh` keeps that file and does not overwrite it. It prints a message instead. In that case, add the
lines of `.gitignore_global` to your file yourself. The reason for the exception is that an overwrite would
silently drop every global ignore you had. That harm is what this whole opt-in design is about.

### When the cmux merge declines

The cmux merge is the one fallback that can decline. It declines in these cases:

- Your `cmux.json` is a symlink that a dotfile manager owns.
- `jq` cannot parse your `cmux.json`. `//` comments are the common case, because cmux accepts JSONC (JSON with
  comments) and `jq` does not.
- `notifications.hooks` is not the shape that the merge expects.
- A hook with that `id` already runs something else.

If the merge declines, it does nothing, says why, and prints the exact JSON to paste. Paste that JSON into your
`cmux.json` yourself. The install still succeeds. But until you paste the JSON, the relay does not work, so a
`wt` row on a VM never attaches or opens.

### How the choice persists

Each machine's opt-in choice is sticky, that is, later runs keep it. Nothing is stored anywhere that could
disagree with it. A destination that is already a symlink into this repo counts as opted in. So `wt update`,
which re-runs `install.sh` with at most `--refresh-config`, keeps what each machine chose.

- **Opt in later:** run `install.sh --with-…` yourself once. After that, `wt update` carries the choice.
  (For `--with-claude-ui`, see below.)
- **Opt-ins left out:** a run that leaves some out names them, and names the flag that would install each.

`--with-claude-ui` is sticky too, but it has a different record. The other six are sticky because of the
symlink itself, and keys inside a copied file leave no such trace. But the copy is its own record. A
`~/.claude/settings.json` that already carries a top-level `tui` key was written by a run that was given the
flag. So a later `--refresh-config` keeps those keys instead of stripping them.

If you give `--with-claude-ui` on its own (without `--refresh-config`) on a machine whose copy was written
without it, the flag changes nothing. The run says so instead of reporting success.

### File classes

`install.sh` sorts every file into one of three classes.

| Class | Files | Behavior |
|---|---|---|
| Symlinks | `~/.zshenv`, `~/.gitignore_global`, `AGENTS.md`, `CLAUDE.md`, the skills, `bin/*`, and every opt-in file you asked for. `cmux.json` is one of them (Mac only, under `--with-cmux-config`). | Edits, including an agent's, land in the repo, so `git diff` is the review. |
| Machine-local copies | `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.codex/hooks.json` | `install.sh` creates them from the versioned `.base` files, minus the keys that this machine cannot use or did not ask for (listed below). The apps write local state into them. So a normal run keeps what is there, and only `install.sh --refresh-config` replaces them. |
| Never touched | `~/.gitconfig.local`, `~/.zshrc.local`, `~/.zshenv.local` (which on a VM gains the `WT_HOST` and `WT_REPOS_DIR` lines when they are absent), and the real directories the apps write into | Your machine-local overrides. The linked files source or include them, but `~/.zshrc.local` only when `~/.zshrc` is one of the linked files. |

The machine-local copies leave out these keys:

- Voice and Keychain credential keys on VMs.
- `statusLine` without `--with-statusline`.
- `tui`, `voice`, `theme`, and `env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS` without `--with-claude-ui`.

VM copies also set Claude's `prefersReducedMotion` and disable the animations of the Codex TUI (terminal user
interface) to keep tmux task rows steady. Mac copies leave both animations enabled.

### What a run does

`install.sh` has these properties:

- **It is idempotent:** a second run gives the same result as the first. Rerun it after every repo change.
- **It deletes nothing.** It moves anything in the way into `~/.workgrove-backup/<timestamp>-<pid>`, and it
  creates that directory only when it is necessary.
- **It stops with a message** if no git identity is set. It looks in `~/.gitconfig.local` first, then in your
  global git config. When `~/.zshrc` is opted in, it also stops if oh-my-zsh is missing.

On Linux, a run also does these things:

- It writes a `WT_HOST` line to `~/.zshenv.local`. The line holds this VM's alias, that is, the VM's name in the
  Mac's `~/.ssh/config`. The run gets the alias from the environment (`WT_HOST=<vm> bash install.sh`, which is
  what the setup page, [docs/new-vm.md](docs/new-vm.md), does). Otherwise, it asks for the alias once at a
  prompt.
- It records `export WT_REPOS_DIR="$HOME"` in the same file.
- It puts one line at the top of `~/.bashrc` so that bash reads `~/.zshenv`, because cmux runs its VM rows in
  bash.

The line must be at the top because Ubuntu's `~/.bashrc` returns early in a non-interactive shell. At the top,
the line also covers `ssh <vm> '<cmd>'` and `wt -H <vm> …`.

### Tests

- **`bash test/install-smoke.sh`** is the repo's smoke test. It makes 648 assertions across seventeen scenario
  groups. The groups make fifty runs, because most groups have several cases and one group loops over five
  flags. Each run uses its own throwaway `$HOME` with no network.
  - It covers:
    - the default no-flags install, into an empty home and over a stranger's own dotfiles
    - `--opinionated-config`, and each file flag on its own
    - the stickiness rules, idempotence, an unknown flag, and every refusal path
    - which links count as this repo's own
    - the don't-clobber branches of `configure_git`, retirement of renamed links, and `ZSH_CUSTOM`
  - Set `INSTALL_BASH=/bin/bash` to run `install.sh` itself under bash 3.2, which is what a fresh Mac gives it.
  - Set `FORCE_OS=Linux` to drive the Linux-only steps from a Mac.
  - On a VM it makes 500 assertions, because scenario 17 is about a Mac file and does not run there.
  - A run on a VM is useful, because `FORCE_OS` cannot fake everything that a real Linux box differs in.
    For example, a VM run found that the suite built its fixtures with whatever umask the machine had.
    Ubuntu's umask, 002, made a `~/.bashrc` group-writable, and `install.sh` declines to rewrite such a file.
    So a scenario that meant to test the rewrite tested the refusal instead, and only on the VM.
    `install-smoke.sh` and `wt-smoke.sh` now both pin `umask 022`.
- **`bash test/wt-smoke.sh`** makes 627 assertions over sixteen groups against throwaway git repos. Because
  the suite stubs out cmux, it needs no cmux, no network, and no VM. It covers:
  - What `wt` records in a sidecar, including a task model passed to Claude and Codex on later launches.
  - How a base is pinned: `@`, `HEAD^0`, and `--head` on a detached checkout. Without the pin, these
    spellings would compare a worktree with itself.
  - Every reason that `wt rm` refuses, and that `--force` gets past each one.
  - That a squash-merged branch is not one of those reasons. A commit made after the squash, a partial
    revert, and a later edit to the same lines still are reasons. These cases run against a bare "origin" and a
    second clone that plays GitHub, and once more under a `git` that claims to be 2.34.
  - That `wt prune` keeps exactly what `wt rm` refuses.
  - That a VM task can remove itself only after it leaves its worktree.
  - That a row in a second cmux window is still found and still closed.
  - That a suspended VM row's relay is cleared only when a user-owned `sshd` or `sshd-session` holds its
    mapped port. The port can be on any local address, and the connection must not be from the Mac's current
    address.
  - That `wt` types into a recovered row, `--reattach` included, only when all of these are true:
    - The row is at a shell prompt that names `user@host` (on its own line or the one above).
    - The row is still connected.
    - The VM lists no tmux client on the session.
  - That client replacement requires a fresh status message visible in that row.
  - That `bin/wt` parses under `/bin/bash` (the 3.2 that a fresh Mac ships).
  - That `bin/wt` and `bin/cmux-hook` agree on `tmux_cmd`, on how they merge the windows' row lists, and on
    which field of `cmux list-windows` is a window.
  - The last group is different: it tests the `rm -rf` of `test/lib.sh` itself. No real run reaches that
    `rm -rf`, for two reasons. Both suites build their scratch root with `mktemp -d`. They also refuse a
    root inside the real home before they arm the trap that calls it. The group exists because nobody knows that
    a branch is broken when nothing exercises it.

  On a VM, the suite makes 596 assertions, because scenario 8 is about the Mac's row list. `bin/wt` has no
  `FORCE_OS` that could fake the result of `is_remote()`. So on a VM, `wt new` asks the Mac for a row over the
  relay and never consults cmux at all.
- **Both `install-smoke.sh` and `wt-smoke.sh`** carry an expected-total guard, because a green run hides a
  scenario that silently skips its assertions. The SSH and cmux recovery checks use fakes. Neither suite
  covers a live VM reconnect.
- **`bash test/hosts-smoke.sh`** checks the SSH inventory's JSON, table, alias filtering, concurrent probes, and
  failure states, with a fake `ssh` on a scratch `PATH`. It also executes the probe script against fake
  hardware commands, including malformed GPU output. It verifies the client deadline against a hanging SSH
  process. It does not contact any configured host.
- **`bash test/remote-new-smoke.sh`** uses scratch SSH and cmux stubs. It checks these cases:
  - remote task preflight and model forwarding
  - an older VM's option refusal
  - a row failure after worktree creation
  - an SSH disconnect after creation but before the Mac receives the result
  - that a brief, agent, and model survive an interrupted `.wt-setup`
- **`bash test/github-guard-smoke.sh`** runs 430 assertions of hook payloads through `bin/github-guard`. The
  suite stubs `gh`. The stub answers `gh api` from fixtures by running the guard's own `--jq` filter over them.
  Set `GUARD_BASH=/bin/bash` to run the guard under bash 3.2. The suite checks these results:
  - A command that only mentions `gh api` or `git push` (a commit message, a heredoc, a `grep`) gets no answer.
  - Approved: reads, pushes to any branch but the default one, pull requests, issues, comments, reviews,
    edits of your own issues and comments, and thread resolution.
  - Denied: pipes, substitutions, brace expansions, and control characters.
  - Denied: another repository, named or through `GH_REPO`, `GH_HOST`, or `gh repo set-default`.
  - Denied: someone else's issue or comment, an approval, and any other GraphQL mutation. That includes a
    mutation behind an alias, a fragment, a directive, a comment, or a block string.
  - Denied: force pushes, deletions, and a tag or a bare commit as the source.
  - Denied: the default branch, in all three cases: as GitHub names it, over a stale local HEAD, and when
    nothing can name it.
  - Denied: a body file outside the repository, and `--template`.
  - Denied: a remote whose push URL leaves github.com, including when `wt pr` would push through that remote.
  - `settings.base.json` wires the hook and carries no rule that would override it.
- **`bash test/agent-status-smoke.sh`** checks the VM lifecycle relay and the Mac row status handler with a fake
  cmux. It covers Running, Idle, clear, interruption, delayed events, stale-status expiry, and failed
  self-teardown cleanup. It needs no VM.
- **`bash test/agent-status-linux-smoke.sh`** runs on a Linux VM. It checks the real process owner gate,
  transcript interruption, heartbeat state, and relay timeout against scratch files and a fake cmux.

### Uninstall

**There is no uninstaller.** Undoing an install is manual, and the backup directory is what makes it possible.

> **Warning:** Before you delete anything, write down which opt-ins this machine has. Deleting the links
> destroys that record. The symlink *is* the record, and there is no state file to consult. Without the
> links, a later bare `install.sh`, and therefore `wt update`, would quietly install the default set instead of
> what this machine had chosen. The same applies to `--with-claude-ui`, whose record is the `tui` key inside
> the `~/.claude/settings.json` copy.

1. Get the list of opt-ins. A run names every file it links and every opt-in it left out. So the cheapest
   way to get the list is one more run of `install.sh` before you delete anything.
2. Delete the symlinks that this repo made. Each one points into `~/repos/workgrove`. Check each entry with
   `ls -l` first, and delete only the links into `~/repos/workgrove`:
   - `~/.zshenv` and `~/.gitignore_global`
   - `~/.claude/AGENTS.md`, `~/.claude/CLAUDE.md`, and `~/.codex/AGENTS.md`
   - the skills under `~/.agents/skills/` and `~/.claude/skills/`
   - the `~/.local/bin/` entries
   - `~/.config/cmux/cmux.json` (a link only on a Mac with `--with-cmux-config`; otherwise it is your own file)
   - whichever opt-in files you asked for
3. If `~/.zshrc` is opted in, delete the oh-my-zsh theme link. It is not in `$HOME` itself, so it never appears
   in an `ls -l ~`. It is at `~/.oh-my-zsh/custom/themes/workgrove.zsh-theme`, or under
   `$ZSH_CUSTOM/themes/` when that variable is set.
4. If `~/.zshrc` is opted in, decide whether to keep the two plugins. `install.sh` *clones* the two plugins it
   enables into `$ZSH_CUSTOM/plugins/zsh-autosuggestions` and `$ZSH_CUSTOM/plugins/zsh-syntax-highlighting`.
   They are in the same directory as the theme, but they are not links. They are ordinary git checkouts of
   someone else's repos, yours to delete or keep.
5. If you do not want the three machine-local copies, delete them: `~/.claude/settings.json`,
   `~/.codex/config.toml`, and `~/.codex/hooks.json`.
6. Copy your originals back out of the newest `~/.workgrove-backup/<timestamp>-<pid>/`, which mirrors `$HOME`.
   If you had your own `wt`, `agent-notify`, `cmux-hook`, or `azml-ssh-host` in `~/bin`, it is also there.
   `install.sh` retires those, because `~/bin` comes before `~/.local/bin` on `PATH`, and a copy there would
   shadow the link.
7. Undo by hand the edits that `install.sh` made in place instead of replacing a file. They are not in the
   backup:
   - On a VM: the lines it appended to `~/.zshenv.local`, and the `~/.zshenv` line at the top of `~/.bashrc`.
   - Without `--with-tmux-conf` (for example, on a default run): the `set -ag update-environment` line appended
     to your own `~/.tmux.conf`.
   - Without `--with-gitconfig` (for example, on a default run): the `core.excludesFile` and
     `~/.gitconfig.local` include added with `git config --global`.

## Daily use

This section lists the command or key for each common job. It also gives the rules for task names and the
steps to recover a VM row.

| You want | Do |
|---|---|
| Start a task locally | Type the brief in the cmux TextBox and press ⏎. This runs `wt new -p <brief>`. The second submit action runs Claude in the current checkout instead |
| Start a task from a terminal | Run `wt new fix-auth -a codex -p "…"`. Or press ⌃⌥⌘N to type `wt new` into the current terminal |
| Prepare a VM task before starting its agent | Run `wt -H <vm> new <name> -r <repo> -p "…" --no-workspace`. It creates the VM worktree and saves its brief, agent and model, but it does not make a row. Add files to the worktree. Then run `wt -H <vm> attach -r <repo> <name>` to open the row and start the agent |
| Start a task anywhere | Press ⌃⌥⌘T to open the task picker (`wt task`). Choose where the task runs, then its kind, repo, name and brief |
| Ask the driver | Press ⌃⌥⌘D to open the `driver` row, and ask: "start a task on `<vm>` in repo X to …". The driver session runs `wt -H <vm> new -r X …` and reports the row |
| See tasks | `wt list [--all]`, `wt show <name>`, `wt -H <vm> list` |
| Look at the code | Say "show me the worktree code", and the agent runs `wt open`. Or run `wt open <name>` or `wt -H <vm> open -r <repo> <name>`. Both ways also work from VM sessions |
| Shell on a VM | ⌃⌥⌘T → `<vm>` → `vm-shell`. The row title is `shell`, and its second line is `@<vm>`. If you type a host that is not a configured alias, `wt` tries it as typed. Requests from inside that VM need a real `Host` entry |
| Shell in a repo | ⌃⌥⌘T → where → `repo-shell` → repo. The row title is `<repo> shell` |
| Re-open a VM task's row | Run `wt -H <vm> attach -r <repo> <name>`. For what it does in each state, see [Recover a VM row](#recover-a-vm-row) |
| Reconnect after sleep or Wi-Fi loss | cmux usually reconnects the row itself. If the terminal misbehaves or the row stays `[ssh:suspended]`, see [Recover a VM row](#recover-a-vm-row) |
| Hand back | The agent reports the branch. It runs `wt pr <name>` only when you ask for it |
| Clean up | `wt rm <name>`, `wt -H <vm> rm -r <repo> <name>`, `wt prune` |
| Update a machine | `wt update`, `wt -H <vm> update`. Add `--refresh-config` only after you review a `.base` change |
| Add an Azure ML compute instance | Run `azml-ssh-host add <instance>`, or say "add compute instance X to my ssh config". After that, the instance is a VM like any other ([docs/azml-compute.md](docs/azml-compute.md)) |

### Task names

The task picker accepts a blank name. If the name is blank, `wt` makes the name from the brief. If the name
and the brief are both blank, the name is `task-<timestamp>`. A blank brief is also allowed: the agent starts idle.

`wt` applies these rules to a name:

- It changes the name to lowercase and changes spaces to dashes. For example, "Fix Auth" becomes `fix-auth`.
- After that change, it refuses a name that does not match `^[a-z0-9][a-z0-9_-]{0,62}$`.
- It never allows `.` in a name.

### Recover a VM row

Use this section when the row of a VM task is closed, suspended, or does not work correctly. The recovery
command is `wt -H <vm> attach -r <repo> <name>`. In this section, `attach` means that command.

What `attach` does depends on the state of the task and its row:

| State | What `attach` does |
|---|---|
| The task has never had a tmux session or `.started` marker | It starts the task |
| The row is suspended | It tries to recover the row. See [Recover a suspended row](#recover-a-suspended-row) |
| The row is connected, and its agent is attached | It replaces that task's tmux client (a replacement attach), so tmux sends the mouse, focus, bracketed paste and extended-key settings again |
| A fresh VM check shows the tmux session detached | It reattaches tmux only when the row also shows a recognizable task-shell prompt |
| The task was started before, but it has lost its agent | It refuses and prints the `--restart-agent` line. That line resumes Claude with `-c` |

After sleep or a brief dropout, cmux usually reconnects the row itself. If the row does not reconnect, or
misbehaves after it reconnects, find your symptom in this table:

| Symptom | Action |
|---|---|
| After a reconnect, the mouse wheel types arrow keys, or paste or Shift+Enter misbehaves | Run `attach`. It restores tmux's terminal settings |
| A replacement attach failed and left the row at its shell prompt | At that prompt, run `attach` with `--reattach` |
| After a Wi-Fi network switch, the row shows `[ssh:suspended]` and the relay error | Run `attach`. See [Recover a suspended row](#recover-a-suspended-row) |
| cmux says `remote session was lost; starting a new shell`, the connected row shows a bare shell, and the VM still lists its old tmux client | Run `attach` with `--reattach` |
| The VM rebooted | A VM reboot ends the tmux session. Run `attach` with `--restart-agent` |

#### Recover a suspended row

A Wi-Fi network switch can leave the row `[ssh:suspended]` with this error:

`Error: ssh-pty-attach: The cmux relay on <vm> did not become ready (the host may not allow SSH remote port forwarding). Automatic reconnect paused; use Reconnect to try again.`

The port-forwarding warning in this message is misleading. After the Mac's IP address changes, the old SSH
session may still hold the row's fixed relay port on the VM. So **Reconnect** cannot work until that
session closes.

To recover the row, run `attach`. For a suspended row, `attach` does these steps:

1. It maps the row's daemon slot to its relay port.
2. While the row is suspended, it stops only a user-owned `sshd` (or `sshd-session`, OpenSSH 9.8+) that
   listens on that port on any local address. If that `sshd`'s connection comes from the Mac's current
   address, that session may still be live. So `attach` refuses at this step and signals no process.
3. It calls cmux's reconnect RPC (remote procedure call) for that row and waits up to 30 seconds.
4. It checks the VM session and the row screen.
5. It reattaches a detached tmux session only at a recognizable task-shell prompt. For an attached task, it
   re-initializes the client.
6. Otherwise, it selects the row and prints the exact `--reattach` command.

`attach` also warns when the VM's sshd has no `ClientAliveInterval`. Block 1 of
[docs/new-vm.md](docs/new-vm.md) sets one.

> **Warning:** Inspect the row before you run the printed `--reattach` command.

If recovery fails, do these steps:

1. Wait for the VM to drop the old SSH session. With the keepalive from block 1, this takes about a minute.
2. Press **Reconnect** on the row, or run the same `attach` again.

## `wt` commands

`bash bin/wt help` is the reference, and it includes every flag. This table shows the shape of the command set:

| Command | Does |
|---|---|
| `wt new [name] [-p TEXT] [-a claude\|codex\|none] [-m MODEL] [-r PATH] [-b REF]` | Create the worktree and a cmux row running the agent with the brief and optional task model |
| `wt run <name>` | Run that worktree's agent with its brief. cmux runs this for you |
| `wt list [--all]` | Worktrees, with branch, base, ahead/behind, merged (`yes`, `squash`, `no`), dirty count, last commit |
| `wt show <name> [--diff]` | Path, branch, whether and how it is merged, row, brief, task model when set, and dirty files. Also commits and diffstat compared with the base. On a VM, also the tmux session and whether its agent is running |
| `wt open [name]` | Open the worktree in VS Code. No name means the one you are in |
| `wt attach <name>` | Open a cmux row for a worktree that already exists |
| `wt sync <name> [--merge]` | Rebase (or merge) the branch onto its base |
| `wt pr <name> [--draft]` | Push the branch and open a GitHub pull request |
| `wt rm <name> [--force] [--keep-branch] [--discard-commits]` | Remove a worktree. See [Remove a task](#remove-a-task) |
| `wt prune [--dry-run]` | Remove worktrees whose branch is merged, by ancestry or by content, and whose tree is clean |
| `wt task` | The task picker on ⌃⌥⌘T (Mac, needs fzf) |
| `wt driver` | Open or select the `driver` row |
| `wt update [--refresh-config]` | `git pull --ff-only` this repo, then re-run `install.sh` |
| `wt repos [<name>] [--porcelain\|--table]` | List every repo (name, task count, location on a terminal; `name<TAB>path` when piped), or print one repo's path |
| `wt hosts [--json]` | Probe the Mac's configured SSH aliases for remote-command access and installed CPU, RAM and GPU hardware |
| `wt path <name>`, `wt current`, `wt diff <name>`, `wt help` | Small helpers |
| `wt -H <host> <sub> …` | Run a subcommand on a VM through ssh while the cmux row stays local. `show`, `rm`, `path`, `open` and `attach` need `-r <repo>` |

### Create a task on a VM

Before it creates the worktree, `wt -H <host> new` checks local cmux. It also checks the VM's repo, `wt`,
`tmux` and selected agent. These checks cannot guarantee that `.wt-setup` or the agent itself will run
successfully.

- If row creation fails after the checks, `wt` keeps the remote worktree. It prints commands to inspect and
  attach it.
- If SSH fails during creation, the result is uncertain. Before you retry or choose another host, wait, then
  run `wt -H <host> list -r <repo>` (or `wt -H <host> list` for all configured repos). A disconnected create
  may still be finishing when the first list runs.

With `--no-workspace`, remote `new` skips the cmux check and row creation. It prints the command that starts
the saved task later with plain `attach`.

### Remove a task

`wt rm` refuses to destroy work. It exits with status 3 and names what blocked it. It refuses when it finds
any of these:

- Uncommitted changes.
- Commits that are neither merged into the base nor pushed.
- A base ref that it cannot compare the branch with. This is a base ref that was deleted since, or a
  sidecar from an older `wt` that holds the literal `HEAD`. `HEAD` resolves to the worktree's own tip, so every
  other count would read as nothing to lose.
- A HEAD that is not on the task's branch `wt/<name>`, for example during a `git bisect` or after a
  detached checkout. No branch keeps that state, so removing the worktree would lose it.
- A file that `.wt-include` covers and that was edited or created inside the worktree.

> **Warning:** `--force` overrides these refusals. It also discards unmerged commits.

`wt prune` is stricter still: it only removes worktrees whose branch is
merged and whose tree is clean.

When you ask an agent to remove its own task, the agent does these steps:

1. It reports its work.
2. It changes to the main checkout (the repo's primary working tree, not a worktree).
3. It runs `wt rm <name> -r <absolute-repo-path>`.

`wt rm` still refuses if its command runs inside the worktree that it removes. When the agent closes its own
row, the agent session ends.

On a VM, these rules apply to a task that runs in its own tmux session:

- Before it removes its own worktree, `wt rm` checks that the VM row has relay configuration.
- The task asks the Mac to close that row. The Mac then stops the task's tmux session after removal.
- A refusal leaves both the row and the tmux session open.
- If the agent is still running after the Mac hook's deadline, `wt rm` warns and names the row and session
  to close from the Mac.

### How `wt` decides that a branch is merged

"Merged" means one of two things:

- **The branch is an ancestor of the base.** This is a merge commit or a fast-forward.
- **All of the branch's work is in the base, but its commits are not.** GitHub's "squash and merge" leaves
  this result: one new commit on `main` that carries the whole diff, and the head branch deleted. A
  rebase-merge leaves the same result. So does a cherry-pick into a branch that then merged.

For the second kind, `wt rm` asks git the exact question instead of a heuristic: would merging the branch
into the base's tip change anything? It uses `git merge-tree --write-tree`, in memory, hunk by hunk. With
git older than 2.38, which Ubuntu 22.04 ships, `wt rm` uses a file-level `read-tree` check instead. The
`read-tree` check is stricter in the safe direction.

The answer decides the result:

- **The merge would change nothing.** Every change that the branch made is already in the base, so `wt rm`
  removes the worktree and its branch.
- **The merge would change something.** `wt rm` refuses and says so, for example
  `merging wt/x into origin/main would still change 1 path(s)`. A commit made after the PR merged gives this
  result. So does a squash that the base later partially reverted.
- **The base edited the squashed lines again.** The refusal reads `would conflict`.
- **The branch's net change is empty.** Such a branch passes any merge and proves nothing, so `wt rm`
  refuses it, as it always did.

The check runs offline first. When the check refuses the branch and the base is a remote's branch, `wt rm`
fetches that one branch and runs the check once more. Without that fetch, `origin/main` is whatever the last fetch left,
from before the merge. Offline, the refusal says that the base could not be refreshed.

`--discard-commits` waives only one refusal reason: commits that are neither merged into the base nor
pushed. It waives nothing else. It is for the cases that the check refuses on purpose: a squash that the base
then edited or reverted. The dirty-tree, `.wt-include` and HEAD checks still
apply. `--force` waives all of these reasons.

`wt list` shows the same verdict in its `MERGED` column:

- `yes`: the branch is an ancestor of the base.
- `squash`: the work landed without its commits.
- `no`: any other case. `wt show` prints the reason behind a `no`.

`wt list` and `wt show` are both offline. So, against a base that nobody has fetched since the PR merged,
they read `no` until `wt rm`, `wt prune` or `wt new` refresh it.

### Files that `.wt-setup` writes

When `wt` decides whether it can remove a worktree, it does not count what a repo's own `.wt-setup` wrote.
This exemption exists because of lockfiles: a hook that runs `uv sync` or `npm ci` regenerates a *tracked*
lockfile. Without this exemption, the worktree
would be dirty from the moment `wt new` created it. Every `wt rm` would then be a refusal for the life of
the worktree. So `--force`, the one deliberate way past the refusals, would become the routine way, and it
discards unmerged commits too.

`wt new` hashes whatever the hook left behind into the sidecar. `wt rm` excuses those paths only while they
still hold exactly that content. If you edit the lockfile yourself, it counts again. `wt list` keeps showing
git's own dirty count, with no paths excused.

### Environment variables

| Variable | Meaning |
|---|---|
| `WT_REPOS_DIR` | The folders that `wt` looks for repos in |
| `WT_AGENT` | The default agent |
| `WT_AGENT_ARGS` | Extra agent arguments |
| `WT_HOST` | On a VM, this VM's alias in the Mac's `~/.ssh/config`. `install.sh` records it |

A model chosen with `wt new -m` persists for every `wt run` launch, including Claude resumes. It overrides
model options in `WT_AGENT_ARGS`. When the task has a model, `wt` also removes Claude's `--fallback-model`.
Without `-m`, those arguments still apply.

One related setting is a git config key, not an environment variable: `git config wt.dir` renames the
worktree folder for one repo.

### Repo folders

`WT_REPOS_DIR` may hold several folders separated by `:`, like `$PATH`. `wt` searches them in the order
given. It skips empty entries and folders that are missing or unreadable. It searches a folder named twice
only once. Set it in `~/.zshenv.local`, for example
`export WT_REPOS_DIR="$HOME/work/repos:$HOME/Documents/Repositories"`.

`wt repos` and `wt list --all` cover every folder in the list. Only direct children that hold a `.git`
count as repos. Hidden folders, such as `~/.oh-my-zsh`, never count.

`wt repos` has these output forms:

- **On a terminal**, it prints a table. The table shows the repo name and how many task worktrees it holds
  (`-` for none). It also shows where the repo lives (`~/…` for a folder under this machine's home folder).
  The task picker (⌃⌥⌘T) shows the same name and location columns.
- **Piped, or with `--porcelain`**, it prints `name<TAB>path` per repo. Scripts and the task picker read this form.
- **With `--table`**, it always prints the table. `wt -H <vm> repos` sends this form to a VM.

`wt` looks up a repo name along the list. It refuses a name found in more than one folder and shows both
paths. In that case, pass the path instead.

### Machine inventory

`wt hosts` probes the Mac's SSH hosts for remote-command access and hardware. It probes the same `Host`
aliases in the Mac's `~/.ssh/config` that the task picker lists: literal, wildcard-free and non-exclusion
aliases. Probes are fresh each run. A host can stop or become busy after `wt hosts` lists it.

Probes run concurrently. Each probe uses a noninteractive SSH login with these settings:

- A five-second connection timeout.
- SSH keepalives.
- A 20-second client deadline.
- Strict host key checking.

A failed SSH probe includes a short error reason. `available` means that a remote shell command succeeded.
It does not mean that `wt` or a particular repo is installed there.

`wt hosts` reports the hardware as follows:

- **CPU** is the number of online logical processors.
- **RAM** comes from Linux `MemTotal`, the kernel's usable total. It can be below the machine's label.
- **GPU** entries report the NVIDIA model and the driver-reported total memory. Driver-reported memory can
  also be below the label.
  - `wt hosts` reports GPU entries when `nvidia-smi` finishes within ten seconds, with a two-second
    force-kill grace period.
  - The GPU index must be numeric and unique.
  - `memory_mib` is null when the GPU reports `[N/A]` for memory.

This inventory concerns NVIDIA GPUs, as used by the task machines.

The `gpu_status` field has these values:

| Case | GPU status |
|---|---|
| `nvidia-smi` fails, and a complete scan of Linux PCI devices finds no NVIDIA display device | `gpu_status: "none"` |
| `nvidia-smi` fails, and the scan is incomplete or finds a GPU with a failed driver | `"unknown"` |
| The GPU query succeeds and is empty | `"none"` |
| The GPU entries are malformed | `"unknown"`, so they cannot inflate a task's matching GPU count |

`wt hosts --json` gives agents structured results (`cpu_logical`, `memory_mib`, `gpu_status`, `gpus`) to
match against a request. For a request stated in GB, agents convert decimal GB to MiB before they compare.
For an explicit GiB request, they use 1024 MiB per GiB.

## Agents

This section tells which conventions and skills Claude and Codex share, and what agents never do on their
own.

`install.sh` links [`home/.claude/AGENTS.md`](home/.claude/AGENTS.md) to `~/.claude/AGENTS.md` and
`~/.codex/AGENTS.md`. So Claude and Codex read the same conventions:

- Task work happens in a worktree made with `wt new`.
- A session inside `.worktrees/<name>` stays there and commits on `wt/<name>`.
- Each session reports its row and branch.

The file also states explicitly that these rules are a convention and not a sandbox.

`install.sh` links the six skills in `home/.agents/skills/` into both `~/.agents/skills/` (Codex) and
`~/.claude/skills/` (Claude). They reload live.

| Skill | Triggered by |
|---|---|
| `worktree-create` | "start a task", "work on this in parallel", "try an approach without touching main" |
| `worktree-work` | Being inside a `.worktrees/` directory; "rebase it", "hand it back" |
| `worktree-show` | "show me the code", "open the worktree", "let me see it" → `wt open`; "what changed", "how far is it" → `wt list` / `wt show` |
| `worktree-teardown` | "remove the worktree", "clean up finished tasks" |
| `task-driver` | "start a task on `<vm>`", "queue these three", "check on the tasks" |
| `azml-compute` | "add compute instance X to my ssh config", "which compute instances can I ssh to" |

Agents never do these things on their own:

- They never run `git push`, `wt pr` or `gh pr create`, create a remote repository, or publish. A brief to
  work on or review a pull request counts as asking, but only for that pull request. A brief never counts as
  asking to approve one.
- They never remove a worktree that you did not ask them to remove.
- They never pass `--force` or `--discard-commits`.
- They never open VS Code when you did not ask.
- They never run the interactive `wt attach`, `wt task` and `wt driver`. These belong to your own session.

## cmux notes

This section lists cmux behavior that affects this setup: hotkeys, configuration, notifications, and VM rows.
It also tells how to enable VM status on an existing VM.

### Hotkeys and configuration

All hotkeys use ⌃⌥⌘. The action type sets how a change to a hotkey takes effect.

| Hotkey | What it does | Action type | After you edit it |
|---|---|---|---|
| ⌃⌥⌘N | Types `wt new` into the current terminal | `type: "command"` | Run `cmux reload-config` |
| ⌃⌥⌘T | Opens the task picker | `type: "workspace"` | Quit and relaunch cmux |
| ⌃⌥⌘D | Opens the driver row | `type: "workspace"` | Quit and relaunch cmux |

- **Workspace actions.** cmux binds the shortcuts on a `type: "workspace"` action (T and D) when the app launches.
  That is why you must quit and relaunch cmux after you edit them.
- **Built-in shortcuts.** Built-in cmux shortcuts have priority over config actions, and cmux gives no warning.
  For this reason, `cmux.json` unbinds `toggleBrowserDesignMode` to free ⌃⌥⌘D.
- **The Settings UI.** The Settings UI never writes `cmux.json`. It writes its toggles to macOS defaults.
  It writes terminal appearance settings to `config.ghostty`. This repo cannot carry those changes
  to other machines, so make config changes in `cmux.json`.

### Notifications

This subsection tells how cmux, the agent hooks, and the Mac hook show each agent's status in its row.
It also tells when a desktop banner appears instead, and what else the Mac hook handles.

**On the Mac:**

- cmux tracks Claude rows itself.
- `cmux hooks codex install --yes` merges its generated Codex lifecycle handlers into `~/.codex/hooks.json`.
  With these handlers, a Codex row goes from `running` to `idle` when a turn ends.

**The portable hooks.** The portable hooks are the versioned hooks in `settings.base.json` and
`hooks.base.json`. They call `bin/agent-notify`. That script acts as follows:

- In a local cmux pane, it leaves lifecycle tracking to cmux.
- From a VM pane, it relays the event to the Mac over the cmux socket.
- Otherwise, on a Mac, it posts a desktop banner.

**Status from a VM task:**

- On the VM, the agent that `wt run` starts sends status updates for prompt, completion, interruption,
  and session end.
- On the Mac, the Mac hook (`bin/cmux-hook`) checks that cmux assigned each update to a row connected
  to the host that the update names. Then it sets that row's `vm-claude` or `vm-codex` status
  to Running or Idle, or it clears the status.
- Each status update carries a sequence number, so a delayed update cannot revive an old status.

**The status lease.** While `wt run` is alive, its heartbeat renews a two-minute status lease.
A dead process or a reboot stops the renewals. When cmux next delivers a notification, the Mac hook
clears an expired status pill (the status that the row shows in the sidebar). The hook's background timer,
a detached process, also tries to clear the pill. But after the hook exits, cmux may reject that process.

**Why the VM rows use their own status keys.** cmux 0.64's remote CLI has no sidebar status method and
no agent lifecycle relay. Also, cmux clears its reserved `claude`/`codex` status keys when an SSH pane
has no local agent process. The VM-specific keys, `vm-claude` and `vm-codex`, avoid that cleanup.

**The control notification.** Each status update from a VM reaches the Mac as a control notification.
When the Mac hook is active, this notification does not appear in history or in banners.
If the hook is missing, the fallback is a readable status notification.

**Claude events on a VM row:**

- Claude's `StopFailure` and `idle_prompt` events return its row to Idle.
- After you press Esc, the heartbeat also detects Claude's interruption markers in the transcript,
  including an interrupted tool.
- If you press Esc while Claude is thinking and Claude writes no marker, the row can stay Running
  until the next lifecycle event.
- `/clear` leaves the agent at Idle.

**Requests from VM tasks.** The same Mac hook handles the `wt-open` and `wt-attach` requests.
For `wt-open`, it opens the remote folder in VS Code. For `wt-attach`, it creates the row for the new VM task.

**Codex prompts.** Codex runs with `approvals_reviewer = "auto_review"`. With this setting, Codex approves
sandbox escalations automatically, so a Codex row rarely shows a needs-input state.
Expect that state only when Codex itself prompts you.

### Enable VM status on an existing VM

Do these steps to turn on VM status for an existing VM. Do them in this order.

The Mac enables status relay only when it finds the installed hook and its `cmux.json` entry.
So an old Mac install cannot make an updated VM post status traffic. That is why you update the Mac first.

A plain `wt update` does not replace the machine-local `hooks.json`. That is why step 3 uses `--refresh-config`.

1. Update the Mac.
2. Make sure that cmux has loaded the `notifications.hooks` entry for `cmux-hook` in the Mac's `cmux.json`.
   If you changed `cmux.json`, run `cmux reload-config`.
3. Run `wt -H <vm> update --refresh-config`.
4. In Codex on that VM, run `/hooks`. Review and trust the changed Codex hooks.
5. Exit the agent in the task row.
6. Run `wt -H <vm> attach --restart-agent -r <repo> <name>`.

To check the result, give the agent a prompt. Make sure that the row's status shows Running,
and then Idle when the turn ends.

### VM rows

- VM rows run bash with cmux's shell integration, not zsh. For this reason, `install.sh` gives `~/.bashrc`
  a first line that sources `~/.zshenv`. For the usual prompt, type `zsh` inside the row's tmux.
- The VM paths are implemented and documented here as designed. But they are the newest part of this
  setup. The first time you use one, make sure that:
  - The row appears with its `@<host>` second line.
  - `wt -H <vm> show -r <repo> <name>` reports the tmux session.

## Keeping machines in sync

This section tells you how to apply each type of change on the Mac and then on each VM.
These rules apply:

- You edit on the Mac. VMs pull.
- `wt update` is `git pull --ff-only` plus `install.sh`. So it refuses to run over local edits,
  and it never touches the three machine-local copies.
- A config refresh is always explicit and always backed up.
- Per-machine files stay out of this edit, commit, and pull cycle.

| Change | Mac | VM |
|---|---|---|
| Edit `AGENTS.md`, a skill, `wt` | Skills apply at once. `AGENTS.md` applies at the next session. Commit. | `wt -H <vm> update` |
| Change Claude or Codex settings, or the portable hooks | Edit the `.base` file. Then run `bash ~/repos/workgrove/install.sh --refresh-config && cmux hooks codex install --yes`. Review the portable hooks with Codex `/hooks`. Commit. | Run `wt -H <vm> update --refresh-config`. It rewrites `~/.codex/config.toml` from the `.base` file and drops Codex's hook trust hashes and folder trust. Then, on the VM, re-trust the hooks in `/hooks`. Do **not** run the cmux installer (`cmux hooks codex install --yes`) on the VM. |
| Update cmux, or repair local Codex state tracking | Back up the live (machine-local) `config.toml` and `hooks.json`. Run `cmux hooks codex install --yes`. Check that one turn returns to `idle`. | n/a |
| Add a file (skill, script) | Edit, `bash install.sh`, commit. | `wt -H <vm> update` |
| Change `cmux.json` | The change applies after cmux reloads its config or relaunches (see Hotkeys and configuration). Commit. | n/a |
| Repos in another folder | Add the folder to `WT_REPOS_DIR` in `~/.zshenv.local`. | Edit the `WT_REPOS_DIR` line that `install.sh` wrote in `~/.zshenv.local`. This file is never versioned. |
| New tool | Add the tool to `Brewfile`, then run `brew bundle`. Commit. | Add the tool's install line to [docs/new-vm.md](docs/new-vm.md). Run that line by hand on each existing VM. |
| Promote a machine-local setting into its `.base` file | Compare the live (machine-local) copy with its `.base` file. Copy only the portable keys into the `.base` file. Commit. | Never commit live (machine-local) copies or trust state. |

### After a config refresh

A rewritten config reaches a **new process**, not a running one. A session that was open when
`install.sh` ran keeps the settings it started with.

- After a refresh, exit and resume the sessions you care about, instead of starting them over.
  `claude -c` re-reads the config and keeps the conversation.
- The same rule applies to the shell in a tmux pane. If a tmux pane was open before an `install.sh` run,
  run `exec bash` in that pane. Until you do, the pane does not see the new environment.

### Keep `wt` the same on every machine

`wt update` needs a real clone. On a VM seeded with `rsync`, `wt update` refuses to run until you replace
the seed with a clone.

Update the Mac's `wt` and each VM's `wt` together:

- On the Mac, run `wt update`.
- For each VM, run `wt -H <vm> update`.
- For an uncommitted change, use the rsync seed instead.

You must update them together because `wt -H <vm> …` runs the VM's copy for the remote half of every command.
So a VM that you did not update answers in a vocabulary that this Mac's `wt` no longer expects.

## Security

Everything that this repository installs runs as you, with your keys and your logins. Much of it exists to
remove prompts, and that is its purpose. The six subsections below describe the choices behind it. Read them
before you run `install.sh` on your own machine.

### The Claude permission lists approve and deny commands automatically

[`home/.claude/settings.base.json`](home/.claude/settings.base.json) holds two permission lists:

| List | Entries | What the entries cover |
|---|---|---|
| `permissions.allow` | sixteen | `ls`, `cd`, the read-only git subcommands (`status`, `diff`, `log`, `show`, and the six read-only spellings of `branch`), `git add`, `git commit`, `wt list` and `wt show` |
| `deny` | nine | `git -c`, `git config`, the two `git -C` spellings of `git push`, `git remote add`, `git filter-branch`, `gh repo create`, `gh repo fork` and `gh release create` |

Commands that match an allow entry run with no prompt at all, so an agent commits to its branch without
asking you. Most of the deny entries are things that the Agents section says agents never do on their own.

Plain `git push`, `gh api`, `gh pr`, `gh issue` and `wt pr` are on neither list. `github-guard` decides
those (see the next subsection).

**How the lists are read.** Keep these two rules in mind:

- Deny beats allow whenever both match. Rule specificity does not change that.
- A compound command is split on `&&`, `||`, `;`, `|`, `&` and newlines. A deny entry applies if it matches
  any subcommand, including one nested in a subshell or a command substitution.

**Why each list names every form separately.** Both lists spell out each form for the same reason, which
these two broad entries show:

- The allowlist replaced a broader entry, `Bash(git *)`. That entry also matched
  `git -c alias.x='!<shell>' x`, which runs arbitrary shell with no prompt.
- `Bash(git branch *)` covered `git branch -D` as readily as `git branch -v`.

**Why there is no allow entry for `git -C <path>`.** This is deliberate. Nine `git -C` entries were tried.
They covered `git -C * status`, `diff`, `log`, `show` and `branch`. The reasoning was that a read-only git
command in another worktree is harmless. They were removed again for two independent reasons:

1. They never fired. Claude Code matches rules case-insensitively, so the `git -c *` deny entry also
   catches `git -C`, and deny beats allow.
2. They could not be made safe, because `*` matches any text, not only a path. For example,
   `git -C <repo> -c diff.external=<script> diff` matches `Bash(git -C * diff)` and runs the script. Claude
   Code's own settings validator warns about this shape: a wildcard before the subcommand also approves
   options inserted at that position. A `git -C` entry always has this shape, because the path must come
   before the subcommand.

To read another worktree, agents are told to use `cd <path> && git <subcommand>`. In that form, the wildcard
falls after the subcommand, and the compound-command splitter checks both halves.

**The lists are not enforcement.** They match the text of the command that Claude writes. The Claude Code
permissions documentation says that this "isn't a security boundary around the program". It also warns that
"Bash permission patterns that try to constrain command arguments are fragile". These examples show that
the lists are not a boundary:

- `Bash(gh repo create *)` does not stop `/opt/homebrew/bin/gh repo create`, `bash -c 'gh repo create'` or
  `gh 'repo' create`.
- The `git push` deny rule that the deny list used to carry did not stop
  `git -c core.fsmonitor=<script> -C <path> push`.
- Three of the entries that the allowlist calls read-only are not read-only. `Bash(git diff *)`,
  `Bash(git log *)` and `Bash(git show *)` all accept `--output=<file>`. So any of them will write to any
  path that you can write, with no prompt.

So, read these lists as a statement of intent, written where Claude Code can act on it. They catch the
ordinary spellings that an agent writes. They also save you a prompt on the commands that you would always
approve. For a rule that must hold, use what the documentation points to instead: a sandbox, or a
`PreToolUse` hook that inspects the command itself.

### `github-guard` lets agents work on pull requests and issues

[`bin/github-guard`](bin/github-guard) is a `PreToolUse` hook. It sees every Bash command before the
permission lists do, and it decides the same way on every machine.

**Why a hook replaced the deny rules.** The lists used to deny `Bash(gh api *)`, `Bash(git push *)`,
`Bash(gh pr create *)` and `Bash(wt pr *)` outright. That also blocked reading a pull request's review
comments, because inline comments are only reachable through `gh api`. A hook's allow cannot override a deny
rule. So those deny rules are gone, and `github-guard` decides instead.

**What it approves.** It approves these commands, in the repository that the session is in:

- Reads: `gh api` GET or HEAD, a GraphQL query, `gh pr view|diff|checks|list|status` and
  `gh issue view|list|status`.
- `git push` of `HEAD` or of one local branch, only when all of these are true:
  - It does not push a tag or a bare commit.
  - It does not use force.
  - It goes through a remote whose push URL is on github.com.
  - It does not go to that repository's default branch. To find the default branch, the guard asks GitHub.
    The guard denies the push if `gh` is unavailable or if GitHub does not return a valid branch.
- `gh pr create`, `wt pr` and `gh issue create`. For `wt pr`, the guard first checks the push and the pull
  request destination that `wt pr` runs.
- `gh pr comment`, `gh issue comment` and `gh pr review --comment|--request-changes`.
- `gh issue edit` of an issue that the `gh` login opened.
- Through `gh api`:
  - a new issue
  - a comment on an issue or pull request
  - an inline review comment or a reply
  - a review with inline comments
  - an edit of an issue, comment or review that GitHub says the `gh` login wrote
- A GraphQL mutation whose only fields are `resolveReviewThread` or `unresolveReviewThread`.

**What it denies.** It denies every other thing that those commands can do. Each denial gives a reason that
names the approved form, so an agent rewrites the command instead of waiting for you. Approving a pull
request is one of the denied actions, because an approval from your login counts toward branch protection.

Exception: the guard does not decide closing, reopening, deleting or transferring an issue. It leaves these
actions to the permission lists, so they show a prompt.

**What it requires of a command.**

- It approves only a command that it can read in full. That is one simple command with nothing that a shell
  would expand. It has no pipe, redirect, `;`, `&&`, `$`, backtick, glob, brace expansion, control character
  or unquoted newline. So nothing that the guard has not read can run beside it.
- A `--body-file` must be a regular file in the repository or in a temp directory. So a prompt injection
  that says "post ~/.ssh/id_rsa" gets a denial instead of a comment.
- It refuses `--template`, because `gh pr create` reads a template from any path.
- `gh` picks the repository itself for a `gh api` endpoint that uses `{owner}/{repo}`, and for every `gh pr`
  or `gh issue` command. For these commands, the guard approves a write only while `GH_REPO`, `GH_HOST` and
  `gh repo set-default` all leave `gh` pointed at one of the repository's github.com remotes. Each of the
  three can send `gh` elsewhere.

**Limits.**

- It answers only a command that *starts* with one of the commands that it governs. It looks only at the
  start because that is the only place where it can find one without a shell parser. A later `git push`
  could be a line of a commit message. So `npm test && git push --force origin main` and `env git push …` go
  to the permission lists, which no longer deny them. Outside auto mode, they prompt. In auto mode, they go
  to the auto mode classifier.
- **Warning:** On a machine whose `settings.json` still allows `Bash(git *)`, these commands run, including
  `npm test && git push --force origin main`.
- It does not check a thread resolution against the repository, because a thread id does not say which
  repository the thread belongs to.
- It reads `GH_REPO` and `GH_HOST` from the environment that Claude Code runs hooks with. So it would not
  see a value that is set only inside the Bash tool's own shell.
- On a machine with Git's `push.followTags=true`, an approved branch push can still send annotated tags with
  it. The guard does not inspect that setting.
- The default-branch check fails closed when `gh` cannot reach GitHub, even if Git credentials would permit
  a push. The denial suggests that you check `gh` authentication and network access. The guard does not
  make a second connection request.
- An agent can still write whatever the machine's `gh` login and Git credentials allow. The guard catches
  the ordinary spellings of a force push or of a push to the default branch. Branch protection on GitHub
  and a token scoped to the repositories that you work on are the controls that hold.

### The hooks run scripts from this repository on every turn

Three files connect events to scripts:

- `settings.base.json` connects six Claude events (`UserPromptSubmit`, `PermissionRequest`, `Notification`,
  `Stop`, `StopFailure`, `SessionEnd`) to `agent-notify`. It also connects `PreToolUse` on every Bash
  command to `github-guard`.
- `hooks.base.json` connects Codex's prompt, permission, completion, interruption and session-end events to
  scripts.
- `cmux.json` gives cmux `~/.local/bin/cmux-hook` as a notification hook.

These scripts are symlinks into this repository's `bin/`, and they run as you. So `wt update` is a
code-execution event, not a data update. A pull changes the scripts, and the changed scripts then run by
themselves, with nothing to restart. For this reason, `wt update` does two things:

- It prints the incoming commits and a diffstat, and asks before it fast-forwards and runs `install.sh`
  again.
- When stdin is not a terminal, it refuses to apply the commits at all.

Before you approve the update, read that diff as you would read any other pull that lands on your `PATH`.

### Every host that you open a cmux `ssh` row to is inside this Mac's trust boundary

**Warning:** Any host that you keep a `cmux ssh` row to can make two requests to the Mac. It can ask the
Mac to open any path on that host in a VS Code remote window. It can also ask the Mac to create a row that
runs `wt run` there. Anyone with an account on that host can make these requests. So trust each such host as
much as you trust yourself. Prefer single-user machines for task rows.

**How a VM asks the Mac for work.** `wt` on a VM cannot open VS Code or make a row itself. It sends a
`wt-open` or `wt-attach` notification over the row's relay socket. Then the Mac hook, `bin/cmux-hook`, does
the work on the Mac.

**What the Mac hook checks.** The hook is strict about what it acts on. It requires these conditions:

| Check | Condition |
|---|---|
| `valid_host` | The host looks like a hostname. |
| `known_host` | The host is a literal `Host` entry, with no wildcard, in `~/.ssh/config`. |
| `from_row_on_host` | The notifying row is itself a `cmux ssh` row pointed at that same host. |
| `safe_path` | A path is absolute, with no `..`, no `//`, no trailing slash and no shell metacharacters. |
| Name pattern | A task name matches `^[a-z0-9][a-z0-9_-]{0,62}$`. |

**What the checks limit.** The limits are real, but narrower than they first seem:

- They limit the destination. Only a host that is already aliased in your own `~/.ssh/config` can be named
  at all. So nothing can send the Mac to a machine that you never configured.
- They limit the shape of a path and of a name, so neither can carry a shell command.
- They do not stop that host from asking the Mac for two things, because these requests are the purpose of
  the feature:
  - to open any path on that host in a VS Code remote window
  - to create a row that runs `wt run` there

**The checks also stop one host from naming a different host.** This is now measured rather than assumed:

- cmux authorizes a relayed notification against the surface and workspace ids in the sender's environment.
- cmux refuses any request whose identity is not the one that the relay connection itself holds. It rejects
  a request that names another row's workspace id as `remote_relay_workspace_denied`. It rejects a stale or
  borrowed surface as `remote_relay_surface_denied`.

So a VM can send a notification only as its own row. The workspace id that `from_row_on_host` reads shows
where the message came from. It is not a claim that the sender makes. So the check is a proof of origin,
although it was written only as a consistency check.

The `--workspace` flag does not authorize the request. It also does not decide which row cmux records the
notification against, on `cmux ssh` rows or locally. `wt` still passes `--workspace` with its own row, so the
flag agrees with the environment instead of contradicting it.

The signal that would show the origin directly is still unusable. On cmux 0.64, a `cmux ssh` row's own
notifications report `CMUX_NOTIFICATION_ORIGIN=local` instead of the documented `ssh-relay:<uuid>`. So the
relay's own refusals are what show the origin.

**The proof depends on the row list.** The proof is only as good as the row list that the hook reads. The
window scoping in "Rows are found by title, in every window" (in [How it works](#how-it-works)) affected
this check most. Before the fix:

- A hook has no caller surface. So the hook's row list answered only for the window that was current.
- When the user had moved a task row into another window, the hook could not show that the row belonged to
  the asking host. The check failed closed. The VM's `wt open` did nothing except write a line to
  `~/.local/state/cmux-hook.log`.

Now `ws_load` merges the row lists of every window. This widens what the check can see, not what it will
accept. The check still finds the row whose id is the sending row's workspace id, and compares that row's ssh
destination with the host.

**The relay ids must be current.** Because cmux enforces identity this way, every one of the six ids must be
current. They are the six variables that the `update-environment` line in `~/.tmux.conf` lists:
`CMUX_SOCKET_PATH`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_PANEL_ID`, `CMUX_TAB_ID` and
`CMUX_TERMINAL_LIFECYCLE_ID`.

A tmux pane keeps the identity of the cmux connection that started it. After cmux reconnects a row, cmux
refuses a pane that holds the old ids, and `wt new` on a VM can never ask for a row. Two things prevent this:

- `~/.tmux.conf`'s `update-environment` line carries all six into the tmux session environment on each
  attach.
- `wt` reads them again from the session environment at call time, instead of trusting the values that the
  pane started with.

**Within one host, the check is deliberately loose.** It asks only whether the notifying row is a remote row
whose destination is that host. It does not ask whether a task lives there, or whether you ever ran `wt` on
that host. So the rows that can send these requests include at least every `cmux ssh` row that you have
open to any aliased host. That can be a task VM, but equally a shared bastion, a customer's jump host or a
build box.

The path has no limit beyond the `safe_path` shape check. It can be `/etc` or a home `.ssh` directory.

The relay socket is loopback TCP on the remote host. So anyone with an account on such a machine can make
both requests: open a path, or create a row.

### Codex approves its own escalations

[`home/.codex/config.base.toml`](home/.codex/config.base.toml) sets `approval_policy = "on-request"` with
`approvals_reviewer = "auto_review"`. So when Codex asks to cross the sandbox boundary, a model reviews the
request instead of you. The model can approve it in seconds, with no human prompt. The sandbox boundary is a
speed bump, not a consent gate: it can delay an escalation, but it does not ask for your consent. This is
also why a Codex row rarely shows a needs-input state.

To review each escalation request yourself:

1. Set `approvals_reviewer = "user"` in `home/.codex/config.base.toml`.
2. Run `install.sh --refresh-config`.

Codex then asks you before it crosses the sandbox boundary.

### Two smaller choices

**`.wt-setup` runs as you.** When a repository's `.wt-setup` is executable, `wt new` runs it inside the new
worktree. So if you start a task in a repository that you have not read, you run that repository's script
as you.

**`azml-ssh-host` trusts a new host key on first use.** `azml-ssh-host` makes its one verification login
with `StrictHostKeyChecking=accept-new`. This records the first host key that a new instance offers, without
asking you.

- Reason: Azure ML instances are created and destroyed often. If you confirmed a key for each one, that
  would be most of what you did with the tool.
- Risk: this is trust on first use. Whoever can intercept that first connection can present their own key
  instead.
- Scope: only that verification login relaxes the check. The `Host` block that the tool writes does not
  carry the option. So later connections use your normal ssh settings, and a host key that changes
  underneath you still stops the connection.

## Known limitations

This section lists the known problems in this setup, their causes, and what you can do about them.

### A VM row is slower to show than a local row

A `cmux ssh` row is slower than a local row:

- When you select a VM row, it takes roughly 1 to 3 seconds to paint. A local row takes about a quarter of a second.
- A VM row takes about 7 seconds to create.

The connection, the network, and the agent do not cause these delays. The row's screen is already on the Mac,
and it reads back instantly while the row is hidden. So the delay is in cmux's own remote-surface path.

The upstream cmux issue for this problem is [manaflow-ai/cmux#13648](https://github.com/manaflow-ai/cmux/issues/13648).
For now, this setup accepts the delay as tolerable.

If the delay ever stops being tolerable, the alternative is to build VM rows as plain local terminals.
Such a row would work as follows:

- Each terminal would run `ssh -t <host> tmux …`, with the cmux socket forwarded back for notifications.
- The row would paint as fast as any local row.
- The row would give up three cmux features: the SSH badge, managed reconnect, and the relay.

### A Codex session on a VM can need escalation to reach the Mac

Codex's sandbox does not let a command create sockets, and the relay that a VM row uses is a loopback TCP socket.
So a sandboxed `wt open` or `wt new` can fail to notify the Mac. If this happens, rerun the command with
escalation. The relay then works.

This limit does not apply to:

- Claude sessions on a VM.
- Codex's lifecycle notifications, because they run outside its command sandbox.

On a VM, `wt open` reports its result as follows:

- **Success.** `wt open` says that the Mac was asked to open VS Code. It also prints a manual fallback command,
  `wt -H <host> open -r <repo> <task>`, to run on the Mac if no window appears. cmux confirms only that it
  accepted the request. It does not confirm that the Mac hook opened a window.
- **Relay failure.** `wt open` exits nonzero and prints the same manual command as the recovery step.

If the relay fails, run the manual command on the Mac. Where you run it depends on its subcommand:

- If it is an `open` command, use any Mac shell.
- If it is a `new` or `attach` command, use a cmux terminal, because these subcommands need the cmux socket.

Allowing network access in `[sandbox_workspace_write]` does not solve this problem, because it does not lift the
loopback restriction. It would also open outbound network access for every command that Codex runs on the VM.

### The notification hooks find `agent-notify` on `PATH`

The portable hooks in `home/.claude/settings.base.json` and `home/.codex/hooks.base.json` call `agent-notify`
by its bare name. `~/.zshenv` puts `~/.local/bin` on `PATH` for every zsh. So any program that a shell starts
finds `agent-notify`.

If a program that bypasses the login shell launches an agent, the hooks of that agent do not find `agent-notify`.
The hook then fails silently, without a report of a missing command.

If that ever happens, change the portable hooks to use the absolute path `~/.local/bin/agent-notify`.
`cmux.json` already calls `cmux-hook` in this way.

## Deliberately left out

This setup does not include the items below. Each item gives the reason.

- **Tailscale.** It is optional hardening. This setup works over the ssh that you already have.
- **mosh.** This setup installs it on neither the Mac nor the VM. Also, cmux's `mosh-tmux` profile connects
  only one row per host. Instead, a VM task row is a plain `cmux ssh` row. The row's shell creates or attaches
  the task's tmux session.
- **Agent-native worktree features** (`claude --worktree`, `codex --worktree`, worktree-creation hooks). They
  overlap with `wt`. If you mix them with `wt`, you get nested or duplicate worktrees.
- **Checksummed session names and stored file hashes.** `wt` gets the same safety with names that you can read:
  - At removal time, it compares copied files with their source.
  - At creation time, it checks for an identity clash.
- **Personal tooling on VMs or in the `Brewfile`.** This setup adds only the tools that it uses itself. That is
  why the `Brewfile` has a line (commented out) for the Azure CLI: `azml-ssh-host` needs it. For any other tool
  that you install yourself, the shell files use the tool only if it is installed.
