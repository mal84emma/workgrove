# workstation essentials only. Personal tools stay out; .zshrc guards whatever you add yourself.
# azure-cli: needed only by bin/azml-ssh-host, which puts Azure ML compute instances in ~/.ssh/config
# (and for ad-hoc data access). Nothing else here uses it, and it drags in its own Python and a large
# dependency tree, so it is off by default: uncomment it, or `brew install azure-cli` when you want it.
# azml-ssh-host already says so itself — it errors clearly when `az` is not on PATH.
# brew "azure-cli"
brew "fzf"
brew "gh"
brew "jq"
# shellcheck: lints bin/* and the shell in install.sh; nothing here runs it for you yet.
brew "shellcheck"

cask "cmux"
cask "visual-studio-code"
# git-credential-manager: the `manager` helper docs/new-mac.md sets for non-GitHub hosts
# (e.g. Azure DevOps). GitHub goes through `!gh auth git-credential` in home/.gitconfig.
cask "git-credential-manager"
