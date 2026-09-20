# Set up a new VM

For an Ubuntu 22.04 or 24.04 machine that already exists and that your Mac can already reach with `ssh <vm>`,
including an Azure ML compute instance. About 20 minutes, and the last block prints how long it actually took.

`<vm>` is the alias you gave the machine in the Mac's `~/.ssh/config`. Add that block first, from
[ssh-config.example](ssh-config.example); `install.sh` asks for exactly this name, and `wt -H <vm> …` and the
task picker use it. Two vCPUs and 8 GB of memory are comfortable.

Open a shell on the VM (`ssh <vm>`) and paste the blocks in order. Replace the UPPERCASE placeholders first.
Nothing prompts except `install.sh` and the logins in blocks 3 and 4. Blocks 1, 2 and 4 work over plain `ssh <vm>`;
block 3 wants a VS Code terminal (explained there).

```bash
# 1. packages   (the first line starts this page's clock)
date +%s > /tmp/workstation-setup-start
sudo apt-get update && sudo apt-get install -y git zsh tmux python3 jq curl rsync build-essential
(type -p wget >/dev/null || sudo apt-get install -y wget) && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt-get update && sudo apt-get install -y gh
sudo update-locale LANG=C.UTF-8
```

```bash
# 2. shell, identity, repo   (edit GIT_NAME / GIT_EMAIL first)
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
git config --file ~/.gitconfig.local user.name  'GIT_NAME'
git config --file ~/.gitconfig.local user.email 'GIT_EMAIL'
mkdir -p ~/repos && [ -d ~/repos/workstation ] || git clone https://github.com/mal84emma/workstation ~/repos/workstation
# install.sh writes export WT_REPOS_DIR="$HOME" to ~/.zshenv.local, so repos cloned to ~/<repo> are found.
# For other folders, or several, edit that line: colon-separated, searched in order, e.g. "$HOME/work:$HOME"
bash ~/repos/workstation/install.sh          # asks once for this VM's alias, no default
sudo chsh -s "$(command -v zsh)" "$USER" && exec zsh -l
```

Run block 3 from a VS Code terminal on the machine (Remote-SSH: Connect to Host → `<vm>`, then Terminal → New
Terminal), not from a plain `ssh` session. VS Code forwards the login callback port automatically, so `codex login`
opens the Mac browser and completes on its own; over plain ssh it needs `ssh -L 1455:localhost:1455 <vm>` kept
open in another Mac terminal, and `codex login --device-auth` is refused on some accounts. This also is the one
Remote-SSH connection the setup asks you to make.

```bash
# 3. agents and logins (interactive, in a VS Code terminal on the machine)
curl -fsSL https://claude.ai/install.sh | bash        # -> ~/.local/bin/claude
curl -fsSL https://chatgpt.com/codex/install.sh | sh  # -> ~/.local/bin/codex (static musl build)
gh auth login --web --git-protocol https              # device code, opened in the Mac's browser
claude auth login                                     # browser login on the Mac; claude auth status must say loggedIn true
codex login                                           # browser login; the callback comes back through VS Code
codex                                                 # /hooks -> trust the two portable hooks, then exit
gh auth status && claude --version && codex login status && claude doctor
gh repo clone OWNER/REPO ~/REPO
```

```bash
# 4. Azure
command -v az >/dev/null || curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login --use-device-code   # code in the Mac browser, like gh
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
ssh <vm> 'zsh -c "echo \$WT_HOST"'
ssh <vm> '~/.local/bin/wt repos'
```

The second must print the alias you typed during `install.sh`. If it is empty, `wt` on the VM cannot ask the
Mac for rows; fix `~/.zshenv.local` on the VM. The third lists every git repo directly under the VM's home
folder, one `name<TAB>path` per line, with hidden folders such as `~/.oh-my-zsh` excluded; an empty result
only means no repo has been cloned there yet.

## Notes

- **A machine that is not fresh** (an Azure ML compute instance usually is not) works the same; `install.sh` moves
  whatever is in the way into `~/.workstation-backup/<stamp>/` and prints the path. Before block 2, copy anything
  you want to keep from an existing `~/.gitconfig` beyond `user.*` (credential helpers, per-URL settings) into
  `~/.gitconfig.local`, because the linked `~/.gitconfig` includes that file and nothing else. An existing
  `~/.claude/settings.json` is kept as is, so the portable hooks are not installed until you run
  `bash ~/repos/workstation/install.sh --refresh-config` and put your own keys back.
- **Do not run `cmux hooks codex install` on a VM.** That is a Mac-only step. The VM keeps only the portable
  hooks, which relay over the cmux socket; cmux's generated handlers hold Mac-local paths and a state protocol
  that cannot travel.
- No extra network rule is needed. cmux's `mosh-tmux` runs tmux over plain ssh when mosh is absent.
- Give the VM a regular OS disk, not an ephemeral one: an ephemeral disk loses its contents when the machine
  is stopped, and the point of the tmux sessions is that they survive.
- Restrict the VM's inbound ssh rule to your own IP address.
