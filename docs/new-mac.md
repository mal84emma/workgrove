# Set up a new Mac

This procedure sets up a new Mac for workgrove. It takes about 30 minutes. Most of that time is downloads and
logins.

## Before you start

Run the four blocks on this page in order. Block 3 needs two things before it runs `install.sh`:

- A git identity. `install.sh` always requires one. Block 3 sets it.
- oh-my-zsh. Block 3 runs `install.sh` with `--opinionated-config`, which asks for the author's own config (the
  opt-in config). `install.sh` requires oh-my-zsh whenever that config's `~/.zshrc` is asked for. Block 2 installs
  oh-my-zsh.

The `Brewfile` has one commented-out line: `brew "azure-cli"`. In this repo, only `bin/azml-ssh-host` needs the
Azure CLI, so `brew bundle` leaves it out of a machine that will never touch Azure. The `az login` in block 4 and
[azml-compute.md](azml-compute.md) both need the Azure CLI. If you want it, do one of these:

- Uncomment that line before you run `brew bundle` in block 2.
- Install it on its own at any time with `brew install azure-cli`.

## Block 1: Command Line Tools

If the installer opens, wait for it. Run the block again until it prints a path.

```bash
# 1. Command Line Tools (wait for the installer if it opens; re-run until it prints a path)
xcode-select -p >/dev/null 2>&1 || xcode-select --install
```

## Block 2: Homebrew, the repo, the essentials and oh-my-zsh

If Homebrew is already installed for the whole machine, skip the first line of this block. Start at
`eval "$(...brew shellenv)"`. This can happen, for example, in a second account on the same Mac.

```bash
# 2. Homebrew, repo, essentials, oh-my-zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
mkdir -p ~/repos && git clone https://github.com/mal84emma/workgrove ~/repos/workgrove
brew bundle --file ~/repos/workgrove/Brewfile
[ -f ~/.oh-my-zsh/oh-my-zsh.sh ] || sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

## Block 3: Git identity and install

Before you run this block, replace `GIT_NAME` and `GIT_EMAIL` with your own values.

The block also holds two optional settings as commented-out lines. To use one, uncomment its line before you run
the block.

- A credential helper for another git host, for example Azure DevOps.
- Repos in more than one folder. The line writes `WT_REPOS_DIR` into `~/.zshenv.local`, a file that is never
  versioned. The folders are searched in order.

```bash
# 3. identity, install   (edit GIT_NAME / GIT_EMAIL first)
git config --file ~/.gitconfig.local user.name  'GIT_NAME'
git config --file ~/.gitconfig.local user.email 'GIT_EMAIL'
git config --file ~/.gitconfig.local core.editor 'code --wait'
# optional: a credential helper for another git host, for example Azure DevOps
# git config --file ~/.gitconfig.local credential.https://dev.azure.com.helper manager
# optional: repos in more than one folder (searched in order; the file is never versioned)
# echo 'export WT_REPOS_DIR="$HOME/work/repos:$HOME/Documents/Repositories"' >> ~/.zshenv.local
bash ~/repos/workgrove/install.sh --opinionated-config
exec zsh -l     # separate line on purpose: chained with &&, it is skipped whenever install.sh exits non-zero
```

Keep `exec zsh -l` on a separate line. If you chain it with `&&`, the shell skips it whenever `install.sh` exits
non-zero.

## Check the `install.sh` run

`install.sh` prints one line for each file that it links or installs. It also tells you where it put anything
that it moved out of the way.

If a git identity is missing, `install.sh` stops before it changes anything. Because this page installs
`~/.zshrc`, it also stops if oh-my-zsh is missing. So a run that stops early has changed nothing.

The last step clones the two zsh plugins that `~/.zshrc` enables (`zsh-autosuggestions`,
`zsh-syntax-highlighting`) into `~/.oh-my-zsh/custom/plugins/`. This clone is the only step that needs the
network. All steps before it are local. The oh-my-zsh prerequisite and the plugin clone belong to the opt-in
`~/.zshrc` alone. Without that file, neither applies.

Run `install.sh` again whenever the repo changes.

## What `--opinionated-config` installs

`--opinionated-config` asks for the opt-in config. These are seven pieces that are the author's personal
preferences, not core setup (what a bare `install.sh` run installs):

1. `~/.zshrc`, with the oh-my-zsh theme
2. `~/.gitconfig`
3. `~/.tmux.conf`
4. the Claude keymap
5. the status line
6. cmux's own `cmux.json`
7. the `tui`, `voice` and `theme` keys of `~/.claude/settings.json`

The first six are files. `install.sh` installs `~/.claude/settings.json` with or without the flag, for its hooks
and permissions.

A bare `install.sh` run installs the core setup and leaves all seven pieces alone. A stranger who clones this
repo gets this result. The README's [Install](../README.md#install) section gives the detail for each flag and
what arrives instead.

Later runs keep the opt-in config:

- **The six files.** You never have to repeat the flag for them. Once they are links into this repo, a later bare
  run keeps them (for example, the run that `wt update` does).
- **The UI keys** (`tui`, `voice`, `theme`). The machine-local copy itself remembers them. A
  `~/.claude/settings.json` with a top-level `tui` key came from a run that had the flag. So a later
  `--refresh-config` keeps those keys instead of removing them.

## Block 4: Agents, Codex hooks and logins

Block 4 installs Claude and Codex, sets up the Codex hooks and the VS Code extensions, and logs you in. Three
lines need your attention:

- `az login`: skip it unless you installed azure-cli. See [azml-compute.md](azml-compute.md).
- `claude auth login`: log in through the browser. Then `claude auth status` must report `loggedIn` true.
- `codex`: type `/hooks`, then review and trust the two portable hooks. Run one test turn, then exit. Step 3 of
  [Then, by hand](#then-by-hand) checks this test turn.

```bash
# 4. agents, Codex hooks and logins
curl -fsSL https://claude.ai/install.sh | bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
cmux hooks codex install --yes
xargs -n1 code --install-extension < ~/repos/workgrove/vscode/extensions.txt
gh auth login --web --git-protocol https
az login          # Azure: skip unless you installed azure-cli; see docs/azml-compute.md
claude auth login # browser login; claude auth status must report loggedIn true
codex login
codex             # /hooks -> review and trust the two portable hooks, run one test turn, then exit
```

`cmux hooks codex install --yes` merges cmux's generated Codex lifecycle handlers into `~/.codex/hooks.json`,
next to the portable ones. It is a Mac-only step. Run it again after every `install.sh --refresh-config`.

## Then, by hand

1. Paste the keys from [../vscode/settings-snippet.jsonc](../vscode/settings-snippet.jsonc) into VS Code
   Settings (JSON). Settings Sync carries them to your other machines. Give
   `remote.SSH.remotePlatform` one entry for each VM alias.
2. Open cmux. The ⌃⌥⌘T and ⌃⌥⌘D hotkeys bind at app launch. So if cmux was already running, quit it and start it
   again. Check that the theme and sidebar look right. Then check the three hotkeys:
   - ⌃⌥⌘N types `wt new` into the current terminal.
   - ⌃⌥⌘T opens the task picker.
   - ⌃⌥⌘D opens the driver row.
3. Check that the Codex test turn from block 4 moved its row from `running` back to `idle`. If it stays
   `running`, run `cmux hooks codex install --yes` again and try another turn.
4. Write `~/.ssh/config` from [ssh-config.example](ssh-config.example), one block for each VM. This file is yours
   and is never versioned.
5. Clone a repo into `~/Documents/Repositories` and start a task: type a brief into the cmux TextBox and
   press ⏎. You get a row titled `<name>` with `@local · <repo>` on its second line.
