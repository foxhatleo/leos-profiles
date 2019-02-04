if type "brew" > /dev/null; then
  export PATH="/usr/local/sbin:$PATH"
  
  brew-checkup() {
    brew update ;
    brew upgrade ;
    brew cask upgrade ;
    brew cleanup -s ;
    brew doctor ;
  }
fi
