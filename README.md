# workstation

Dotfiles plus a small tool, `wt`, that runs many coding-agent tasks in parallel. Claude Code and Codex
each get their own git worktree and their own terminal row in [cmux](https://github.com/manaflow-ai/cmux),
on this Mac or on an Ubuntu VM, with VS Code opened only when you ask for it. `install.sh` puts the whole
thing into `$HOME` on a Mac or on a VM from one clone.

**The model:** one task = one worktree at `<repo>/.worktrees/<name>` on branch `wt/<name>` = one cmux row.
VS Code opens on demand, through `wt open`.

## How it works

- **Identity.** Every row a task owns is titled `<repo>:<name>`; its description line, the sidebar's second
  line, reads `@local` or `@<host>`, so you always know where a session runs. A task on a VM also has the
  tmux session `wt-<repo>-<name>`, which keeps the agent alive across disconnects: the row is a plain `cmux ssh`
  row, and the shell it opens creates that session (running the agent) or takes over the one already there.
  Other rows: `<repo> shell` for a repo shell, `shell` for a VM shell, `driver` for the driver session.
- **Git owns the worktree; sidecar files own the launch metadata.** `wt` reads `git worktree list`. Per task
  it keeps `<repo>/.git/wt/<name>.json` (base ref, agent, row title, tmux session, copied files),
  `<name>.prompt` (the brief, handed to the agent by `wt run`) and `<name>.started` (after which Claude
  resumes with `-c`). None of this is ever committed.
- **Per-repo hooks.** `.worktreeinclude` lists gitignore-style patterns of *ignored* files (`.env` and
  friends) to copy into each new worktree. `.wt-setup`, if executable, runs inside each new worktree.
- **Paths.** Task repos live in the folders `$WT_REPOS_DIR` lists, default `~/Documents/Repositories` on the
  Mac; on a VM `install.sh` records the home folder instead, so every git repo directly under the home folder
  then counts as a task repo, hidden folders such as `~/.oh-my-zsh` excluded. This repo lives at
  `~/repos/workstation` on every machine, so the same commands work everywhere.
- **Auth is yours.** The repo carries tools and config only. You log in once per machine with `gh auth login`,
  `az login`, `claude auth login`, and `codex login`; `claude auth status` must report `"loggedIn": true`.

## Layout

```
workstation/
├── README.md
├── LICENSE
├── install.sh                 links this repo into $HOME (Mac and Ubuntu)
├── Brewfile                   azure-cli fzf gh jq shellcheck; casks cmux, VS Code, git-credential-manager
├── .gitignore
├── bin/
│   ├── wt                     the task tool: worktrees, cmux rows, the picker, the driver, VMs
│   ├── agent-notify           agent lifecycle hook, relays to cmux or posts a banner
│   ├── cmux-hook              Mac-side cmux notification hook: remote wt open / wt attach
│   └── azml-ssh-host          Azure ML compute instance -> a Host block in ~/.ssh/config
├── home/
│   ├── .zshenv .gitignore_global   always installed; .zshrc .gitconfig .tmux.conf are opt-in
│   ├── .oh-my-zsh/custom/themes/workstation.zsh-theme   with the .zshrc opt-in
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
│   └── install-smoke.sh       the install smoke test: the default install, the flags, stickiness
└── docs/
    ├── new-mac.md             set up a Mac
    ├── new-vm.md              set up an Ubuntu VM
    ├── azml-compute.md        Azure ML compute instances over ssh
    └── ssh-config.example     the Host block a VM alias needs
```

## Install

**What it needs.** macOS with Homebrew, or Ubuntu 22.04 to 24.04. `git` and `jq` have to be on `PATH` before
you start: `install.sh` stops with a message naming `jq` when it is missing, and without `git` it cannot get
past its git-identity check. `bash` 3.2 is the floor — that is macOS's own `/bin/bash`, and the smoke test
passes under it — so nothing here needs a newer shell. On the VMs the tmux is 3.2a and `home/.tmux.conf` is
written for it. The cmux integration assumes cmux 0.64 or newer (`bin/cmux-hook` encodes 0.64's notification
behaviour) and `home/.config/cmux/cmux.json` is `schemaVersion: 1`. The rest — `gh`, `az`, `fzf`, cmux itself,
Claude Code, Codex — is installed by `Brewfile` on a Mac and by [docs/new-vm.md](docs/new-vm.md) on a VM.

```bash
mkdir -p ~/repos && git clone https://github.com/mal84emma/workstation ~/repos/workstation
bash ~/repos/workstation/install.sh
```

Full instructions: [docs/new-mac.md](docs/new-mac.md) and [docs/new-vm.md](docs/new-vm.md).

To see exactly what it would do to your machine without touching your own dotfiles, give it a throwaway home:
`HOME=$(mktemp -d) bash install.sh`. Every path it writes is `$HOME`-relative — that is what the smoke test
exercises — so the whole install lands in that directory and you can read it there.

To put a local change on a machine before committing it, seed it with the `rsync` line in the notes of
[docs/new-vm.md](docs/new-vm.md) instead of the clone. A seeded copy has no `.git`, so `wt update` refuses
until it is replaced by a clone.

That bare run installs the machinery and leaves your own shell, git and tmux alone. Five of the files here
are the author's taste rather than machinery, and so is one group of keys inside a file that is installed
either way, so each waits for its own flag: installing a task tool should not hand a stranger someone else's
prompt, git config, tmux bindings, Claude keymap, status line and Claude UI.

| Flag | Asks for | What arrives instead when you leave it out |
|---|---|---|
| `--with-zshrc` | `~/.zshrc`, and with it the oh-my-zsh theme, the oh-my-zsh prerequisite and the clone of the two plugins it enables | Nothing: your `~/.zshrc` is untouched, and a default install therefore has no oh-my-zsh prerequisite and no network step at all |
| `--with-gitconfig` | `~/.gitconfig`: `core.excludesFile`, the github.com credential helper, the `~/.gitconfig.local` include | Its two machinery settings only, written into your own `~/.gitconfig` with `git config --global`: `core.excludesFile` (what git-ignores `.worktrees/`) and the `~/.gitconfig.local` include (where your identity lives). Every other line of your file is left alone |
| `--with-tmux-conf` | `~/.tmux.conf`: the relay line, plus tuning that makes Claude in tmux feel like a bare terminal (true colour, a 10 ms `escape-time`, Shift+Enter, focus events) | Its one machinery line, appended to your own `~/.tmux.conf` (created if you have none), leaving every line already there in place: that `set -ag update-environment` is how cmux's relay variables reach a pane started in an already-running session |
| `--with-keybindings` | `~/.claude/keybindings.json` | Nothing; Claude keeps its own keymap |
| `--with-statusline` | `~/.claude/statusline-command.sh` | Nothing, and `statusLine` is stripped from the `~/.claude/settings.json` copy, because it names a script that would not be there |
| `--with-claude-ui` | No file of its own: the `tui`, `voice` and `theme` keys and `env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS`, kept in the `~/.claude/settings.json` copy | Those keys are deleted from the copy, so Claude keeps its own full-screen setting, voice mode, theme and mouse handling; the hooks and permissions in the same file arrive either way |

`--opinionated-config` is all six at once; `--refresh-config` is orthogonal to them, and they combine in any
order. The one deliberate exception to the fallbacks above is a `core.excludesFile` that already points at a
file of your own: that is kept, not overwritten, with a message asking you to add `.gitignore_global`'s lines
to it, because overwriting it would silently drop every global ignore you had — which is the harm this whole
opt-in is about.

The choice is sticky, with nothing stored anywhere to disagree with: a destination that is already a symlink
into this repo counts as opted in, so `wt update` — which re-runs `install.sh` with at most
`--refresh-config` — keeps what each machine chose. Opting in later means running `install.sh --with-…`
yourself once, after which `wt update` carries it. A run that leaves some out names them and the flag that
would install each.

`--with-claude-ui` is sticky too, by a different witness. What makes the other five sticky is the symlink
itself, and keys inside a copied file leave no such trace — but the copy is its own record: a
`~/.claude/settings.json` that already carries a top-level `tui` key was written by a run that was given the
flag, so a later `--refresh-config` keeps those keys instead of stripping them. Given on its own, on a machine
whose copy was written without it, it changes nothing and says so rather than reporting success.

`~/.zshenv` and `~/.gitignore_global` are not on that list, because they are the contract rather than taste:
`~/.zshenv` puts `~/.local/bin` on `PATH` and carries `WT_HOST` and `WT_REPOS_DIR`, and `~/.gitignore_global`
is the file that git-ignores `.worktrees/`.

`install.sh` sorts every file into one of three classes.

| Class | Files | Behaviour |
|---|---|---|
| Symlinks | `~/.zshenv`, `~/.gitignore_global`, `AGENTS.md`, `CLAUDE.md`, the skills, `bin/*`, `cmux.json` (Mac only), and every opt-in file you asked for | Edits, including an agent's, land in the repo, so `git diff` is the review |
| Machine-local copies | `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.codex/hooks.json` | Created from the versioned `.base` files, minus the keys this machine cannot use or did not ask for: the voice keys and the Keychain credential store off a Mac, `statusLine` without `--with-statusline`, and `tui`, `voice`, `theme` and `env.CLAUDE_CODE_DISABLE_MOUSE_CLICKS` without `--with-claude-ui`. The apps write local state into them, so a normal run keeps what is there and only `install.sh --refresh-config` replaces them |
| Never touched | `~/.gitconfig.local`, `~/.zshrc.local`, `~/.zshenv.local` (which on a VM gains the `WT_HOST` and `WT_REPOS_DIR` lines when they are absent), and the real directories the apps write into | Your machine-local overrides, sourced or included by the linked files — `~/.zshrc.local` only when `~/.zshrc` is one of them |

It is idempotent: rerun it after every repo change. Nothing is deleted. Anything in the way is moved into
`~/.workstation-backup/<timestamp>-<pid>`, which is created only when it is actually needed. It stops with a
message if no git identity is set — `~/.gitconfig.local` first, then your global git config — or, when
`~/.zshrc` is opted in, if oh-my-zsh is missing. On Linux it records this VM's alias in the Mac's
`~/.ssh/config` as a `WT_HOST` line in `~/.zshenv.local`: given in the environment
(`WT_HOST=<vm> bash install.sh`, which is what the setup page does) or asked for once at a prompt. It records
`export WT_REPOS_DIR="$HOME"` there too, and puts one line at the top of `~/.bashrc` so that bash reads
`~/.zshenv`, because cmux runs its VM rows in bash. At the top because Ubuntu's `~/.bashrc` returns early in a
non-interactive shell, so the line has to come first to cover `ssh <vm> '<cmd>'` and `wt -H <vm> …` as well.

`bash test/install-smoke.sh` is the repo's smoke test: 496 assertions across sixteen scenario groups
(thirty-nine runs, since most groups have several cases and one loops over five flags), each run against its
own throwaway `$HOME` with no network. They cover the default no-flags install — into an empty home and over a
stranger's own dotfiles — `--opinionated-config`, each file flag on its own, the stickiness rules, idempotence,
an unknown flag, every refusal path, which links count as this repo's own, the don't-clobber branches of
`configure_git`, retirement of renamed links, and `ZSH_CUSTOM`. Set `INSTALL_BASH=/bin/bash` to run
`install.sh` itself under bash 3.2, which is what a fresh Mac gives it; `FORCE_OS=Linux` drives the
Linux-only steps from a Mac.

**There is no uninstaller.** Undoing an install is manual, and the backup directory is what makes it possible.
Delete the symlinks this repo made — `~/.zshenv`, `~/.gitignore_global`, `~/.claude/AGENTS.md`,
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, the skills under `~/.agents/skills/` and `~/.claude/skills/`, the
`~/.local/bin/` entries, `~/.config/cmux/cmux.json`, and whichever opt-in files you asked for (each one points
into `~/repos/workstation`, so `ls -l` tells you which are ours). Delete the three machine-local copies
(`~/.claude/settings.json`, `~/.codex/config.toml`, `~/.codex/hooks.json`) if you do not want them. Then copy
your originals back out of the newest `~/.workstation-backup/<timestamp>-<pid>/`, which mirrors `$HOME`.
Two things `install.sh` edits in place rather than replacing are not in the backup and have to be undone by
hand: the lines it appended to `~/.zshenv.local` and the `~/.zshenv` line at the top of `~/.bashrc` on a VM,
and, on a default run, the `set -ag update-environment` line appended to your own `~/.tmux.conf` and the
`core.excludesFile` and `~/.gitconfig.local` include added with `git config --global`.

## Daily use

| You want | Do |
|---|---|
| Start a task locally | Type the brief in the cmux TextBox and press ⏎ (runs `wt new -p <brief>`). The second submit action runs Claude in the current checkout instead |
| Start a task from a terminal | `wt new fix-auth -a codex -p "…"`, or ⌃⌥⌘N to type `wt new` into the current terminal |
| Start a task anywhere | ⌃⌥⌘T opens the picker (`wt task`): where, then kind, then repo, then name, then brief |
| Ask the driver | ⌃⌥⌘D opens the `driver` row: "start a task on `<vm>` in repo X to …". It runs `wt -H <vm> new -r X …` and reports the row |
| See tasks | `wt list [--all]`, `wt show <name>`, `wt -H <vm> list` |
| Look at the code | Say "show me the worktree code" (the agent runs `wt open`), or run `wt open <name>` / `wt -H <vm> open -r <repo> <name>`. This works from VM sessions too |
| Shell on a VM | ⌃⌥⌘T → `<vm>` → `vm-shell` (row `shell`, second line `@<vm>`). A host you type that is not a configured alias is tried as-is; requests from inside that VM need a real `Host` entry |
| Shell in a repo | ⌃⌥⌘T → where → `repo-shell` → repo (row `<repo> shell`) |
| Re-open a VM task's row | `wt -H <vm> attach -r <repo> <name>`. It re-attaches a live agent, including one whose row lost its pty in a cmux relaunch and now shows a bare shell; when no agent is running in the session (it exited, or a VM restart took the session) it refuses and prints the `--restart-agent` line, which resumes Claude with `-c`. If the row shows a bare shell but plain attach only selects it, add `--reattach` (see the row below) |
| Reconnect after sleep or Wi-Fi loss | Often nothing: the row reconnects by itself and the agent kept running in tmux. When the outage outlasts cmux's retries the row goes quiet and its sidebar says the automatic reconnect is paused; press **Reconnect** there, once per row, which reliably comes back attached to tmux with the relay intact. Sometimes cmux reports `remote session was lost; starting a new shell` and the row comes back as a bare shell while the VM still holds the pty, and therefore still lists the old tmux client, so plain attach cannot tell the session is orphaned: `wt -H <vm> attach -r <repo> <name> --reattach` sends the tmux line to that row and rebinds the session to the row's current relay socket. A lost remote pty (a cmux relaunch) needs plain `wt -H <vm> attach -r <repo> <name>`; a VM reboot takes the tmux session with it, so that one needs `--restart-agent` |
| Hand back | Report the branch. `wt pr <name>` only when you ask for it |
| Clean up | `wt rm <name>`, `wt -H <vm> rm -r <repo> <name>`, `wt prune` |
| Update a machine | `wt update`, `wt -H <vm> update`; add `--refresh-config` only after reviewing a `.base` change |
| Add an Azure ML compute instance | `azml-ssh-host add <instance>`, or say "add compute instance X to my ssh config"; then it is a VM like any other ([docs/azml-compute.md](docs/azml-compute.md)) |

The name the picker asks for may be blank, in which case it comes from the brief (both blank: `task-<timestamp>`). A blank brief is fine too:
the agent starts idle. Names are lower-cased and spaces become dashes, so "Fix Auth" becomes `fix-auth`;
anything that is not `^[a-z0-9][a-z0-9_-]{0,62}$` after that is refused, and `.` is never allowed.

## `wt` commands

`bash bin/wt help` is the reference, including every flag. The shape of it:

| Command | Does |
|---|---|
| `wt new [name] [-p TEXT] [-a claude\|codex\|none] [-r PATH] [-b REF]` | Create the worktree and a cmux row running the agent with the brief |
| `wt run <name>` | Run that worktree's agent with its brief. cmux runs this for you |
| `wt list [--all] [--json]` | Worktrees, with branch, base, ahead/behind, dirty count, last commit |
| `wt show <name> [--diff] [--json]` | Path, branch, row, brief, dirty files, commits and diffstat vs base; on a VM also the tmux session and whether its agent is running |
| `wt open [name]` | Open the worktree in VS Code. No name means the one you are in |
| `wt attach <name>` | Open a cmux row for a worktree that already exists |
| `wt sync <name> [--merge]` | Rebase (or merge) the branch onto its base |
| `wt pr <name> [--draft]` | Push the branch and open a GitHub pull request |
| `wt rm <name> [--force] [--keep-branch]` | Remove a worktree; see below |
| `wt prune [--dry-run]` | Remove worktrees whose branch is merged and whose tree is clean |
| `wt task` | The picker on ⌃⌥⌘T (Mac, needs fzf) |
| `wt driver` | Open or select the `driver` row |
| `wt update [--refresh-config]` | `git pull --ff-only` this repo, then re-run `install.sh` |
| `wt repos [<name>] [--porcelain\|--table]` | List every repo (name, task count, location on a terminal; `name<TAB>path` when piped), or print one repo's path |
| `wt path <name>`, `wt current`, `wt diff <name>`, `wt help` | Small helpers |
| `wt -H <host> <sub> …` | Run a subcommand on a VM over ssh while the cmux row stays local. `show`, `rm`, `path`, `open` and `attach` need `-r <repo>` |

`wt rm` refuses, with exit status 3, to destroy work: uncommitted changes, commits that are neither merged
into the base nor pushed, a file copied in through `.worktreeinclude` that no longer matches its source
in the main checkout, or a base ref it cannot compare the worktree against — deleted since, or a sidecar from
an older `wt` holding the literal `HEAD`, which resolves to the worktree's own tip and would make every other
count read as nothing to lose. It names what blocked it. `--force` overrides. `wt prune` is stricter still:
it only removes worktrees whose branch is merged and whose tree is clean.

Useful environment variables: `WT_REPOS_DIR` (the folders repos are looked for in), `WT_AGENT` (default
agent), `WT_AGENT_ARGS` (extra agent arguments), and `WT_HOST` on a VM. `git config wt.dir` renames the
worktree folder for one repo.

`WT_REPOS_DIR` may hold several folders separated by `:`, like `$PATH`, searched in the order given; empty
entries and folders that are missing or unreadable are skipped, and a folder named twice is searched once.
`wt repos` and `wt list --all` cover every folder in the list; only direct children holding a `.git` count,
and hidden folders such as `~/.oh-my-zsh` never do. On a terminal `wt repos` prints a table: the repo name,
how many task worktrees it holds (`-` for none) and where it lives, `~/…` for this home; the ⌃⌥⌘T picker
shows the same name and location columns. Piped, or with `--porcelain`, it prints `name<TAB>path` per repo, the form scripts and
the picker read; `--table` forces the table, which is what `wt -H <vm> repos` sends to a VM. A name is looked up along the list; a name found in more
than one folder is refused with both paths, so pass the path instead. Set it in
`~/.zshenv.local`, for example `export WT_REPOS_DIR="$HOME/work/repos:$HOME/Documents/Repositories"`.

## Agents

[`home/.claude/AGENTS.md`](home/.claude/AGENTS.md) is linked to `~/.claude/AGENTS.md` and `~/.codex/AGENTS.md`,
so Claude and Codex read the same conventions: task work happens in a worktree made with `wt new`, a session
inside `.worktrees/<name>` stays there and commits on `wt/<name>`, and each session reports its row and branch.
It also says plainly that this is a convention and not a sandbox.

The six skills in `home/.agents/skills/` are linked into both `~/.agents/skills/` (Codex) and
`~/.claude/skills/` (Claude), and reload live:

| Skill | Triggered by |
|---|---|
| `worktree-create` | "start a task", "work on this in parallel", "try an approach without touching main" |
| `worktree-work` | Being inside a `.worktrees/` directory; "rebase it", "hand it back" |
| `worktree-show` | "show me the code", "open the worktree", "let me see it" → `wt open`; "what changed", "how far is it" → `wt list` / `wt show` |
| `worktree-teardown` | "remove the worktree", "clean up finished tasks" |
| `task-driver` | "start a task on `<vm>`", "queue these three", "check on the tasks" |
| `azml-compute` | "add compute instance X to my ssh config", "which compute instances can I ssh to" |

What agents never do on their own: `git push`, `wt pr`, `gh pr create`, create a remote repository, publish,
remove a worktree you did not ask them to remove, pass `--force`, open VS Code unasked, or run the
interactive `wt attach`, `wt task` and `wt driver`, which belong to your own session.

## cmux notes

- The hotkeys are all on ⌃⌥⌘: **N** types `wt new` into the current terminal, **T** opens the task picker,
  **D** opens the driver row.
- Shortcuts on a `type: "workspace"` action (T and D) bind at app launch, so after editing them you must quit
  and relaunch cmux. A `type: "command"` action (N) is picked up by `cmux reload-config`.
- Built-in cmux shortcuts silently win over config actions. `cmux.json` therefore unbinds
  `toggleBrowserDesignMode` to free ⌃⌥⌘D.
- The Settings UI never writes `cmux.json`: its toggles go to macOS defaults and terminal appearance to
  `config.ghostty`. Those changes are not portable through this repo, so make config changes in the file.
- **Notifications.** On the Mac, cmux tracks Claude rows itself, and `cmux hooks codex install --yes` merges
  its generated Codex lifecycle handlers into `~/.codex/hooks.json` so a Codex row goes from `running` to
  `idle` when a turn ends. The portable hooks in `settings.base.json` and `hooks.base.json` call
  `bin/agent-notify`, which is a no-op inside a local cmux pane, relays over the cmux socket from a VM pane so
  the right row lights up on the Mac, and otherwise posts a desktop banner on a Mac. `bin/cmux-hook` is the Mac side of
  that relay: it runs for every cmux notification, ignores everything except a relayed `wt-open` or
  `wt-attach`, and then opens the remote folder in VS Code or creates the row for the new VM task.
- Codex runs with `approvals_reviewer = "auto_review"`, so sandbox escalations are approved automatically and
  a Codex row rarely shows a needs-input state. Expect it only when Codex really does prompt.
- VM rows are bash with cmux's shell integration, not zsh, which is why `install.sh` gives `~/.bashrc` a first
  line sourcing `~/.zshenv`; type `zsh` inside the row's tmux for the usual prompt.
- The VM paths are implemented and documented here as designed, but they are the newest part of this
  setup. The first time you use one, check that the row appears with its `@<host>` line and that
  `wt -H <vm> show -r <repo> <name>` reports the tmux session.

## Keeping machines in sync

The Mac is where you edit; VMs pull. `wt update` is `git pull --ff-only` plus `install.sh`, so it refuses
over local edits and never touches the three machine-local copies. A config refresh is always explicit and
always backed up. Per-machine files never enter the loop.

| Change | Mac | VM |
|---|---|---|
| Edit `AGENTS.md`, a skill, `wt` | Skills apply live, `AGENTS.md` at the next session; commit | `wt -H <vm> update` |
| Change Claude or Codex settings, or the portable hooks | Edit the `.base` file, then `bash ~/repos/workstation/install.sh --refresh-config && cmux hooks codex install --yes`; review the portable handlers with Codex `/hooks`; commit | `wt -H <vm> update --refresh-config`; the refresh rewrites `~/.codex/config.toml` from the `.base` file and drops Codex's hook trust hashes and folder trust, so re-trust in `/hooks` on the VM afterwards; do **not** run the cmux installer there |
| Update cmux, or repair local Codex state tracking | Back up the live `config.toml` and `hooks.json`, run `cmux hooks codex install --yes`, check that one turn returns to `idle` | n/a |
| Add a file (skill, script) | Edit, `bash install.sh`, commit | `wt -H <vm> update` |
| Change `cmux.json` | Live once cmux reloads or relaunches; commit | n/a |
| Repos in another folder | add the folder to `WT_REPOS_DIR` in `~/.zshenv.local` | edit the `WT_REPOS_DIR` line `install.sh` wrote in `~/.zshenv.local`; never versioned |
| New tool | `Brewfile` plus `brew bundle`; commit | Add the line to [docs/new-vm.md](docs/new-vm.md) and run it by hand on existing VMs |
| Promote a machine-local setting | Diff the live file against its `.base`, port only the portable keys, commit | Never commit live files or trust state |

A rewritten config reaches a **new process**, not a running one. A session that was open when the installer
ran keeps the settings it started with, so after a refresh exit and resume the ones you care about — `claude -c`
re-reads the config and keeps the conversation — rather than starting them over. The same rule one layer down is
why a tmux pane that predates an `install.sh` run needs `exec bash` before it sees the new environment.

`wt update` needs a real clone: a VM seeded with `rsync` refuses it until the seed is replaced by a clone.
Update the Mac's `wt` and each VM's `wt` together (`wt update` here, `wt -H <vm> update` there, or the rsync
seed for an uncommitted change): `wt -H <vm> …` runs the VM's copy for the remote half of every command, so a
VM left behind answers in a vocabulary this Mac no longer expects.

## Security

All of this runs as you, with your keys and your logins, and a good deal of it exists to remove prompts. That
is the point of it, but five of the choices behind it are worth knowing before you run `install.sh` on your
own machine.

- **The Claude permission list auto-approves, and denies.** The sixteen `permissions.allow` entries in
  [`home/.claude/settings.base.json`](home/.claude/settings.base.json) — `ls`, `cd`, the read-only git
  subcommands (`status`, `diff`, `log`, `show`, and the six read-only spellings of `branch`), `git add`,
  `git commit`, `wt list` and `wt show` — run with no prompt at all, so an agent commits to its branch
  without asking you. Thirteen
  `deny` entries cover `git -c`, `git config`, `git push` in its plain and its `git -C` spelling,
  `git remote add`, `git filter-branch`, `gh api`,
  `gh pr create`, `gh repo create`, `gh repo fork`, `gh release create` and `wt pr`; most of them are things
  the Agents section says agents never do on their own. Each list is spelled out form by form for the same
  reason: the broader `Bash(git *)` the allowlist replaced also matched `git -c alias.x='!<shell>' x`, which
  runs arbitrary shell with no prompt, and `Bash(git branch *)` covered `git branch -D` as readily as
  `git branch -v`. There is no allow entry for `git -C <path>` at all, and that is deliberate. Nine were
  tried — `git -C * status`, `diff`, `log`, `show`, `branch` — on the reasoning that running a read-only git
  in another worktree is harmless, and taken out again for two independent reasons. They never fired: rules
  are matched case-insensitively, so the `git -c *` deny below also catches `git -C`, and deny beats allow.
  And they could not have been made safe, because `*` matches any text, not just a path: `git -C <repo> -c
  diff.external=<script> diff` matches `Bash(git -C * diff)` and runs the script. That is the shape Claude
  Code's own settings validator warns about — a wildcard before the subcommand also approves options
  inserted at that position — and `git -C` always has one, since the path must precede the subcommand. To
  read another worktree, agents are told to use `cd <path> && git <subcommand>`, where the wildcard falls
  after the subcommand and the compound splitter checks both halves.

  Two things about how the lists are read are worth keeping in mind. Deny beats allow whenever both match,
  and rule specificity does not change that; and a compound command is split on `&&`, `||`, `;`, `|`, `&` and
  newlines, with a deny applying if it matches any subcommand, including one nested in a subshell or a
  command substitution. What the lists are not is enforcement. They match the text of the command Claude
  writes, and the permissions documentation says in as many words that this "isn't a security boundary around
  the program", warning that "Bash permission patterns that try to constrain command arguments are fragile".
  `Bash(git push *)` does not stop `/usr/bin/git push`, `bash -c 'git push'`, `git 'push' origin main` or
  `git -c core.fsmonitor=<script> -C <path> push`. So read these lists as intent made legible where the tool
  can act on it: they catch the ordinary spellings an agent actually writes, and they save you a prompt on
  the ones you would always approve. Anything that has to actually hold wants what those docs
  point at instead: a sandbox, or a `PreToolUse` hook that inspects the command itself. For a concrete
  example of why the allowlist is intent rather than a boundary, three of the entries it calls read-only are
  not: `Bash(git diff *)`, `Bash(git log *)` and `Bash(git show *)` all accept `--output=<file>`, so any of
  them will write to any path you can write, with no prompt.

- **The hooks run scripts from this repo on every turn.** `settings.base.json` wires five Claude events
  (`UserPromptSubmit`, `PermissionRequest`, `Notification`, `Stop`, `SessionEnd`) to `agent-notify`, and
  `cmux.json` hands cmux `~/.local/bin/cmux-hook` as a notification hook. Both are symlinks into this repo's
  `bin/`, and both run as you. So `wt update` is a code-execution event rather than a data update: pulling
  changes the scripts that then run by themselves, with nothing to restart. That is why `wt update` prints
  the incoming commits and a diffstat and asks before it fast-forwards and re-runs `install.sh`, and why it
  refuses to apply them at all when stdin is not a terminal. Read that diff the way you would read any other
  pull that lands on your `PATH`.

- **Every host you open a cmux `ssh` row to sits inside this Mac's trust boundary.** `wt` on a VM cannot open
  VS Code or make a row itself; it sends a `wt-open` or `wt-attach` notification over the row's relay socket,
  and `bin/cmux-hook` does the work on the Mac. The hook is picky about what it will act on: the host has to
  look like a hostname (`valid_host`) and be a literal, wildcard-free `Host` entry in `~/.ssh/config`
  (`known_host`); the notifying row must itself be a cmux SSH row pointed at that same host
  (`from_row_on_host`); a path must be absolute with no `..`, no `//`, no trailing slash and no shell
  metacharacters (`safe_path`); and a task name must match `^[a-z0-9][a-z0-9_-]{0,62}$`. Those checks stop
  one host from naming a different one, and stop shell being smuggled through a path or a name. What they do
  not stop — because it is the feature — is that host asking the Mac to open any path on it in a VS Code
  remote window, or to create a row that runs `wt run` there. And `from_row_on_host` asks only whether the
  notifying row is a remote row whose destination is that host: not whether a task lives there, not whether
  you ever ran `wt` on it. So the set that can ask is every `cmux ssh` row you have open to any aliased host:
  a task VM, but equally a shared bastion, a customer's jump host, a build box. The path is unconstrained
  beyond that shape check, `/etc` and a home `.ssh` directory included. The relay socket is loopback TCP on
  the far side, so anyone with an account on such a machine can ask for both: treat any host you keep a row
  to as trusted the way you are, and prefer single-user machines for task rows.

- **Codex approves its own escalations.** [`home/.codex/config.base.toml`](home/.codex/config.base.toml)
  sets `approval_policy = "on-request"` with `approvals_reviewer = "auto_review"`, so when Codex asks to
  cross the sandbox boundary the request is reviewed by a model rather than by you and can be approved in
  seconds with no human prompt. The sandbox boundary is a speed bump, not a consent gate — which is also why
  a Codex row rarely shows a needs-input state. Set `approvals_reviewer = "user"` in that file (then
  `install.sh --refresh-config`) to be asked yourself.

- **Two smaller ones.** `wt new` runs the repo's `.wt-setup`, when it is executable, inside the new worktree,
  so starting a task in a repo you have not read is running that repo's script as you. And `azml-ssh-host`
  makes its one verification login with `StrictHostKeyChecking=accept-new`, which records the first host key
  a new instance offers without asking: Azure ML instances are created and destroyed often enough that
  confirming a key for each one would be most of what you did with the tool, but it is trust on first use,
  and whoever can intercept that very first connection can present their own key instead. Only that
  verification relaxes the check — the `Host` block the tool writes does not carry it, so later connections
  use your normal ssh settings and a key that changes underneath you still stops the connection.

## Known limitations

- **Switching to a VM row is slower than a local one.** A `cmux ssh` row takes roughly 1 to 3 seconds to paint
  when you select it, against about a quarter of a second for a local row, and about 7 seconds to create. The
  connection, the network and the agent are not at fault: the row's screen is already on the Mac and reads back
  instantly while the row is hidden, so the cost is in cmux's own remote-surface path. Reported upstream as
  [manaflow-ai/cmux#13648](https://github.com/manaflow-ai/cmux/issues/13648). Accepted as tolerable for now.
  If it ever stops being tolerable, the alternative is to build VM rows as plain local terminals running
  `ssh -t <host> tmux …` with the cmux socket forwarded back for notifications, which paints as fast as any
  local row but gives up cmux's SSH badge, managed reconnect and relay.

- **A Codex session on a VM cannot reach the Mac by itself.** Codex runs the commands it issues in a sandbox
  that refuses to create sockets, and the cmux relay a VM row uses is a loopback TCP socket, so `wt open` and
  `wt new` inside a Codex row on a VM cannot ask the Mac to open VS Code or a new row. `wt` detects the failed
  relay and prints the command to run on the Mac instead, for example
  `wt -H <host> open -r <repo> <task>`; run that in any Mac shell for `open`, and in a cmux terminal for
  `new` or `attach`, which need the cmux socket. Claude sessions on a VM are unaffected, and so are Codex's own
  notifications, because Codex spawns its lifecycle hooks outside that sandbox. Allowing network access in
  `[sandbox_workspace_write]` is not the fix: it would open outbound network for every command Codex runs on
  the VM, and it does not lift the loopback restriction.

- **The notification hooks find `agent-notify` on `PATH`.** The portable hooks in
  `home/.claude/settings.base.json` and `home/.codex/hooks.base.json` call it by bare name, and `~/.zshenv` puts
  `~/.local/bin` on `PATH` for every zsh, so anything started from a shell finds it. An agent launched by
  something that bypasses the login shell would not, and the hook then fails silently rather than reporting a
  missing command. If that ever happens, the fix is the absolute path `~/.local/bin/agent-notify`, which is how
  `cmux.json` already invokes `cmux-hook`.

## Deliberately left out

- **Tailscale.** Optional hardening; this works over the ssh you already have.
- **mosh.** Not installed at either end, and cmux's `mosh-tmux` profile connects only one row per host. A VM
  task row is a plain `cmux ssh` row whose shell creates or attaches the task's tmux session instead.
- **Agent-native worktree features** (`claude --worktree`, `codex --worktree`, worktree-creation hooks).
  They overlap with `wt`, and mixing them makes nested or duplicate worktrees.
- **Checksummed session names and stored file hashes.** `wt` compares copied files with their source at
  removal time and checks for an identity clash at creation time, which buys the same safety with names you
  can read.
- **Personal tooling on VMs or in the `Brewfile`.** Only what this setup itself uses goes in, which is why the
  Azure CLI is there: `azml-ssh-host` needs it. The shell files guard whatever else you install yourself.
