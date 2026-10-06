# Set up a new VM

Use this procedure to set up an Ubuntu VM for workgrove tasks. The VM must already exist, and your Mac must
already reach it with `ssh <vm>`. An Azure ML compute instance is also a VM for this procedure.

The setup takes about 20 minutes of wall time. About 5 minutes of it is machine time; the browser logins take
the rest. The last block prints the elapsed wall time since the first line of block 1.

## Prerequisites

- The VM runs Ubuntu 22.04 or 24.04. Two vCPUs and 8 GB of memory are comfortable.
- The Mac's `~/.ssh/config` has a host entry for the VM. `<vm>` is the alias that you gave the VM in that
  entry. Block 2 gives `install.sh` exactly this name, and `wt -H <vm> …` and the task picker (⌃⌥⌘T) use it.
  Add the entry first:
  - For an Azure ML compute instance, run `azml-ssh-host add <instance>` on the Mac
    ([azml-compute.md](azml-compute.md)). This command writes the entry with the correct port, user, and key.
  - For any other VM, copy [ssh-config.example](ssh-config.example).
- `sudo` works on the VM without a password. Otherwise, block 1 asks for one.
- The VM has enough free disk. Blocks 1 and 3 download about 1 GB. Before block 1, check the free disk on the
  VM with `df -h /`.
- The VM has a regular OS disk, not an ephemeral one. An ephemeral disk loses its contents when the machine is
  stopped, and the purpose of the tmux sessions is that they survive.
- The VM's inbound ssh rule is restricted to your own IP address. No other network rule is necessary: the rows
  are plain ssh, and the row's own shell starts tmux.

## Placeholders

Replace these placeholders before you run the blocks:

| Placeholder | Where | Replace with |
| --- | --- | --- |
| `GIT_NAME` and `GIT_EMAIL` | Block 2 | Your git user name and email |
| `<vm>` | Block 2's `install.sh` line | The VM's alias in the Mac's `~/.ssh/config` |
| `OWNER/REPO` and `~/REPO` | Block 3's `gh repo clone` line | The repository to clone, and its folder `~/<repo>` |

## How to run the blocks

1. Open a shell on the VM with `ssh <vm>`.
2. Paste block 1 as one chunk.
3. Read [Block 2](#block-2-shell-identity-repo) and do the steps that apply to your machine. To install an
   uncommitted change, seed the repo from the Mac first (see
   [Seeding instead of cloning](#seeding-instead-of-cloning)). Then paste block 2 as one chunk.
4. Open a VS Code terminal on the VM (see [Block 3](#block-3-agents-and-logins)). Run block 3 line by line,
   because its logins and the `codex` TUI (terminal user interface) take over the terminal.
5. In the `ssh <vm>` shell, paste block 4 as one chunk.

Blocks 1, 2, and 4 work over plain `ssh <vm>`. Use a VS Code terminal for block 3.

Only `sudo` (when it needs a password) and the logins in blocks 3 and 4 prompt you. Nothing else prompts. On an Azure ML image, apt prints
many repository warnings. These warnings were there before the setup, and they are harmless.

## Block 1: packages

Block 1 installs the packages and `gh`, and it sets the locale. It also adds the sshd keepalive file, which
shortens future stale SSH connections to about a minute (see [Recovering a VM row](#recovering-a-vm-row)).

```bash
# 1. packages   (the first line starts this page's clock)
date +%s > /tmp/workgrove-setup-start
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git zsh tmux python3 jq curl rsync build-essential
(type -p wget >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wget) && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
sudo update-locale LANG=C.UTF-8
# sshd uses the first value it reads in sshd_config.d. This file sorts before Ubuntu's 50-cloudimg-settings.conf.
conf=/etc/ssh/sshd_config.d/10-workgrove-keepalive.conf keepalive=$(mktemp)
printf 'ClientAliveInterval 15\nClientAliveCountMax 4\n' >"$keepalive"
if ! sudo cmp -s "$keepalive" "$conf"; then
  sudo install -m 644 "$keepalive" "$conf"
  # if sshd -t fails, the block removes the new file at once, so it cannot break the next sshd restart and lock you out
  if sudo sshd -t; then sudo systemctl reload ssh; else sudo rm -f "$conf"; echo "sshd -t failed; removed $conf" >&2; fi
fi
rm -f "$keepalive"
sudo sshd -T | grep -i clientalive   # clientaliveinterval 15; clientalivecountmax 4
```

## Block 2: shell, identity, repo

Block 2 installs oh-my-zsh, sets your git identity, clones the repo, and runs `install.sh` with two flags.
Read this section before you paste it.

**The repos folder.** `install.sh` writes `export WT_REPOS_DIR="$HOME"` to `~/.zshenv.local`, so `wt` finds
repos that you clone to `~/<repo>`. To use other folders, or several folders, edit that line after block 2
writes it. Separate the folders with colons, for example `"$HOME/work:$HOME"`. `wt` searches them in order.

**`--refresh-config`** installs the portable Claude and Codex configs, even when the image shipped its own.
`install.sh` moves the old configs to `~/.workgrove-backup/<stamp>-<pid>/`.

> **Warning:** `--refresh-config` also drops Codex's hook and folder trust. Because of this, on a later update,
> never pass the flag without reading the sync table in the README
> ([Keeping machines in sync](../README.md#keeping-machines-in-sync)).

**`--opinionated-config`** asks for the author's own versions of these six items:

- `~/.zshrc` (this is why block 2 installs oh-my-zsh)
- `~/.gitconfig`
- `~/.tmux.conf`
- the Claude keymap
- the Claude status line
- the `tui`, `voice`, and `theme` keys of `~/.claude/settings.json`

If you remove the flag, the install leaves all six to you, and the core setup stays intact (see the README's
[Install](../README.md#install) section).

You never have to repeat the flag for the first five items, which are files. After they are links into the
repo, the bare `install.sh` rerun behind `wt update` keeps them. The machine-local copy itself records the
user interface (UI) keys (`tui`, `voice`, and `theme`). A `settings.json` with a top-level `tui` key came from
a run that got the flag. Thus `--refresh-config` keeps these keys instead of removing them.

**If the machine is not fresh** (an Azure ML compute instance usually is not fresh), read this part. On a
fresh machine, skip it. `install.sh` moves whatever is in the way into `~/.workgrove-backup/<stamp>-<pid>/`
and prints that path. If nothing is in the way, it prints `done. nothing needed backing up`. Block 2's
`--opinionated-config` is what moves an existing `~/.gitconfig` and `~/.tmux.conf` into that folder.

The linked `~/.gitconfig` already routes github.com through `gh auth git-credential` and includes
`~/.gitconfig.local`. Before you run block 2 with this flag, copy these other settings from your existing
`~/.gitconfig` into `~/.gitconfig.local`:

- the credential helpers of other hosts
- per-URL settings

Do not copy the github.com helper.

Without `--opinionated-config`, `install.sh` moves neither file. It adds `core.excludesFile` and the
`~/.gitconfig.local` include to your existing `~/.gitconfig`. It appends cmux's one `update-environment` line
to your `~/.tmux.conf`.

```bash
# 2. shell, identity, repo   (edit GIT_NAME / GIT_EMAIL / <vm> first)
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
git config --file ~/.gitconfig.local user.name  'GIT_NAME'
git config --file ~/.gitconfig.local user.email 'GIT_EMAIL'
mkdir -p ~/repos
[ -d ~/repos/workgrove ] || git clone https://github.com/mal84emma/workgrove ~/repos/workgrove
# flags: see "Block 2" in docs/new-vm.md. WT_REPOS_DIR goes to ~/.zshenv.local.
WT_HOST=<vm> bash ~/repos/workgrove/install.sh --opinionated-config --refresh-config   # replace <vm> with this machine's alias in the Mac's ~/.ssh/config
sudo chsh -s "$(command -v zsh)" "$(id -un)" && exec zsh -l   # last line: exec replaces the shell
```

## Block 3: agents and logins

Run block 3 in a VS Code terminal on the VM, not in a plain `ssh` session:

1. In VS Code, select Remote-SSH: Connect to Host → `<vm>`.
2. Select Terminal → New Terminal.

This is the only Remote-SSH connection that the setup asks you to make. VS Code forwards the login callback
port automatically, so `codex login` opens the Mac browser and completes on its own. Over plain ssh, `codex login` needs `ssh -L 1455:localhost:1455 <vm>` kept open in another Mac terminal, and
some accounts refuse `codex login --device-auth`.

> **Warning:** Do not run `cmux hooks codex install` on a VM. It is a Mac-only step. The VM keeps only the
> portable hooks, which relay over the cmux socket. The handlers that cmux generates contain Mac-local paths and a
> state protocol that cannot travel.

```bash
# 3. agents and logins (interactive, in a VS Code terminal on the machine)
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash   # -> ~/.local/bin/claude
command -v codex  >/dev/null || curl -fsSL https://chatgpt.com/codex/install.sh | sh   # -> ~/.local/bin/codex
gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https   # one-time code; VS Code forwards the callback
claude auth status | grep -q '"loggedIn": true' || claude auth login   # browser login on the Mac
codex login status >/dev/null 2>&1 || codex login   # browser login; the callback comes back through VS Code
codex   # /hooks -> trust the two portable hooks, then exit
gh auth status; claude auth status; codex login status; claude doctor   # loggedIn true; ignore doctor's Remote Control lines
gh repo clone OWNER/REPO ~/REPO
```

## Block 4: Azure

Block 4 installs the Azure CLI from Microsoft's signed apt source, logs in to Azure, and prints the setup time.

```bash
# 4. Azure   (Microsoft's step-by-step install: their signing key in a keyring, their apt source signed by it)
command -v az >/dev/null || { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https ca-certificates gnupg lsb-release \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null \
  && sudo chmod go+r /etc/apt/keyrings/microsoft.gpg \
  && printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-by: /etc/apt/keyrings/microsoft.gpg\n' "$(lsb_release -cs)" "$(dpkg --print-architecture)" | sudo tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null \
  && sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y azure-cli; }
# Shorter, but unverified: a shortened URL piped into a root shell, with no signature check on what comes back.
# command -v az >/dev/null || curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az account show >/dev/null 2>&1 || az login --use-device-code   # code in the Mac browser, like gh
az account show --query name -o tsv
echo "setup took $(( ($(date +%s) - $(cat /tmp/workgrove-setup-start)) / 60 )) min"
```

## Then, on the Mac

### Check the VM

Run these commands on the Mac to make sure that the VM answers:

```bash
ssh <vm> '~/.local/bin/wt help'
ssh <vm> 'cat ~/.zshenv.local'   # export WT_HOST=<vm> and export WT_REPOS_DIR="$HOME"
ssh <vm> '~/.local/bin/wt repos'   # name<TAB>path per repo: piped output is the plain form
ssh <vm> 'bash -ic "echo \$WT_REPOS_DIR"'   # what a cmux row sees; must print the home folder
ssh <vm> 'time bash -ic true'   # real under 0.1s; see the conda note below
wt -H <vm> repos --porcelain   # on the Mac; must print exactly the same lines as the third
```

The expected results are:

- **Second command:** both lines that `install.sh` wrote, that is, the alias that you gave it and the repos
  folder. If a line is missing, `wt` on the VM cannot ask the Mac for rows or find repos. Fix
  `~/.zshenv.local` on the VM.
- **Third command:** every git repo directly under the VM's home folder, one `name<TAB>path` per line. The
  list excludes hidden folders, such as `~/.oh-my-zsh`. An empty result only means that you have not cloned a
  repo there yet.
- **Fourth command:** the home folder. This is what a cmux row sees.
- **Fifth command:** a `real` time under 0.1s. Otherwise, see the conda note
  ([Slow shells on an Azure ML compute instance](#slow-shells-on-an-azure-ml-compute-instance)).
- **Last command:** exactly the same lines as the third command. The lines must match because both commands
  run a non-interactive bash on the VM. Without `--porcelain`, `wt -H <vm> repos` on a terminal asks the VM for the table instead.

If the last command fails with `repos dir not found`, the `~/.zshenv` line is missing from the top of the VM's
`~/.bashrc`. Run `install.sh` on the VM again to put the line back.

A tmux session that already existed when `install.sh` ran keeps its old environment, so a shell row attached
to it does not have `WT_REPOS_DIR`. To get it, run `exec bash` in that pane or open a new tmux window.

### Open a shell row and start tasks

Press ⌃⌥⌘T to open the task picker. Select `<vm>`, then select `vm-shell`. You get a row titled `shell` with
`@<vm>` on its second line. From this row, or from the driver row (the row titled `driver`, ⌃⌥⌘D), start tasks
with `wt -H <vm> new -r <repo> -p "…"`.

### Keys and colors inside tmux

Inside tmux, Ctrl+J always gives Claude a newline. Shift+Enter also gives a newline, but only with the linked
`~/.tmux.conf` (`--with-tmux-conf` or `--opinionated-config`). The `extended-keys` option in that file passes
the modifier through. Under tmux's defaults, tmux strips the modifier and Shift+Enter submits. The same occurs
in a session that started before the file arrived.

The same file also brings these settings:

- **True color.** The file sets `COLORTERM=truecolor`. ssh does not carry this variable over. The file also sets
  `CLAUDE_CODE_TMUX_TRUECOLOR=1`. Without this variable, Claude caps itself at 256 colors inside tmux.
- **A 10 ms `escape-time`** instead of 500 ms.
- **Focus events.**

Ubuntu 22.04's tmux is 3.2a, and the file is written for that version. The Ubuntu archive has nothing newer
for that release. Thus the file leaves out options that need 3.3 or later, for example `allow-passthrough`.
The setup does not install a newer tmux from a PPA (personal package archive) or from source to get them.

### When the tmux settings take effect

tmux reads `~/.tmux.conf` only when the server starts. Thus none of the settings in that file reach a tmux
server that was already running when the file landed. On that server, none of the `TERM`, `COLORTERM`,
`CLAUDE_CODE_TMUX_TRUECOLOR`, `escape-time`, and `extended-keys` settings is in effect. That is exactly the
state right after `install.sh` on a VM with live sessions. It is the usual reason that colors or Shift+Enter do not change.

After the server reads the file, the remaining boundary is the **pane**, not the session. On every spawn,
tmux reads `default-terminal`, so a new pane in an old session gets the new `TERM`. Only a pane that is already
running keeps the `TERM` it started with.

> **Warning:** Do not run `tmux kill-server` to apply the file. It takes every task on the VM with it (see the
> note [`server exited unexpectedly` after `tmux kill-server`](#server-exited-unexpectedly-after-tmux-kill-server)).

To apply the file safely, do one of these:

- Start a new pane or window.
- For one task, run `tmux kill-session -t wt-<repo>-<name>` and let the row re-create the session.

### Update the Mac and each VM together

When you update workgrove later, update the Mac's `wt` and each VM's `wt` together. `wt -H <vm> …` runs the
VM's copy for the remote half of every command. A VM that is left behind answers in a vocabulary that the Mac
no longer expects.

- **On the Mac:** run `wt update`.
- **For a VM:** do one of these:
  - Run `wt -H <vm> update` from an interactive Mac terminal.
  - Run `wt update` in a shell on the VM.
  - For an uncommitted change, use the rsync line in [Seeding instead of cloning](#seeding-instead-of-cloning).

`wt update` prints the incoming commits and a diffstat. It asks before it merges them and runs `install.sh`, and
the default answer is no. With no terminal on stdin, it refuses instead of applying them unattended.
`wt -H <vm> update` has a terminal to lend the VM only when the Mac side has one.

## Notes

### Seeding instead of cloning

Seeding carries an uncommitted change to a VM. From the Mac, run:
`ssh <vm> 'mkdir -p ~/repos' && rsync -a --exclude .git --exclude .worktrees ~/repos/workgrove/ <vm>:~/repos/workgrove/`

- `--exclude .worktrees` keeps your task worktrees on the Mac, where they belong.
- Block 2's clone line then finds the folder and skips the clone.
- A seeded copy has no `.git`, so `wt update` and `wt -H <vm> update` refuse until a clone replaces the copy.
  Until then, re-seed with the same rsync line and run `bash ~/repos/workgrove/install.sh` on the VM again.
- A VM seeded before the rsync line had `--exclude .worktrees` still has a stale copy of every Mac worktree.
  The rsync line has no `--delete`, so re-seeding does not remove that copy. Run `ssh <vm> 'rm -rf ~/repos/workgrove/.worktrees'` once.

### cmux rows on a VM run bash, not zsh

A row is a plain `cmux ssh` row. It starts the VM's login shell and types its `--command` text into it once.
That line creates or attaches the task's tmux session, so the row does not use the oh-my-zsh prompt. Type `zsh`
inside the row's tmux for the usual prompt.

An Azure ML compute instance resets the login shell to `/bin/bash` at every boot. Thus the `chsh` line in block
2 lasts only until the next stop/start there. Nothing in the harness depends on that line.

`install.sh` puts one line at the *top* of `~/.bashrc`, and that line sources `~/.zshenv`. This line carries
`wt`, `WT_HOST`, and `WT_REPOS_DIR` into every bash on the VM, interactive or not. This includes
`ssh <vm> '<cmd>'` and thus `wt -H <vm> …`. The line must be at the top because Ubuntu's own `~/.bashrc`
returns on its fourth line when the shell is not interactive. A command sent over ssh never reads anything
below that return.

### Recovering a VM row

**After a VM reboot, or after a cmux relaunch onto a lost pty (pseudo-terminal),** a row can show a bare
shell. Run `wt -H <vm> attach -r <repo> <name>`. If the reboot took the tmux session with it, run the same
command with `--restart-agent`.

**After a dropped connection that left the VM holding the old pty,** cmux announces
`remote session was lost; starting a new shell`. Inspect the row. If it shows a bare shell, run
`wt -H <vm> attach -r <repo> <name>` with `--reattach`.

**After a Wi-Fi network switch,** a row can instead be suspended with this message:
`Error: ssh-pty-attach: The cmux relay on <vm> did not become ready (the host may not allow SSH remote port forwarding). Automatic reconnect paused; use Reconnect to try again.`

The port-forwarding warning in this message is misleading. After the Mac's IP changes, the old SSH connection
can still hold that row's fixed relay port on the VM. Run `wt -H <vm> attach -r <repo> <name>`. This command
does these steps:

1. It checks only that suspended row.
2. It stops the stale listener on the row's relay port, on any local address. The listener is a user-owned
   `sshd`, or `sshd-session` from OpenSSH 9.8.
3. It asks cmux to reconnect the row.

The command refuses, and signals nothing, when that `sshd`'s connection comes from the Mac's current address,
because that session can still be live. When the command does not refuse, it then does one of these:

- If a fresh VM check shows the session detached and the row shows a recognizable task-shell prompt, it
  reattaches tmux.
- If the task's client is attached, it restores tmux's terminal settings. It does this only after a fresh
  tmux status message appears in that connected row.
- Otherwise, it selects the row and prints the exact `--reattach` command. Inspect the row before you run that
  command.

If the wheel types arrow keys, or paste or Shift+Enter misbehaves, run the same attach command.

If recovery fails, wait for the VM to drop the old SSH session. With block 1's keepalive, this takes about a
minute. Then press **Reconnect** on the row, or run `wt -H <vm> attach -r <repo> <name>` again.

**Block 1's keepalive.** A normal SSH reload does not end existing sessions, so block 1's keepalive setting
only shortens future stale connections to about a minute.

A VM set up before that setting existed does not have it. To add it, paste only
block 1's keepalive lines, from its `sshd_config.d` comment to the end. These lines are idempotent.
During recovery, `wt -H <vm> attach` warns when the VM's sshd has no `ClientAliveInterval`.

It is **UNVERIFIED** whether Azure ML keeps `/etc/ssh/sshd_config.d/10-workgrove-keepalive.conf` across a
stop/start. (Azure ML does reset the login shell.) On an Azure ML compute instance, after a stop/start, run
this command on the Mac:
`ssh <vm> 'ls -l /etc/ssh/sshd_config.d/10-workgrove-keepalive.conf; sudo sshd -T | grep -i clientalive'`.
If the file is missing, or the output does not show `clientaliveinterval 15` and `clientalivecountmax 4`,
paste block 1's keepalive lines again.

### `server exited unexpectedly` after `tmux kill-server`

> **Warning:** `tmux kill-server` ends **every session on that socket**. That is every `wt-<repo>-<name>` task
> on that VM and every agent that runs in one. It is almost never what you want. To restart a single task, use
> `tmux kill-session -t wt-<repo>-<name>` and let the row re-create the session. `wt show <name>` prints the
> session name.

After a `tmux kill-server`, every tmux command, `wt new` included, fails with `server exited unexpectedly`.
The server ends its sessions, but it waits for its clients to leave before it exits. A control-mode client
(`tmux -CC attach`) that a dropped connection left behind never leaves. Such a client has parent PID 1, and its
pty is gone.

The half-exited server keeps the socket and drops every new connection. This includes `tmux list-clients`, so
you cannot ask tmux which clients are left. You must look at the process table instead.

Kill only the orphaned clients (parent PID 1), because a plain `grep '[t]mux -CC'` also lists the healthy
control-mode clients that drive your live cmux rows. If you kill those clients, the rows drop.

1. Run this command:

   ```bash
   ps -eo pid,ppid,tty,args | awk '$2==1 && /[t]mux -CC/'   # ppid 1 only; the tty column shows the lost pty
   ```

2. `kill` those PIDs.

The server then finishes its exit, and the next tmux command starts a fresh server.

### Slow shells on an Azure ML compute instance

The image's `~/.bashrc` runs a `conda init` block (about 2.5 s) in every shell. It also runs
`conda activate azureml_py38` (about 1 s) in every shell. These delay each cmux row, each `wt -H <vm>` call,
and the tmux status line.

If your repos manage Python with `uv`, do these steps:

1. Comment out the `conda activate` line.
2. Replace the `# >>> conda initialize >>>` block with this lazy wrapper, so that `conda` still works on first
   use:

   ```bash
   conda() { unset -f conda; eval "$(/anaconda/bin/conda shell.bash hook 2>/dev/null)"; conda "$@"; }
   ```

A fresh shell then has `python3` but no bare `python`. `~/.bashrc` is your file: `install.sh` only adds its one
sourcing line at the top, and it never edits the rest of the file.
