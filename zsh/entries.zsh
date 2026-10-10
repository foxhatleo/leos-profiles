# Leo's Profiles — entries: ordered PATH, environment and command loader.

entry "path/brew"
entry "path/gnu"
# add-path prepends, so PATH order is the reverse of load order: user-local bins
# are loaded here, BEFORE the version managers below, so their shims end up in
# front. Otherwise a stale node/python/ruby left in ~/.local/bin permanently
# shadows whatever fnm/pyenv/rbenv selected, defeating per-directory switching.
entry "path/bin"
entry "path/apt"
entry "path/dnf"
entry "path/pacman"
entry "path/node"
entry "path/pyenv"
entry "path/rbenv"
entry "path/fnm"
entry "path/direnv"
entry "path/go"
entry "path/flutter"
entry "path/thefuck"
entry "path/gcloud"
entry "path/gpg"

# Load aliases and completion styles only after PATH initialisation, so tools
# discovered by Homebrew/local-bin setup are available to env.zsh.
entry "env"

entry "commands"

# local/private.zsh, the interactive layer and local/private-interactive.zsh
# are loaded by start.zsh after this file returns: private files must be
# sourced at top level, not inside `entry`, so their declarations stay global.

:
