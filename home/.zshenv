# Environment for every zsh: login, interactive, and non-interactive.
# Put machine-local additions in ~/.zshenv.local, which is never versioned.

# Tools installed per user, including wt and the agent CLIs.
export PATH="$HOME/.local/bin:$PATH"

# gh: no interactive prompts in agent sessions.
export GH_PROMPT_DISABLED=1

# Rust toolchain, if installed.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Node toolchain, if installed.
[ -d "$HOME/.volta/bin" ] && export VOLTA_HOME="$HOME/.volta" PATH="$HOME/.volta/bin:$PATH"

# cmux's Mac wrappers run these agent CLIs instead of searching PATH. A mise shim for a tool that no mise config
# activates falls back to the next one on PATH, the cmux wrapper. Without these paths, the two start each other
# in a loop. A value that is already set stays. ~/.zshenv.local, sourced below, can still replace either one.
if [ "$(uname -s)" = Darwin ]; then
  [ -z "${CMUX_CUSTOM_CODEX_PATH:-}" ] && [ -x "$HOME/.local/bin/codex" ] \
    && export CMUX_CUSTOM_CODEX_PATH="$HOME/.local/bin/codex"
  [ -z "${CMUX_CUSTOM_CLAUDE_PATH:-}" ] && [ -x "$HOME/.local/bin/claude" ] \
    && export CMUX_CUSTOM_CLAUDE_PATH="$HOME/.local/bin/claude"
fi

if [ -f "$HOME/.zshenv.local" ]; then
  . "$HOME/.zshenv.local"
fi
