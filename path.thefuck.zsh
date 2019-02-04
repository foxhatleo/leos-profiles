if type "thefuck" > /dev/null; then
  eval $(thefuck --alias)
else
  puts-err "thefuck is not installed."
fi
