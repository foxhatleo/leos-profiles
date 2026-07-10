# Leo's Profiles — entries: ordered loader.

entry "path/brew"
entry "path/gnu"
entry "path/apt"
entry "path/dnf"
entry "path/pacman"
entry "path/node"
entry "path/pyenv"
entry "path/rbenv"
entry "path/fnm"
entry "path/direnv"
entry "path/zoxide"
entry "path/go"
entry "path/flutter"
entry "path/thefuck"
entry "path/gcloud"
entry "path/gpg"
entry "path/bin"

# Load aliases and completion styles only after PATH initialisation, so tools
# discovered by Homebrew/local-bin setup are available to env.zsh.
entry "env"

entry "commands"

# Private definitions load after the public command layer so a machine-specific
# override can intentionally replace a profile command or alias.
entry "_private" optional

entry "interactive"

:
