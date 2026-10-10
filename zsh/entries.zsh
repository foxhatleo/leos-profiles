# Leo's Profiles — entries: ordered PATH, environment and command loader.

# Fewer fpath entries mean fewer directories for compinit to scan, and a
# nested shell inherits FPATH from brew shellenv: keep the array unique.
typeset -gU fpath

entry "path/brew"
entry "path/gnu"
# add-path prepends, so PATH order is the reverse of load order. The resulting
# precedence is: version-manager shims, then ~/.local/bin, then Go workspace
# bins, then Homebrew and the system.
#
# Go loads right after Homebrew (which usually provides the go binary): a
# GOPATH bin is a user-local install location like ~/.local/bin, and must not
# shadow the runtimes the version managers below select.
entry "path/go"
# User-local bins load BEFORE the version managers below, so their shims end up
# in front. Otherwise a stale node/python/ruby left in ~/.local/bin permanently
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
entry "path/gpg"

# Tool init scripts assign PATH directly; drop any duplicates they introduced.
typeset -gU path
path=($path)

# Load aliases and completion styles only after PATH initialisation, so tools
# discovered by Homebrew/local-bin setup are available to env.zsh.
entry "env"

entry "commands"

# local/private.zsh, the interactive layer and local/private-interactive.zsh
# are loaded by start.zsh after this file returns: private files must be
# sourced at top level, not inside `entry`, so their declarations stay global.

:
