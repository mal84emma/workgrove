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
The [cmux integration contract](docs/cmux-integration.md) lists the commands, fields, environment variables, and measured behavior.
The [Mac–VM protocol](docs/vm-protocol.md) defines remote commands, result records, relay requests, and the tmux environment.

- **Identity.** Each row that a task owns has the task name `<name>` as its title.
  Each kind of row has its own title:

  | Row title | What the row holds |
  |---|---|
  | `<name>` | a task |
  | `<repo> shell` | a shell in a repo |
  | `shell` | a shell on a VM |
  | `driver` | the driver session, that is, the agent session that starts and watches tasks |

  The description line of a row shows as the **second line** of its sidebar entry.
  On a task row, the second line reads `@<host> · <repo>`, for example `@local · workgrove` or `@<vm> · workgrove`.
  The separator is a space, a middle dot (U+00B7), and a space.
  On the other rows, the second line reads `@local` or `@<host>`.
  So you always know where a session runs, and which repo a task belongs to.

  Two repos can have tasks with the same name. Their rows have the same title, and the repo on the second line tells them apart.
  So `wt` and `bin/cmux-hook` find a task's row by its title, its repo, and its host.

  Leave a task row's second line as `wt` wrote it. If you edit or clear it in cmux, `wt` no longer finds the row.
  `wt rm` still checks such a row for a running agent, as [Remove a task](#remove-a-task) describes.

  An older `wt` gave task rows the title `<repo>:<name>` and the second line `@<host>`.
  `wt rm`, the name check of `wt new`, `wt -H <vm> new`, `attach` and `rm`, and `bin/cmux-hook` still find such a row.
  The row keeps its old title until you close it. `wt show` prints the label in the new form, from the task's saved data.

  A new VM task row gets its second line just after cmux creates it.
  If cmux cannot write that line, `wt` and the hook close the new row, because no later lookup could find it.

  A task on a VM also has the tmux session `wt-<repo>-<name>`. This session keeps the agent alive across disconnects.
  The row itself is only a plain `cmux ssh` row, so the tmux session, not the row, gives this persistence.
  The shell that the row opens creates that tmux session, and the session runs the agent.
  If the session already exists, the shell takes it over instead.

- **Rows are found by title, repo and host, in every window.**
  The **Mac hook** is `bin/cmux-hook`, the native notification event handler on the Mac.
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
  - *The earlier evidence:* Measured on cmux 0.64, a row keeps its id, its title and its `workspace:N` ref when it moves.
    Every command that acts on a row (select, send, close, set-description) finds the row by id in any window.
    Only the listing is limited to the caller's window.
    On cmux 0.65.1, a moved native VM row kept its UUID, title, and ref.
    Combined window lookup, description updates, targeted input, and self-removal also passed.
  - *The decision:* `cmux_rows_load` in `lib/workgrove/cmux.sh` enumerates the windows and merges their row lists. Both `rows_json` and the Mac hook use it.
    Because the commands that act on a row already reach it in any window, no other code had to change.
    The loader uses window UUIDs because opening a window renumbers the indices that `cmux list-windows` prints first.

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

See [Layout](docs/development.md#layout) for the tracked files and their roles.

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
- **`bash`:** the scripts in `bin/` need version 5 or later. Ubuntu 22.04 and 24.04 ship bash 5.1 and 5.2.
  macOS ships only `/bin/bash` 3.2, so `Brewfile` installs Homebrew's bash.
  - When `/bin/bash` starts a script in `bin/`, the script checks two Homebrew candidates in order.
    It uses the first bash 5 or later: `/opt/homebrew/bin/bash`, then `/usr/local/bin/bash`.
  - Without a bash 5, `wt`, `azml-ssh-host`, and `wt-ssh-host` stop with a message that names `brew install bash`. The hooks
    exit 0 and do nothing, so they block no agent and no notification.
  - `install.sh` still runs under bash 3.2. To check that, run its smoke test with `INSTALL_BASH=/bin/bash`
    (see Tests).
- **Python and OpenSSH:** SSH registration and portable remote setup need Python 3.9 or later. SSH registration also needs OpenSSH.
- **tmux:** the VMs have tmux 3.2a, and `home/.tmux.conf` is written for that version.
- **cmux:** workgrove supports 0.65.1 (build 110). Version 0.65.2 is unverified.
  Support moves to a newer release after verification, rather than automatically when that release appears.
  See the [cmux compatibility log](docs/cmux-integration.md#cmux-compatibility-log) for verified behavior and remaining checks.
  `home/.config/cmux/cmux.json` is `schemaVersion: 1`.
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

| Flag | Asks for | What arrives instead when you leave it out |
|---|---|---|
| `--with-zshrc` | `~/.zshrc`, with the oh-my-zsh theme, the oh-my-zsh prerequisite, and a clone of the two plugins that it enables | Nothing. Your `~/.zshrc` stays untouched. A default install therefore has no oh-my-zsh prerequisite and no network step at all. |
| `--with-gitconfig` | `~/.gitconfig`: `core.excludesFile`, the github.com credential helper, and the `~/.gitconfig.local` include | Its two core-setup settings only, written into your own `~/.gitconfig`. See the fallbacks below. |
| `--with-tmux-conf` | `~/.tmux.conf`: tuning that makes Claude in tmux feel like a bare terminal (listed below the table) | Nothing. Your `~/.tmux.conf` stays untouched. |
| `--with-keybindings` | `~/.claude/keybindings.json` | Nothing. Claude keeps its own keymap. |
| `--with-statusline` | `~/.claude/statusline-command.sh` | Nothing. Also, `install.sh` strips `statusLine` from the `~/.claude/settings.json` copy, because that key names a script that would not be there. |
| `--with-claude-ui` | The `tui`, `voice`, and `theme` keys and `env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS` in `~/.claude/settings.json`. | VMs use fullscreen mode. Other UI preferences remain unset. On the Mac, fullscreen remains opt-in too. Hooks and permissions arrive either way. |
| `--with-cmux-config` | `~/.config/cmux/cmux.json` (Mac only). It holds the palette, the sound overrides, the sidebar layout, the three ⌃⌥⌘ hotkeys, and the tab-bar buttons. With it come `~/.config/ghostty/config` and its two themes in `~/.config/ghostty/themes/`, each one a separate link. cmux renders its terminals with Ghostty and reads that config for the font, theme, and colors. The config names SF Mono, which macOS ships only inside Terminal.app. So `install.sh` copies each missing `SF-Mono-*.otf` file into `~/Library/Fonts`, and never replaces a file that is already there. When a symlink manages `~/.config/ghostty` or `~/.config/cmux`, for example from stow, `install.sh` links nothing into it and names the skip in its summary. | Nothing. Your `~/.config/cmux/cmux.json`, your Ghostty config, and your fonts stay untouched. |

The full `~/.tmux.conf` from `--with-tmux-conf` tunes tmux with true color, a 10 ms `escape-time`,
Shift+Enter, and focus events. It also makes the mouse wheel scroll instead of typing arrow keys.

`~/.zshenv` and `~/.gitignore_global` are not opt-in config. They are the contract that the tools rely on, not
personal preference:

- `~/.zshenv` puts `~/.local/bin` on `PATH` and carries `WT_HOST` and `WT_REPOS_DIR`. On a Mac, it also points
  cmux at the `claude` and `codex` binaries in `~/.local/bin`
  (see [Block 4 of the Mac setup](docs/new-mac.md#block-4-agents-codex-hooks-and-logins)).
- `~/.gitignore_global` is the file that git-ignores `.worktrees/`.

Every `install.sh` run ends with a summary of skips and follow-up actions.
Empty groups show `none`, including on failed runs.
The summary lists each refresh command once and retains the required opt-in flags.
It separates file opt-ins from settings that require a refresh.
The summary still prints if temporary-file cleanup fails. Cleanup failures retain their exit status.

### Fallbacks that edit your own files

When you leave out `--with-gitconfig`, `install.sh` adds the core setup to your own file:

- **`~/.gitconfig`:** `install.sh` writes two settings with `git config --global`. `core.excludesFile` is what
  git-ignores `.worktrees/`. The `~/.gitconfig.local` include is where your identity lives. Every other line
  of your file stays as it is.
- **`~/.cmuxterm/automations.json`:** On the Mac, `install.sh` adds the `wt-native-relay` rule for native VM requests.
  It updates a changed rule and preserves an explicit `enabled: false` setting.
  It preserves other rules and backs up the file before replacement.
  It reports unknown schema versions on stderr and skips their merge.
  Run `cmux automation reload` after installation.
  See [VM requests after cmux 0.65](docs/vm-open-relay.md) for the transport changes and existing-row recovery.

There is one deliberate exception to these fallbacks. If `core.excludesFile` already points at a file of your
own, `install.sh` keeps that file and does not overwrite it. It prints a message instead. In that case, add the
lines of `.gitignore_global` to your file yourself. The reason for the exception is that an overwrite would
silently drop every global ignore you had. That harm is what this whole opt-in design is about.

### How the choice persists

Each machine's opt-in choice is sticky, that is, later runs keep it. Nothing is stored anywhere that could
disagree with it. A destination that is already a symlink into this repo counts as opted in. So `wt update`,
which re-runs `install.sh` with at most `--refresh-config`, keeps what each machine chose.

- **Opt in later:** run `install.sh --with-…` yourself once. After that, `wt update` carries the choice.
  (For `--with-claude-ui`, see below.)
- **Opt-ins left out:** a run that leaves some out names them, and names the flag that would install each.

`--with-claude-ui` is sticky too, but it has a different record. The other six are sticky because of the
symlink itself, and keys inside a copied file leave no such trace. But the copy is its own record. A
Mac copies use the `tui` key as that record.
VM copies use theme, voice, or mouse preferences; fullscreen alone does not select the other preferences.
A later `--refresh-config` preserves the recorded opt-in.

If you give `--with-claude-ui` on its own (without `--refresh-config`) on a machine whose copy was written
without it, the flag changes nothing. The run says so instead of reporting success.
Run `install.sh --with-claude-ui --refresh-config` to add the UI keys.
The summary includes both flags because the existing copy cannot remember the requested opt-in.

### File classes

`install.sh` sorts every file into one of three classes.

| Class | Files | Behavior |
|---|---|---|
| Symlinks | `~/.zshenv`, `~/.gitignore_global`, `AGENTS.md`, `CLAUDE.md`, the skills, `bin/*`, and every opt-in file you asked for. `cmux.json` and the three Ghostty files are among them (Mac only, under `--with-cmux-config`). | Edits, including an agent's, land in the repo, so `git diff` is the review. |
| Machine-local copies | `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.codex/hooks.json` | Both installers create them from the versioned `.base` files with the shared policy below. The apps write local state into them. A classic install keeps existing copies unless you specify `--refresh-config`. Portable setup preserves personal settings and merges hooks on every full setup. Both hook merges preserve foreign commands and their group settings. |
| Never touched | `~/.gitconfig.local`, `~/.zshrc.local`, `~/.zshenv.local` (which on a VM gains the `WT_HOST` and `WT_REPOS_DIR` lines when they are absent), and the real directories the apps write into | Your machine-local overrides. The linked files source or include them, but `~/.zshrc.local` only when `~/.zshrc` is one of the linked files. |

A foreign hook command is an existing command string absent from the new `.base` file.
A refresh keeps each foreign command with its matcher and other group settings.
For a mixed group, it keeps only the foreign commands.
Commands present in the base use the base's groups and matchers.
The comparison uses the complete command string, including its arguments.

When a base command changes, refresh preserves its previous command string as foreign.
Remove obsolete entries from machine-local copies after you review the backup.
This release changes bare `agent-notify` commands to `~/.local/bin/agent-notify`.
A refresh keeps the old bare commands alongside the new commands.
After you check the backup, remove the old bare commands from both JSON files to prevent duplicate notifications.

Both installers read [the agent configuration policy](lib/workgrove/agent-config-policy.json).
The ordered `settings` rows define deletions and values for new Claude copies.
The `codex_remote` row defines the Codex edits for classic VMs and portable hosts.
An empty `env` object is removed after the edits.

| Policy | Mac | Classic VM | Portable host | Reason |
|---|---|---|---|---|
| Claude `voice` and `voiceEnabled` | The base `voiceEnabled` remains. `voice` requires UI opt-in. | Both keys are removed. | Both keys are removed. | Remote hosts do not use local voice input. |
| Claude `theme`, `voice`, and `env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS` | They require `--with-claude-ui`. | They require `--with-claude-ui`; voice is always removed. | They are removed from new copies. | These personal preferences require consent. Portable setup has no UI opt-in. |
| Claude `statusLine` | It requires `--with-statusline`. | It requires `--with-statusline`. | It is removed from new copies. | Portable setup does not install the status line script. |
| Claude `tui` | It requires `--with-claude-ui`. | It is `fullscreen`. | It defaults to `fullscreen`; existing personal values remain. | Remote agents use tmux task rows. |
| Claude `prefersReducedMotion` | The base value remains. | It is `true`. | It is `true` in new copies. | Both remote layouts need steady tmux task rows. |
| Codex credentials and animations | The base file remains unchanged. | The Keychain setting is removed; terminal user interface (TUI) animations are disabled. | The same edits apply to new copies. | Remote hosts lack the Mac Keychain and need steady task rows. |
| Existing copies | A normal run keeps them. Refresh replaces settings and merges hooks. | The Mac rule applies. | Full setup merges hooks and supplies missing `tui`. It preserves other settings and Codex trust data. | Portable setup preserves selected personal configuration, including migrated files. |
| Hook merge | Refresh puts base groups first, then foreign groups. | The Mac rule applies. | Every full setup uses the same rule. Restore-only leaves agent files unchanged. | Base commands use current matchers. Foreign commands retain their group settings. |

Classic opt-in flags remain sticky across refreshes.
Portable setup has no equivalent opt-in flags.
The hook comparison uses command strings across the complete document, including commands in different events.
When a portable update replaces an old base group, its commands use the new base matchers and options.

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

See [Tests](docs/development.md#tests) for local checks, GitHub Actions, and test fixtures.

### Uninstall

**There is no uninstaller.** Undoing an install is manual, and the backup directory is what makes it possible.

> **Warning:** Before you delete anything, write down which opt-ins this machine has. Deleting the links
> destroys that record. The symlink *is* the record, and there is no state file to consult. Without the
> links, a later bare `install.sh`, and therefore `wt update`, would quietly install the default set instead of
> what this machine had chosen. The same applies to `--with-claude-ui`, whose record is inside the machine-local settings copy.
> VM fullscreen alone does not record that opt-in.

1. Get the list of opt-ins. A run names every file it links and every opt-in it left out. So the cheapest
   way to get the list is one more run of `install.sh` before you delete anything.
2. Delete the symlinks that this repo made. Each one points into `~/repos/workgrove`. Check each entry with
   `ls -l` first, and delete only the links into `~/repos/workgrove`:
   - `~/.zshenv` and `~/.gitignore_global`
   - `~/.claude/AGENTS.md`, `~/.claude/CLAUDE.md`, and `~/.codex/AGENTS.md`
   - the skills under `~/.agents/skills/` and `~/.claude/skills/`
   - the `~/.local/bin/` entries
   - `~/.config/cmux/cmux.json` (a link only on a Mac with `--with-cmux-config`; otherwise it is your own file)
   - `~/.config/ghostty/config`, `~/.config/ghostty/themes/learning-dark`, and
     `~/.config/ghostty/themes/learning-light` (links under the same condition)
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
6. On a Mac with `--with-cmux-config`, decide whether to keep SF Mono. `install.sh` copied the
   `SF-Mono-*.otf` files that were missing into `~/Library/Fonts`. They are copies, not links, so they stay
   until you delete them.
7. Copy your originals back out of the newest `~/.workgrove-backup/<timestamp>-<pid>/`, which mirrors `$HOME`.
   If you had your own `wt`, `agent-notify`, `cmux-hook`, or `azml-ssh-host` in `~/bin`, it is also there.
   `install.sh` retires those, because `~/bin` comes before `~/.local/bin` on `PATH`, and a copy there would
   shadow the link.
8. Undo by hand the edits that `install.sh` made in place instead of replacing a file. They are not in the
   backup:
   - On a VM: the lines it appended to `~/.zshenv.local`, and the `~/.zshenv` line at the top of `~/.bashrc`.
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
| Reconnect after sleep or Wi-Fi loss | cmux usually reconnects the row itself. If the terminal misbehaves or the row does not reconnect, see [Recover a VM row](#recover-a-vm-row) |
| Hand back | The agent reports the branch. It runs `wt pr <name>` only when you ask for it |
| Clean up | `wt rm <name>`, `wt -H <vm> rm -r <repo> <name>`, `wt prune` |
| Update a machine | `wt update`, `wt -H <vm> update`. Add `--refresh-config` only after you review a `.base` change |
| Prepare or restore a portable host | Run `wt -H <host> setup --root <root>` with the [setup options](docs/remote-setup.md). Check `wt -H <host> doctor --json`. See [Runpod preparation](docs/runpod.md). |
| Register a supplied SSH fragment | Run `wt-ssh-host add <host> --fragment <path>` ([registration guide](docs/ssh-hosts.md)). Existing usable SSH aliases require no helper. |
| Add an Azure ML compute instance | Run `azml-ssh-host add <instance>`, or say "add compute instance X to my ssh config". After that, the instance is a VM like any other ([docs/azml-compute.md](docs/azml-compute.md)) |

Use `wt <command> -h` to show that command's help.
Use `--` to end options before a positional argument.
Valued long options accept both `--repo=PATH` and `--repo PATH`.
Repeated options use their last value.

Direct `wt attach` accepts `-a`/`--agent` and `-p`/`--prompt` to update the saved agent and brief.
Direct invocation can run on the Mac or inside a VM.
The `wt -H <vm> attach` form rejects those options.
It accepts `--reattach` and `--restart-agent` for VM session recovery.
Direct invocation rejects those recovery options.

### Task names

The task picker accepts a blank name. If the name is blank, `wt` makes the name from the brief. If the name
and the brief are both blank, the name is `task-<timestamp>`. A blank brief is also allowed: the agent starts idle.

`wt` applies these rules to a name:

- It changes the name to lowercase and changes spaces to dashes. For example, "Fix Auth" becomes `fix-auth`.
- After that change, it refuses a name that does not match `^[a-z0-9][a-z0-9_-]{0,62}$`.
- It never allows `.` in a name.

### Recover a VM row

Use this section when the row of a VM task is closed or does not work correctly. The recovery
command is `wt -H <vm> attach -r <repo> <name>`. In this section, `attach` means that command.

What `attach` does depends on the state of the task and its row:

| State | What `attach` does |
|---|---|
| The task has never had a tmux session or `.started` marker | It starts the task |
| The row is connected, and its agent is attached | It replaces that task's tmux client (a replacement attach), so tmux sends the mouse, focus, bracketed paste and extended-key settings again |
| A fresh VM check shows the tmux session detached | It reattaches tmux only when the row also shows a recognizable task-shell prompt |
| The task was started before, but it has lost its agent | It refuses and prints the `--restart-agent` line. That line resumes Claude with `-c` |

After sleep or a brief dropout, cmux usually reconnects the row itself. If the row does not reconnect, or
misbehaves after it reconnects, find your symptom in this table:

| Symptom | Action |
|---|---|
| After a reconnect, the mouse wheel types arrow keys, or paste or Shift+Enter misbehaves | Run `attach`. It restores tmux's terminal settings |
| A replacement attach failed and left the row at its shell prompt | At that prompt, run `attach` with `--reattach` |
| cmux says `remote session was lost; starting a new shell`, the connected row shows a bare shell, and the VM still lists its old tmux client | Run `attach` with `--reattach` |
| The VM rebooted | A VM reboot ends the tmux session. Run `attach` with `--restart-agent` |

## `wt` commands

Use `bash bin/wt help` for the grouped option reference. This table summarizes the commands:

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
| `wt update [--refresh-config] [--opinionated-config] [--with-*]` | Pull this repo with `git pull --ff-only`, then re-run `install.sh`. Portable hosts accept only `--refresh-config` and `--with-tmux-conf`. |
| `wt repos [<name>] [--porcelain\|--table]` | List every repo (name, task count, location on a terminal; `name<TAB>path` when piped), or print one repo's path |
| `wt doctor [--record DIR]` | Check cmux contracts and hook paths. Save redacted fixtures below `DIR/cmux-<version>/` |
| `wt -H <vm> doctor` | Check VM tools, cmux-tui hooks, folders, and the protocol against the Mac |
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

### VM command results

The Mac sets `WT_MACHINE` to the highest record version it accepts, currently `1`.
This applies to VM task creation, task recovery, path lookup for opening VS Code, and the Mac hook's worktree absence check.
The VM keeps its human-readable output and adds one line beginning with `WT_RESULT`
and a tab, followed by a compact JSON object.
The VM consumes the request at startup so setup hooks and nested commands keep their ordinary output.
See [Result records and versions](docs/vm-protocol.md#result-records-and-versions) for the record fields.

The record goes to standard output, except that a missing `path` record goes to
standard error with exit status `1`.
The VM emits the lower of the requested version and its own version.
Protocol 1 VMs accept every positive integer request and emit version 1.
Readers require exactly one record with a supported version, the expected command, and string fields.
Readers keep unknown scalar keys. New fields are additive.
Task recovery requires the `agent`, `attached`, and `started` boolean facts.
Successful path lookups for opening VS Code require a nonempty recorded `path`.
The shared result reader removes record lines before displaying VM output.
A new version number means that a field changed its meaning.
An unsupported result version stops creation or recovery and names `wt update` on the Mac.
The object must have unique keys and scalar values, except for the doctor result's structured `checks` array.
Keys and string values must not contain control characters.
A missing record or required field stops the operation and names `wt -H <host> update`.
An invalid record causes creation or recovery to stop and keeps the row during a close check.

`wt version` and `wt -H <vm> version` print JSON with `commit`, `protocol`, and `capabilities` fields.
The commit is the short repository commit, or `unknown` for a seeded copy without `.git`.
Host probes and creation preflight checks call the VM's `wt version`.
`wt hosts --json` includes the VM's `wt_commit`, `wt_protocol`, and `wt_capabilities`.
Invalid or unavailable reports produce null version fields and an empty capability array.

Updates print JSON records before and after the pull, alongside their existing output.
Each record has `event: "wt_update"`, `stage`, `side`, `commit`, and `protocol`.
Local updates use side `local`; remote updates report sides `Mac` and `VM`.
Stages are `before` and `after`. An invalid initial VM version report stops the update.
A failed update can stop before the `after` records.
A failed final version query reports null VM values and preserves the successful update status.
See [the JSON contracts](docs/wt-json.md) for details.

The close check also requires exit status `1`, status `missing`, and the requested task and repository.
A failed worktree listing cannot produce a missing record.

The environment request avoids an unsupported flag and requires no creation retry.
Supported VMs must provide result records when requested.
Older Macs that send `WT_MACHINE=1` continue to receive protocol 1 records.
Macs that send no request continue to receive ordinary output.
An ordinary `wt path` therefore still prints only its path.

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

If Codex runs in a sandbox, the agent runs the teardown command with escalation.
Changing directories does not give the command access to the cmux or tmux sockets.
`wt rm` refuses sandboxed removal before it deletes the worktree, so the agent can retry with escalation.

Before removal, `wt rm` checks the target row for a running agent.
It permits the caller's own row and refuses another agent's row, even with `wt rm --force`.
If cmux cannot report the row's agent status, `wt rm` keeps the worktree.
For its own row, `wt rm` passes cmux's `--force` to skip the running-process confirmation.
That cmux flag does not waive Git safety checks.
If a row close fails after removal, `wt rm` reports the error and the cmux command to close that row.

You can edit or clear a row's second line in cmux, and then the target row is not found by its repo.
So `wt rm` also checks two other kinds of rows for a running agent:
- each row with the task's title whose second line has a form that `wt` never writes;
- each local row whose current directory is in the worktree.

It refuses when another agent runs in any of them. It closes none of them, except the caller's own row with the task's title.

Claude's automatic approval review can reject self-removal before the command reaches cmux.
In that case, the agent reports the rejection and leaves the task intact.

`wt rm` still refuses if its command runs inside the worktree that it removes. When the agent closes its own
row, the agent session ends.

On a VM, these rules apply to a task that runs in its own tmux session:

- `wt rm` refuses another running agent's tmux session, even with `wt rm --force`.
- If `wt rm` cannot read that session's agent status, it keeps the worktree.
- Native cmux rows replace their shell with the task's tmux client.
  After removal, stopping that tmux session ends the terminal and closes its Mac row.
- If `wt rm` reports that a native row predates this change, it keeps the worktree and prints an attach command.
  Close that row on the Mac, run the attach command, then retry self-removal.
- A native row with a complete relay identity but no cleanup marker requests `wt-close` from the Mac hook.
  The hook closes the row before stopping tmux, so the row cannot recreate the session.
  If cleanup does not finish, `wt rm` prints the manual cleanup commands.
- A refusal leaves both the row and the tmux session open.

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

Use `--json` for scripts. See the [JSON status contract](docs/wt-json.md) for fields, types, and errors.

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

This table lists configuration variables, test overrides, and repository settings.

| Knob | Default and behavior |
|---|---|
| `WT_REPOS_DIR` | Colon-separated repository folders. The default is `~/Documents/Repositories`; the VM installer records `$HOME`. |
| `WT_HOST` | No default. The VM's alias in the Mac's `~/.ssh/config`; the VM installer records it. |
| `WT_AGENT` | `claude`. Selects the default agent for new tasks. |
| `WT_AGENT_ARGS` | Empty. Adds shell-split agent arguments. |
| `WT_MACHINE` | Unset. The highest accepted record version enables versioned results for supported commands. The Mac sets it for VM requests. |
| `WG_POLL_INTERVAL` | `1` second. Passes directly to `sleep` for poll waits. Tests can set `0`; invalid values produce a sleep error. |
| `WG_HOST_PROBE_TIMEOUT` | `20` seconds. Limits the Mac's SSH host probe. Accepts decimal integers from 1 through 922337203685477580, without leading zeros. Invalid values return 1; timeouts return 124. |
| `WG_DEBUG` | Unset. `1` adds tracebacks for unexpected errors in `portable.py`, including calls through `install.sh`. Set it in the host process environment. `wt -H <host> setup` does not forward the Mac's value. Expected refusals keep their usual output. |
| `WT_CLOSE_WAIT_SECONDS` | `22`. Sets the wait for older VM rows to close during self-removal. |
| `WT_STATUS_LEASE_SECONDS` | Retired with the TCP status paths. Current code ignores it. |
| `AGENT_NOTIFY_MIN_SECONDS` | `180`. Suppresses completion banners for shorter turns outside cmux. |
| `INSTALL_BASH` | `bash` on `PATH`. Selects the interpreter for `install.sh` in `test/install-smoke.sh`. |
| `FORCE_OS` | The result of `uname -s`. Overrides the installer platform for tests. |
| `GUARD_BASH` | `bash` on `PATH`. Selects the guard interpreter in `test/github-guard-smoke.sh`. |
| `WT_BASH` | `bash` on `PATH`. Selects the `wt` interpreter in `test/wt-smoke.sh`. |
| `JOBS` | `4`. Limits concurrent workers in `test/run.sh`. |
| `ONLY` | Unset. Filters smoke scenarios by shell pattern. The runner requires one selected suite. |
| `KEEP` | Unset. A nonempty value preserves test fixtures and runner logs. Failures also preserve them. |
| `wt.dir` | `.worktrees`. Git config key that sets a repository's worktree folder. |
| `.wt-include` | Absent. Lists gitignore-style patterns of ignored files to copy into new worktrees. |
| `.wt-setup` | Absent. An executable repository hook that runs inside each new worktree. |
| `~/.zshenv.local` | Optional machine-local shell overrides. `~/.zshenv` sources it; the VM installer adds missing host and repository settings. |

The variables below are internal. Workgrove writes them; do not set them as user configuration.
`test/docs_check.py` checks reads in `bin/` and `lib/` against the table and this explicit list.

<!-- Internal variables begin. -->
- `WT_REMOTE_ROOT` holds the portable root. `portable.py` writes it to the profile's `env.sh`; doctor and repository lookup read it.
- `WT_CLAUDE_ARGS_JSON` and `WT_CODEX_ARGS_JSON` hold JSON argument arrays from the portable profile. `portable.py` writes them to `env.sh`; `wt run` reads them.
- `WT_CMUX_TUI_HOOK` holds the original agent hook helper. `wt run` sets it from `CMUX_TUI_HOOK` or the cmux-tui data folder.
- `WT_CMUX_CLOSE_ON_EXIT` marks native task attachments in tmux. Self-removal reads it before closing the row.
- `WT_NAME` and `WT_REPO` identify the task and main checkout for `.wt-setup`.
- `WG_LIB_DIR`, `WG_VERSION_ROOT`, and `WG_PREFIX` identify the library, installation, and diagnostic prefix.
- `WG_COMMON_LOADED` and `WG_TASK_LOADED` prevent repeated module loading.
- `WG_EXIT_HANDLERS` and `WG_EXIT_PID` track process cleanup handlers.
- `WG_MACHINE_RESULT` holds the consumed `WT_MACHINE` request without exporting it.
- `WG_CMUX_SUPPORTED` records the verified cmux version.
- `WG_NEW_PREFLIGHT` selects repository checks for remote task creation.
- `WT_PROTOCOL` records the supported result protocol. `WT_FS` separates row fields.
- `WT_COMMANDS`, `WT_COMMAND`, `WT_REMOTE`, and `WT_SUMMARY` describe command dispatch.
- `WT_SPEC`, `WT_REMOTE_SPEC`, and `WT_HELP_COMMAND` select command options and help.
- `WT_DIRNAME` holds the repository's worktree folder from `wt.dir`.
- `WT_META`, `WT_META_FILE`, `WT_META_JSON`, and `WT_META_FILTER` hold cached sidecar data and its decoder.
- `WT_STATUS_FIELDS` and `WT_SHOW_FIELDS` define task status fields.
- `WT_BASE_FETCHES` caches base-fetch results. `WT_MERGE_TREE` caches merge support.
- `WT_TMPFILES` and `WT_TMPFILES_PID` track temporary files for each process.
- `WT_PR_FORM` holds the guard's approved `wt pr` diagnostic.
<!-- Internal variables end. -->

A model chosen with `wt new -m` persists for every `wt run` launch, including Claude resumes. It overrides
model options in `WT_AGENT_ARGS`. When the task has a model, `wt` also removes Claude's `--fallback-model`.
Without `-m`, those arguments still apply.

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
- Each session writes short, plain messages, leads with the result, and names what it did not check.

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
| `ssh-host` | "register this SSH fragment", "prepare this host for workgrove" |
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

### cmux compatibility log

See the [cmux compatibility log](docs/cmux-integration.md#cmux-compatibility-log) for verified versions, flows, and remaining checks.

### SSH row creation

`wt` and the Mac hook use `lib/workgrove/cmux.sh` to create SSH rows.
The adapter reads the JSON window list before it looks for an existing row.
If any window fails, it stops before creating a row.
If `cmux ssh` prints no row ref, the adapter waits one second and makes one lookup.

The second line identifies the row's host and repo.
If the adapter cannot write it on a new row, it closes that row and reports the failure.
If a description rewrite fails on an existing row, the caller reports the failure and keeps the row open.

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
  to other machines. Make cmux config changes in `cmux.json`.
  Make font, theme, and color changes in `home/.config/ghostty/config` or its themes.
  Run `cmux reload-config` to apply a change to either file.

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
- On a VM, it leaves lifecycle tracking to cmux-tui.
- Otherwise, on a Mac, it posts a desktop banner.

**Status from a VM task on cmux 0.65:**

- cmux-tui installs its own agent hooks on the VM. They report the agent's state to the row's terminal.
- The Mac shows that state in the row as Running, Idle, or Needs input.
- `wt run` points these hooks at `lib/workgrove/cmux-tui-hook.sh`.
  At each hook, that wrapper reads the row's terminal ID from the task's tmux session.
  Without it, the hooks report to the row that started the tmux server, or to the row from before a reattach.
- An Esc interruption on a native row was not tested.
- [Agent status in VM rows](docs/vm-agent-status.md) gives the cause, the check for
  the cmux-tui hooks, and the verification.

**Requests from VM tasks.** The same Mac hook handles the `wt-open` and `wt-attach` requests.
For `wt-open`, it opens the remote folder in VS Code. For `wt-attach`, it creates the row for the new VM task.

**Codex prompts.** Codex runs with `approvals_reviewer = "auto_review"`. With this setting, Codex approves
sandbox escalations automatically, so a Codex row rarely shows a needs-input state.
Expect that state only when Codex itself prompts you.

### Enable VM status on an existing VM

Do these steps to turn on VM status for an existing VM. Do them in this order.

1. Update workgrove on the Mac and VM.
2. On the VM, run `cmux-tui agent hook status claude codex`.
   If a provider shows `absent`, run `cmux-tui agent hook install claude codex`.
   Both providers must show `installed` before you continue.
   In Codex on the VM, review and trust the hooks with `/hooks`.
   A config refresh keeps existing foreign hooks, including cmux-tui's hooks.
   See [Agent status in VM rows](docs/vm-agent-status.md) for details.
3. Exit the agent in the task row.
4. Run `wt -H <vm> attach --restart-agent -r <repo> <name>`.

To check the result, give the agent a prompt. Make sure that the row's status shows Running,
and then Idle when the turn ends.

### VM rows

- VM rows run bash with cmux's shell integration, not zsh. For this reason, `install.sh` gives `~/.bashrc`
  a first line that sources `~/.zshenv`. For the usual prompt, type `zsh` inside the row's tmux.
- The VM paths are implemented and documented here as designed. But they are the newest part of this
  setup. The first time you use one, make sure that:
  - The row appears with `@<host> · <repo>` on its second line.
  - `wt -H <vm> show -r <repo> <name>` reports the tmux session.

## Keeping machines in sync

This section tells you how to apply each type of change on the Mac and then on each VM.
These rules apply:

- You edit on the Mac. VMs pull.
- `wt update` is `git pull --ff-only` plus `install.sh`. So it refuses to run over local edits,
  and classic installations keep the three machine-local copies. Portable updates merge hooks and preserve personal settings.
- A classic config refresh is always explicit and always backed up.
- Per-machine files stay out of this edit, commit, and pull cycle.

| Change | Mac | VM |
|---|---|---|
| Edit `AGENTS.md`, a skill, `wt` | Skills apply at once. `AGENTS.md` applies at the next session. Commit. | `wt -H <vm> update` |
| Change Claude or Codex settings, or the portable hooks | Edit the `.base` file. Then run `bash ~/repos/workgrove/install.sh --refresh-config && cmux hooks codex install --yes`. Review the portable hooks with Codex `/hooks`. Commit. | Run `wt -H <vm> update --refresh-config`. Portable hosts merge hooks and preserve existing settings and trust data. Classic VMs rewrite `~/.codex/config.toml` from the `.base` file and drop Codex's hook trust hashes and folder trust. The refresh keeps existing cmux-tui hooks. On the VM, run `cmux-tui agent hook status claude codex`. If a provider shows `absent`, run `cmux-tui agent hook install claude codex`. Re-trust the hooks in `/hooks`, then restart the agent with `wt -H <vm> attach --restart-agent -r <repo> <name>` from the Mac. Do **not** run the cmux installer (`cmux hooks codex install --yes`) on the VM. |
| Update cmux, or repair local Codex state tracking | Back up the live (machine-local) `config.toml` and `hooks.json`. Run `cmux hooks codex install --yes`. Check that one turn returns to `idle`. | n/a |
| Add a file (skill, script) | Edit, `bash install.sh`, commit. | `wt -H <vm> update` |
| Change `cmux.json` or the Ghostty config | The change applies after cmux reloads its config or relaunches (see Hotkeys and configuration). A Ghostty config change applies after `cmux reload-config`. Commit. | n/a |
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

[`bin/github-guard`](bin/github-guard) checks Bash commands through `PreToolUse` in Claude and Codex.
Claude runs it before the permission lists. Codex 0.164.0 supports its deny response before shell execution.
Codex requires hook review and trust through `/hooks` before this hook runs.
The setup instructions use the upstream Codex installer without a pinned version.
This support check applies to 0.164.0; other versions need their own verification.
The guard uses the same policy for both providers.
An array defines the approved API writes. The guard generates its API help and command pattern from the array and checker forms.

**Codex decisions.** `github-guard --codex` returns denials and exits with status 0.
For permitted commands, it returns no output and exits with status 0.
Codex then applies its own sandbox and approval controls.
This avoids an unsupported bare `allow` response in 0.164.0.
Claude still receives its existing `allow` and `deny` responses.
See the [Codex hooks reference](https://learn.chatgpt.com/docs/hooks) for the current interface.

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
  - It does not go to `main`, `master`, or that repository's default branch. To find the default branch, the guard asks GitHub.
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
actions to the provider's permission controls. Claude shows a prompt or uses its auto mode classifier.
Codex applies its own sandbox and approvals.

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
  to the provider's permission controls. Claude's lists no longer deny them.
  Outside auto mode, Claude prompts. In auto mode, Claude uses its classifier.
  Codex applies its own sandbox and approvals.
- **Warning:** On a machine whose `settings.json` still allows `Bash(git *)`, these commands run, including
  `npm test && git push --force origin main`.
- It does not check a thread resolution against the repository, because a thread id does not say which
  repository the thread belongs to.
- It reads `GH_REPO` and `GH_HOST` from the environment that the provider runs hooks with. So it would not
  see a value that is set only inside the Bash tool's own shell.
- On a machine with Git's `push.followTags=true`, an approved branch push can still send annotated tags with
  it. The guard does not inspect that setting.
- The default-branch check fails closed when `gh` cannot reach GitHub, even if Git credentials would permit
  a push. The denial suggests that you check `gh` authentication and network access. The guard does not
  make a second connection request.
- Codex reports shell tools, including nested code-mode `exec_command` calls, as `Bash` with `tool_input.command`.
  Later `write_stdin` input to an existing process receives no new `PreToolUse` check.
  The Bash matcher does not cover file tools, MCP tools, hosted tools, or specialized paths that skip hooks.
- Codex 0.164.0 omits `exec_command.workdir` from the hook input.
  The guard checks the hook's `cwd`, which can differ from the command's working directory.
- Disabled or untrusted hooks do not run. Codex hook errors, timeouts, and malformed responses can leave the command running.
  Missing dependencies or invalid input make this guard give no answer in either provider.
  The GitHub write restrictions still apply when the hook gives no answer or does not run.
- An agent can still write whatever the machine's `gh` login and Git credentials allow. The guard catches
  the ordinary spellings of a force push or of a push to the default branch. Branch protection on GitHub
  and a token scoped to the repositories that you work on are the controls that hold.

### The hooks run scripts from this repository on every turn

Three files connect events to scripts:

- `settings.base.json` connects six Claude events (`UserPromptSubmit`, `PermissionRequest`, `Notification`,
  `Stop`, `StopFailure`, `SessionEnd`) to `agent-notify`. It also connects `PreToolUse` on every Bash
  command to `github-guard`.
- `hooks.base.json` connects Codex's five lifecycle events to `agent-notify`.
  It also connects `PreToolUse` on Bash commands to `github-guard --codex`.
- `~/.cmuxterm/automations.json` connects `notification.created` events to `cmux-hook --event` through the `wt-native-relay` rule.

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
runs `wt run` there. Processes with access to the native relay's Unix socket can make these requests.
Trust each such host as much as you trust yourself. Prefer single-user machines for task rows.

**How a VM asks the Mac for work.** `wt` on a VM cannot open VS Code or make a row itself. It sends a
`wt-open` or `wt-attach` notification over the row's relay socket. Then the Mac hook, `bin/cmux-hook`, does
the work on the Mac.

**What the Mac hook checks.** The hook is strict about what it acts on. It requires these conditions:

| Check | Condition |
|---|---|
| `valid_host` | The host looks like a hostname. |
| `known_host` | The host is a literal `Host` entry, with no wildcard, in `~/.ssh/config`. |
| `from_row_on_host` | The notifying row is itself a `cmux ssh` row pointed at that same host. |
| `hook_safe_path` | A path is absolute, with no `..`, no `//`, no trailing slash and no shell metacharacters. |
| `valid_name` | A task name matches `^[a-z0-9][a-z0-9_-]{0,62}$`. |

**What the checks limit.** The limits are real, but narrower than they first seem:

- They limit the destination. Only a host that is already aliased in your own `~/.ssh/config` can be named
  at all. So nothing can send the Mac to a machine that you never configured.
- They limit the shape of a path and of a name, so neither can carry a shell command.
- They do not stop that host from asking the Mac for two things, because these requests are the purpose of
  the feature:
  - to open any path on that host in a VS Code remote window
  - to create a row that runs `wt run` there

**The check depends on the row list.** The handler gets the row ID from the native automation event.
It reads only the notification record with that event's notification ID and row ID.
It accepts only a row whose backend is `cmux-tui`.
The window scoping in "Rows are found by title, repo and host, in every window" (in [How it works](#how-it-works)) affected
this check. Before the fix:

- A hook has no caller surface. So the hook's row list answered only for the window that was current.
- When the user had moved a task row into another window, the hook could not show that the row belonged to
  the asking host. The check failed closed. The VM's `wt open` did nothing except write a line to
  `~/.local/state/cmux-hook.log`.

Now `cmux_rows_load` merges the row lists of every window. This widens what the check can see, not what it will
accept. The check still finds the row whose id is the sending row's workspace id, and compares that row's ssh
destination with the host.

**Within one host, the check is deliberately loose.** It asks only whether the notifying row is a remote row
whose destination is that host. It does not ask whether a task lives there, or whether you ever ran `wt` on
that host. So the rows that can send these requests include at least every `cmux ssh` row that you have
open to any aliased host. That can be a task VM, but equally a shared bastion, a customer's jump host or a
build box.

The path has no limit beyond the `hook_safe_path` shape check. It can be `/etc` or a home `.ssh` directory.

The native relay uses a Unix socket on the VM.
Treat processes that can access that socket as part of the Mac's trust boundary.

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

Codex's sandbox can block access to the native relay's Unix socket on the VM.
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

### The notification hooks use a home-relative path

The portable hooks call `~/.local/bin/agent-notify` directly, so they do not need `~/.local/bin` on `PATH`.
The hook shell expands `~` to the agent's home directory.
The helper still needs its dependencies, including `bash` and `jq`, on `PATH`.

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
