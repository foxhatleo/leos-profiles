if type "thefuck" > /dev/null; then
  eval $(thefuck --alias)
else
  if [ ! -f $HOME/.zp-nofuck ]; then
    puts-err "thefuck is not installed. To silence, touch \$HOME/.zp-nofuck.";
  fi
fi
