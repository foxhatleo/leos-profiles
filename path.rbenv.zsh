RBENV_BIN_PATH="${HOME}/.rbenv/bin"
add-path "$RBENV_BIN_PATH";

if type "rbenv" > /dev/null; then
  eval "$(rbenv init -)";
else
  if [ ! -f $HOME/.lp-norbenv ]; then
    puts-err "rbenv is not installed. To silence, touch \$HOME/.lp-norbenv.";
  fi
fi
