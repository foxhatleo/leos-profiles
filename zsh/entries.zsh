# Leo's Profiles — entries: ordered PATH, environment and command loader.

# Fewer fpath entries mean fewer directories for compinit to scan, and a
# nested shell inherits FPATH from brew shellenv: keep the array unique.
typeset -gU fpath

# Entries test for tools with `whence -p tool >/dev/null`, then read the path
# from $commands[tool]. Like $+commands[tool], `whence -p` ignores functions
# and aliases, but it searches PATH for that one name and hashes it, while
# $+commands fills zsh's whole command table (2-3 ms with Homebrew on PATH)
# whenever the name is not hashed yet, and every PATH edit empties the table
# again. Several fills per startup were measurable (PERF-9).

__leos_entry "path/brew"
__leos_entry "path/gnu"
# __leos_add_path prepends, so PATH order is the reverse of load order. The resulting
# precedence is: version-manager shims, then ~/.local/bin, then Go workspace
# bins, then Homebrew and the system.
#
# Go loads right after Homebrew (which usually provides the go binary): a
# GOPATH bin is a user-local install location like ~/.local/bin, and must not
# shadow the runtimes the version managers below select.
__leos_entry "path/go"
# User-local bins load BEFORE the version managers below, so their shims end up
# in front. Otherwise a node or ruby left in ~/.local/bin permanently shadows
# whatever fnm/rbenv selected, defeating per-directory switching. (uv's
# python3 lives there on purpose; an existing pyenv's shims still win.)
__leos_entry "path/bin"
__leos_entry "path/apt"
__leos_entry "path/dnf"
__leos_entry "path/pacman"
__leos_entry "path/node"
__leos_entry "path/pyenv"
__leos_entry "path/rbenv"
__leos_entry "path/fnm"
__leos_entry "path/direnv"
__leos_entry "path/gpg"

# Tool init scripts assign PATH directly; drop any duplicates they introduced.
typeset -gU path
path=($path)

# Load aliases and completion styles only after PATH initialisation, so tools
# discovered by Homebrew/local-bin setup are available to env.zsh.
__leos_entry "env"

__leos_entry "commands"

# local/private.zsh, the interactive layer and local/private-interactive.zsh
# are loaded by start.zsh after this file returns: private files must be
# sourced at top level, not inside `__leos_entry`, so their declarations stay global.

:
