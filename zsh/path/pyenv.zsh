# pyenv
export PYENV_ROOT=$HOME/.pyenv
add-path "$PYENV_ROOT/bin"
if [[ -x $PYENV_ROOT/bin/pyenv ]]; then
  eval "$("$PYENV_ROOT/bin/pyenv" init - zsh)"
elif [[ ! -f $HOME/.lp-nopyenv ]]; then
  puts-err "pyenv is not installed. To silence, touch \$HOME/.lp-nopyenv." >&2
fi
