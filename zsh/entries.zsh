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

# Private definitions live outside version control and load after the public
# command layer so a machine-specific override can intentionally win.
if [[ -r $LEOS_PROFILES/local/private.zsh ]]; then
  # This file routinely holds API keys, and a group-traversable home (the macOS
  # default, where every local account is in staff) makes a permissive mode a
  # real exposure. Warn instead of rewriting it: the mode is the owner's call,
  # and the installer already enforces 600 on every apply.
  #
  # Checked inside an anonymous function so EXTENDED_GLOB — needed for the
  # (#q...) qualifiers, and normally set by env.zsh, which has not run yet —
  # stays local, and so the `source` below still sees the ambient option set
  # that a machine-specific override may depend on.
  () {
    emulate -L zsh
    setopt extended_glob
    local f=$LEOS_PROFILES/local/private.zsh
    [[ -n $f(#qNf:g+r:) || -n $f(#qNf:o+r:) ]] || return 0
    puts-err "$f is readable beyond its owner and usually holds secrets. Fix with: chmod 600 ${(q)f}"
  }
  source "$LEOS_PROFILES/local/private.zsh"
fi

entry "interactive"

:
