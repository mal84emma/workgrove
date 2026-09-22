# Set up a new VM

For an Ubuntu 22.04 or 24.04 machine that already exists and that your Mac can already reach with `ssh <vm>`,
including an Azure ML compute instance. About 20 minutes of wall time, roughly 5 of it machine time; the rest
is the browser logins. The last block prints the elapsed wall time since the first line of block 1.

`<vm>` is the alias you gave the machine in the Mac's `~/.ssh/config`. Add that block first: for an Azure ML
compute instance run `azml-ssh-host add <instance>` on the Mac ([azml-compute.md](azml-compute.md)), which
writes the block with the right port, user and key; for any other VM copy
[ssh-config.example](ssh-config.example). `install.sh` is given exactly this name, and `wt -H <vm> …` and the
task picker use it. Two vCPUs and 8 GB of memory are comfortable.

Open a shell on the VM (`ssh <vm>`) and paste blocks 1, 2 and 4 each as one chunk, in order; run block 3 line by
line, because its logins and the `codex` TUI take over the terminal. Replace the UPPERCASE placeholders first.
`sudo` must work without a password, or block 1 asks for one; apt on an Azure ML image prints many repository
warnings, which are pre-existing and harmless. Blocks 1, 2 and 4 work over plain `ssh <vm>`; block 3 wants a
VS Code terminal (explained there). Nothing else prompts. To install an uncommitted change, seed the repo from the Mac before
block 2 (see the Notes).

```bash
# 1. packages   (the first line starts this page's clock)
date +%s > /tmp/workstation-setup-start
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git zsh tmux python3 jq curl rsync build-essential
(type -p wget >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wget) && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
sudo update-locale LANG=C.UTF-8
```

```bash
# 2. shell, identity, repo   (edit GIT_NAME / GIT_EMAIL / VM first)
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
git config --file ~/.gitconfig.local user.name  'GIT_NAME'
git config --file ~/.gitconfig.local user.email 'GIT_EMAIL'
mkdir -p ~/repos
[ -d ~/repos/workstation ] || git clone https://github.com/mal84emma/workstation ~/repos/workstation
# install.sh writes export WT_REPOS_DIR="$HOME" to ~/.zshenv.local, so repos cloned to ~/<repo> are found.
# For other folders, or several, edit that line: colon-separated, searched in order, e.g. "$HOME/work:$HOME"
# --refresh-config installs the portable Claude and Codex configs even when the image shipped its own; the
# old ones go to ~/.workstation-backup/<stamp>-<pid>/. On a later update never pass it without reading the sync
# table in the README, because it also drops Codex's hook and folder trust.
WT_HOST=<vm> bash ~/repos/workstation/install.sh --refresh-config   # replace <vm> with this machine's alias in the Mac's ~/.ssh/config
sudo chsh -s "$(command -v zsh)" "$(id -un)" && exec zsh -l   # last line: exec replaces the shell
```

Run block 3 from a VS Code terminal on the machine (Remote-SSH: Connect to Host → `<vm>`, then Terminal → New
Terminal), not from a plain `ssh` session. VS Code forwards the login callback port automatically, so `codex login`
opens the Mac browser and completes on its own; over plain ssh it needs `ssh -L 1455:localhost:1455 <vm>` kept
open in another Mac terminal, and `codex login --device-auth` is refused on some accounts. This also is the one
Remote-SSH connection the setup asks you to make.

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

```bash
# 4. Azure
command -v az >/dev/null || curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az account show >/dev/null 2>&1 || az login --use-device-code   # code in the Mac browser, like gh
az account show --query name -o tsv
echo "setup took $(( ($(date +%s) - $(cat /tmp/workstation-setup-start)) / 60 )) min"
```

## Then, on the Mac

⌃⌥⌘T → `<vm>` → `vm-shell` gives you a row titled `shell` with `@<vm>` on its second line. From there, or from
the driver row, start tasks with `wt -H <vm> new -r <repo> -p "…"`.

Inside tmux, Claude takes Ctrl+J for a newline; Shift+Enter submits, because tmux strips the modifier.

Check the VM answers:

```bash
ssh <vm> '~/.local/bin/wt help'
ssh <vm> 'cat ~/.zshenv.local'   # export WT_HOST=<vm> and export WT_REPOS_DIR="$HOME"
ssh <vm> '~/.local/bin/wt repos'   # name<TAB>path per repo: piped output is the plain form
ssh <vm> 'bash -ic "echo \$WT_REPOS_DIR"'   # what a cmux row sees; must print the home folder
ssh <vm> 'time bash -ic true'   # real under 0.1s; see the conda note below
wt -H <vm> repos --porcelain   # on the Mac; must print exactly the same lines as the third
```

The second must show both lines `install.sh` wrote: the alias you gave it, and the repos folder. If either
line is missing, `wt` on the VM cannot ask the Mac for rows or find repos; fix `~/.zshenv.local` on the VM.
The third lists every git repo directly under the VM's home folder, one `name<TAB>path` per line, with hidden
folders such as `~/.oh-my-zsh` excluded; an empty result only means no repo has been cloned there yet. The
last runs the same thing from the Mac and must print the same lines, because both are a non-interactive bash
on the VM (without `--porcelain`, `wt -H <vm> repos` on a terminal asks the VM for the table instead); if it fails with `repos dir not found`, the `~/.zshenv` line is missing from the top of the VM's
`~/.bashrc`, and rerunning `install.sh` there puts it back. A tmux session that already existed when
`install.sh` ran keeps its old environment, so a shell row attached to it still lacks `WT_REPOS_DIR` until you
run `exec bash` in that pane or open a new tmux window.

## Notes

- **A machine that is not fresh** (an Azure ML compute instance usually is not). Skip this on a fresh machine.
  `install.sh` moves whatever is in the way into `~/.workstation-backup/<stamp>-<pid>/` and prints that path, or
  prints `done. nothing needed backing up`. Before block 2, copy from an existing `~/.gitconfig` only what the
  linked one does not already cover: the linked `~/.gitconfig` routes github.com through
  `gh auth git-credential` and includes `~/.gitconfig.local`, so carry over other hosts' credential helpers
  and per-URL settings into `~/.gitconfig.local`, not the github.com helper.
- **Seeding instead of cloning** (to carry an uncommitted change to a VM). From the Mac:
  `ssh <vm> 'mkdir -p ~/repos' && rsync -a --exclude .git ~/repos/workstation/ <vm>:~/repos/workstation/`.
  Block 2's clone line then finds the folder and skips. A seeded copy has no `.git`, so `wt update` and
  `wt -H <vm> update` refuse until it is replaced by a clone; until then re-seed with the same rsync line and
  rerun `bash ~/repos/workstation/install.sh` on the VM.
- **Update the Mac's `wt` and each VM's `wt` together** (`wt update` on the Mac, `wt -H <vm> update` on the
  VM, or the rsync seed above for an uncommitted change), because `wt -H <vm> …` runs the VM's copy for the
  remote half of every command, and a VM left behind answers in a vocabulary the Mac no longer expects.
- **Check free disk first** with `df -h /`: blocks 1 and 3 download about 1 GB.
- **Do not run `cmux hooks codex install` on a VM.** That is a Mac-only step. The VM keeps only the portable
  hooks, which relay over the cmux socket; cmux's generated handlers hold Mac-local paths and a state protocol
  that cannot travel.
- **cmux rows on a VM run bash, not zsh.** A row is a plain `cmux ssh` row: it starts the VM's login shell
  and types its `--command` text into it once, and that line creates or attaches the task's tmux session, so
  the oh-my-zsh prompt is not used there. An Azure ML compute instance goes further: it resets the login
  shell to `/bin/bash` at every boot, so the `chsh` line in block 2 only lasts until the next stop/start
  there, and nothing in the harness depends on it. The one line `install.sh` puts at the *top* of `~/.bashrc`,
  which sources `~/.zshenv`, is what carries `wt`, `WT_HOST` and `WT_REPOS_DIR` into every bash on the VM,
  interactive or not, including `ssh <vm> '<cmd>'` and so `wt -H <vm> …`. At the top because Ubuntu's own
  `~/.bashrc` returns on its fourth line when the shell is not interactive, and anything below that return is
  never read by a command sent over ssh. Type `zsh` inside the row's tmux for the usual prompt.
- No extra network rule is needed: the rows are plain ssh, and tmux is started by the row's own shell. After a
  VM reboot or a cmux relaunch onto a lost pty a row shows a bare shell; `wt -H <vm> attach -r <repo> <name>`
  re-attaches it (add `--restart-agent` when the reboot took the tmux session with it, or `--reattach` when a
  dropped connection left the VM holding the old pty, which is the case cmux announces in the row as
  `remote session was lost; starting a new shell`).
- **Slow shells on an Azure ML compute instance.** The image's `~/.bashrc` runs a `conda init` block (about
  2.5 s) and `conda activate azureml_py38` (about 1 s) in every shell, which delays each cmux row, each
  `wt -H <vm>` call and the tmux status line. If your repos manage Python with `uv`, comment out the
  `conda activate` line and replace the `# >>> conda initialize >>>` block with a lazy wrapper, so that
  `conda` still works on first use:

  ```bash
  conda() { unset -f conda; eval "$(/anaconda/bin/conda shell.bash hook 2>/dev/null)"; conda "$@"; }
  ```

  A fresh shell then has `python3` but no bare `python`. `~/.bashrc` is your file: `install.sh` only adds its
  one sourcing line at the top and never edits the rest of it.
- Give the VM a regular OS disk, not an ephemeral one: an ephemeral disk loses its contents when the machine
  is stopped, and the point of the tmux sessions is that they survive.
- Restrict the VM's inbound ssh rule to your own IP address.
