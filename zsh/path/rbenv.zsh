# rbenv
export RBENV_ROOT=$HOME/.rbenv
add-path "$RBENV_ROOT/bin"
if [[ -x $RBENV_ROOT/bin/rbenv ]]; then
  eval "$("$RBENV_ROOT/bin/rbenv" init - zsh)"
elif [[ ! -f $HOME/.lp-norbenv ]]; then
  puts-err "rbenv is not installed. To silence, touch \$HOME/.lp-norbenv." >&2
fi
