# Set up a new Mac

About 30 minutes, most of it downloads and logins. Run the blocks in order: block 3 needs oh-my-zsh and a git
identity, both of which `install.sh` insists on.

```bash
# 1. Command Line Tools (wait for the installer if it opens; re-run until it prints a path)
xcode-select -p >/dev/null 2>&1 || xcode-select --install
```

```bash
# 2. Homebrew, repo, essentials, oh-my-zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
mkdir -p ~/repos && git clone https://github.com/mal84emma/workstation ~/repos/workstation
brew bundle --file ~/repos/workstation/Brewfile
[ -f ~/.oh-my-zsh/oh-my-zsh.sh ] || sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

If Homebrew is already installed for the whole machine, for example in a second account on the same Mac, skip
the first line of this block and start at `eval "$(...brew shellenv)"`.

```bash
# 3. identity, install   (edit GIT_NAME / GIT_EMAIL first)
git config --file ~/.gitconfig.local user.name  'GIT_NAME'
git config --file ~/.gitconfig.local user.email 'GIT_EMAIL'
git config --file ~/.gitconfig.local core.editor 'code --wait'
git config --file ~/.gitconfig.local credential.https://dev.azure.com.helper manager   # drop if you do not use Azure DevOps
# optional: repos in more than one folder (searched in order; the file is never versioned)
# echo 'export WT_REPOS_DIR="$HOME/work/repos:$HOME/Documents/Repositories"' >> ~/.zshenv.local
bash ~/repos/workstation/install.sh && exec zsh -l
```

`install.sh` prints one line per file it links or installs and says where it put anything it moved out of the
way. Rerun it whenever the repo changes.

```bash
# 4. agents, Codex hooks and logins
curl -fsSL https://claude.ai/install.sh | bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
cmux hooks codex install --yes
xargs -n1 code --install-extension < ~/repos/workstation/vscode/extensions.txt
gh auth login --web --git-protocol https
az login          # Azure: data access and compute instances; see docs/azml-compute.md
claude auth login # browser login; claude auth status must report loggedIn true
codex login
codex             # /hooks -> review and trust the two portable hooks, run one test turn, then exit
```

`cmux hooks codex install --yes` merges cmux's generated Codex lifecycle handlers into `~/.codex/hooks.json`
next to the portable ones. It is a Mac-only step, and it has to be repeated after every
`install.sh --refresh-config`.

## Then, by hand

1. Paste the keys from [../vscode/settings-snippet.jsonc](../vscode/settings-snippet.jsonc) into VS Code
   Settings (JSON). Settings Sync carries them to your other machines. Give
   `remote.SSH.remotePlatform` one entry per VM alias.
2. Open cmux. Check the theme and sidebar look right, then check the three hotkeys: ⌃⌥⌘N types `wt new` into
   the current terminal, ⌃⌥⌘T opens the task picker, ⌃⌥⌘D opens the driver row. The T and D shortcuts bind at
   app launch, so if cmux was already running, quit it and start it again first.
3. Check that the Codex test turn from block 4 moved its row from `running` back to `idle`. If it stays
   `running`, run `cmux hooks codex install --yes` again and try another turn.
4. Write `~/.ssh/config` from [ssh-config.example](ssh-config.example), one block per VM. This file is yours
   and is never versioned.
5. Clone a repo into `~/Documents/Repositories` and start a task: type a brief into the cmux TextBox and
   press ⏎. You should get a row titled `<repo>:<name>` with `@local` on its second line.
