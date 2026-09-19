# Environment for every zsh (login, interactive and non-interactive).
# Machine-local additions go in ~/.zshenv.local (never versioned).

# Tools installed per user, incl. wt and the agent CLIs.
export PATH="$HOME/.local/bin:$PATH"

# gh: no interactive prompts in agent sessions.
export GH_PROMPT_DISABLED=1

# Rust toolchain, if installed.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Node toolchain, if installed.
[ -d "$HOME/.volta/bin" ] && export VOLTA_HOME="$HOME/.volta" PATH="$HOME/.volta/bin:$PATH"

if [ -f "$HOME/.zshenv.local" ]; then
  . "$HOME/.zshenv.local"
fi
