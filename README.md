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
├── install.sh                 links this repo into $HOME (Mac and Ubuntu)
├── Brewfile                   azure-cli fzf gh jq shellcheck; casks cmux, VS Code, git-credential-manager
├── .gitignore
├── bin/
│   ├── wt                     the task tool: worktrees, cmux rows, the picker, the driver, VMs
│   ├── agent-notify           agent lifecycle hook, relays to cmux or posts a banner
│   ├── cmux-hook              Mac-side cmux notification hook: remote wt open / wt attach
│   └── azml-ssh-host          Azure ML compute instance -> a Host block in ~/.ssh/config
├── home/
│   ├── .zshenv .zshrc .gitconfig .gitignore_global .tmux.conf
│   ├── .oh-my-zsh/custom/themes/workstation.zsh-theme
│   ├── .claude/
│   │   ├── AGENTS.md          the working conventions both agents read
│   │   ├── CLAUDE.md          one line: @AGENTS.md
│   │   └── settings.base.json, keybindings.json, statusline-command.sh
│   ├── .agents/skills/        task-driver, worktree-create, worktree-work, worktree-show, worktree-teardown,
│   │                          azml-compute
│   ├── .codex/                config.base.toml, hooks.base.json
│   └── .config/cmux/cmux.json
├── vscode/
│   ├── settings-snippet.jsonc six keys to paste; Settings Sync owns the rest
│   └── extensions.txt
└── docs/
    ├── new-mac.md             set up a Mac
    ├── new-vm.md              set up an Ubuntu VM
    ├── azml-compute.md        Azure ML compute instances over ssh
    └── ssh-config.example     the Host block a VM alias needs
```

## Install

```bash
mkdir -p ~/repos && git clone https://github.com/mal84emma/workstation ~/repos/workstation
bash ~/repos/workstation/install.sh
```

Full instructions: [docs/new-mac.md](docs/new-mac.md) and [docs/new-vm.md](docs/new-vm.md).

Until the repo is published, seed a machine with the `rsync` line in the notes of
[docs/new-vm.md](docs/new-vm.md) instead of the clone. A seeded copy has no `.git`, so `wt update` refuses
until it is replaced by a clone.

`install.sh` sorts every file into one of three classes.

| Class | Files | Behaviour |
|---|---|---|
| Symlinks | shell, git and tmux dotfiles, `AGENTS.md`, `CLAUDE.md`, the skills, `bin/*`, `cmux.json` (Mac only) | Edits, including an agent's, land in the repo, so `git diff` is the review |
| Machine-local copies | `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.codex/hooks.json` | Created from the versioned `.base` files. The apps write local state into them, so a normal run keeps what is there and only `install.sh --refresh-config` replaces them |
| Never touched | `~/.gitconfig.local`, `~/.zshrc.local`, `~/.zshenv.local` (which on a VM gains the `WT_HOST` and `WT_REPOS_DIR` lines when they are absent), and the real directories the apps write into | Your machine-local overrides, sourced or included by the linked files |

It is idempotent: rerun it after every repo change. Nothing is deleted. Anything in the way is moved into
`~/.workstation-backup/<timestamp>-<pid>`, which is created only when it is actually needed. It stops with a
message if oh-my-zsh is missing, or if `~/.gitconfig.local` holds no git identity. On Linux it records this
VM's alias in the Mac's `~/.ssh/config` as a `WT_HOST` line in `~/.zshenv.local`: given in the environment
(`WT_HOST=<vm> bash install.sh`, which is what the setup page does) or asked for once at a prompt. It records
`export WT_REPOS_DIR="$HOME"` there too, and puts one line at the top of `~/.bashrc` so that bash reads
`~/.zshenv`, because cmux runs its VM rows in bash. At the top because Ubuntu's `~/.bashrc` returns early in a
non-interactive shell, so the line has to come first to cover `ssh <vm> '<cmd>'` and `wt -H <vm> …` as well.

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
into the base nor pushed, or a file copied in through `.worktreeinclude` that no longer matches its source
in the main checkout. It names what blocked it. `--force` overrides. `wt prune` is stricter still: it only removes worktrees whose branch is merged and whose tree is clean.

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

`wt update` needs a real clone: a VM seeded with `rsync` refuses it until the seed is replaced by a clone.
Update the Mac's `wt` and each VM's `wt` together (`wt update` here, `wt -H <vm> update` there, or the rsync
seed while the repo is private): `wt -H <vm> …` runs the VM's copy for the remote half of every command, so a
VM left behind answers in a vocabulary this Mac no longer expects.

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
