# Leo's zsh Profiles
# thefuck
#
# This script sets up thefuck if present.

if command -v thefuck &> /dev/null; then
  eval $(thefuck --alias)
else
  if [ ! -f $HOME/.lp-nofuck ]; then
    puts-err "thefuck is not installed. To silence, touch \$HOME/.lp-nofuck."
  fi
fi
