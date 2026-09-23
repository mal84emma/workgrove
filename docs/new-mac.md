# Set up a new Mac

About 30 minutes, most of it downloads and logins. Run the blocks in order: block 3 asks for the author's own
config with `--opinionated-config`, so it needs oh-my-zsh and a git identity: `install.sh` insists on the
identity always, and on oh-my-zsh whenever that config's `~/.zshrc` is asked for.

```bash
# 1. Command Line Tools (wait for the installer if it opens; re-run until it prints a path)
xcode-select -p >/dev/null 2>&1 || xcode-select --install
```

```bash
# 2. Homebrew, repo, essentials, oh-my-zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
mkdir -p ~/repos && git clone https://github.com/mal84emma/workgrove ~/repos/workgrove
brew bundle --file ~/repos/workgrove/Brewfile
[ -f ~/.oh-my-zsh/oh-my-zsh.sh ] || sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

If Homebrew is already installed for the whole machine, for example in a second account on the same Mac, skip
the first line of this block and start at `eval "$(...brew shellenv)"`.

One line in the `Brewfile` is commented out: `brew "azure-cli"`. `bin/azml-ssh-host` is the only thing in
this repo that needs it, so `brew bundle` leaves it out of a machine that will never touch Azure. If you do
want it — the `az login` in block 4 and [azml-compute.md](azml-compute.md) both do — uncomment that line
before running `brew bundle`, or install it on its own at any time with `brew install azure-cli`.

```bash
# 3. identity, install   (edit GIT_NAME / GIT_EMAIL first)
git config --file ~/.gitconfig.local user.name  'GIT_NAME'
git config --file ~/.gitconfig.local user.email 'GIT_EMAIL'
git config --file ~/.gitconfig.local core.editor 'code --wait'
# optional: a credential helper for another git host, e.g. Azure DevOps
# git config --file ~/.gitconfig.local credential.https://dev.azure.com.helper manager
# optional: repos in more than one folder (searched in order; the file is never versioned)
# echo 'export WT_REPOS_DIR="$HOME/work/repos:$HOME/Documents/Repositories"' >> ~/.zshenv.local
bash ~/repos/workgrove/install.sh --opinionated-config
exec zsh -l     # separate line on purpose: chained with && it is skipped whenever install.sh exits non-zero
```

`--opinionated-config` is what asks for the seven pieces that are the author's taste rather than machinery: the
six files — `~/.zshrc` (with the oh-my-zsh theme), `~/.gitconfig`, `~/.tmux.conf`, the Claude keymap, the
status line and cmux's own `cmux.json` — and the `tui`, `voice` and `theme` keys of `~/.claude/settings.json`,
a file that is installed either way for its hooks and permissions. A bare `install.sh` installs the machinery
and leaves all seven alone, which is what a stranger cloning this repo gets; the README's Install section has
the per-flag detail and what arrives instead. For the six files the flag never has to be repeated: once they are links into this
repo, a later bare run — `wt update`'s, for instance — keeps them. The UI keys are remembered by the copy
itself: a `~/.claude/settings.json` that already carries a top-level `tui` key came from a run that was given
the flag, so a later `--refresh-config` keeps those keys rather than stripping them.

`install.sh` prints one line per file it links or installs and says where it put anything it moved out of the
way. Rerun it whenever the repo changes. It refuses before touching anything if a git identity is missing, or,
because this page installs `~/.zshrc`, if oh-my-zsh is missing, so a run that stops early has changed nothing.
Its last step clones the two zsh plugins `~/.zshrc` enables (`zsh-autosuggestions`, `zsh-syntax-highlighting`)
into `~/.oh-my-zsh/custom/plugins/`, which is the one step that needs the network; everything before it is
local. Both the prerequisite and the clone belong to that `~/.zshrc` alone, so without it neither applies.

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
