if type "brew" > /dev/null; then
  export PATH="/usr/local/sbin:$PATH"

  brew-checkup() {
    brew update ;
    brew upgrade ;
    brew cask upgrade ;
    brew cleanup -s ;
    brew doctor ;
  }
else
  if [[ "$OSTYPE" == "darwin"* ]] && [ ! -f $HOME/.zp-nobrew ]; then
    puts-err "brew is not installed. To silence, touch \$HOME/.zp-nobrew.";
  fi
fi
