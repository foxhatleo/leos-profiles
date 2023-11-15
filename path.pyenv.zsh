# Leo's zsh Profiles
# pyenv
#
# This script sets up pyenv if present.

export PYENV_ROOT="$HOME/.pyenv"
add-path "$PYENV_ROOT/bin"

if command -v pyenv &> /dev/null; then
  eval "$(pyenv init --path)"
else
  if [ ! -f $HOME/.lp-nopyenv ]; then
    puts-err "pyenv is not installed. To silence, touch \$HOME/.lp-nopyenv."
  fi
fi