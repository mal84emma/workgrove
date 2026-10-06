# workgrove essentials only. Personal tools stay out, and .zshrc guards whatever you add yourself.
# azure-cli: needed only by bin/azml-ssh-host (which puts Azure ML compute instances in ~/.ssh/config)
# and for ad-hoc data access. Nothing else here uses it, and it brings its own Python and a large
# dependency tree, so it is off by default. When you want it, uncomment its brew line or run
# `brew install azure-cli`.
# azml-ssh-host also tells you this: it gives a clear error when `az` is not on PATH.
# brew "azure-cli"
brew "fzf"
brew "gh"
brew "jq"
# shellcheck: lints bin/* and the shell in install.sh. Nothing here runs it for you yet.
brew "shellcheck"

cask "cmux"
cask "visual-studio-code"
# git-credential-manager: the `manager` helper that docs/new-mac.md sets for non-GitHub hosts
# (for example, Azure DevOps). GitHub goes through `!gh auth git-credential` in home/.gitconfig.
cask "git-credential-manager"
