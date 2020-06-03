if type "brew" > /dev/null; then
  export PATH="/usr/local/sbin:$PATH";
  if [[ -f "$HOME/.brew-china" ]]; then
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles";
  fi
  brew-checkup() {
    brew update ;
    HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade ;
    HOMEBREW_NO_AUTO_UPDATE=1 brew cask upgrade ;
    brew cleanup -s ;
    # brew doctor ;
  }
  brew-china-enable() {
    git -C "$(brew --repo)" remote set-url origin https://mirrors.ustc.edu.cn/brew.git;
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-core" remote set-url origin https://mirrors.ustc.edu.cn/homebrew-core.git;
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-cask" remote set-url origin https://mirrors.ustc.edu.cn/homebrew-cask.git;
    touch "$HOME/.brew-china";
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles";
    brew update;
  }
  brew-china-disable() {
    git -C "$(brew --repo)" remote set-url origin https://github.com/Homebrew/brew.git;
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-core" remote set-url origin https://github.com/Homebrew/homebrew-core.git;
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-cask" remote set-url origin https://github.com/Homebrew/homebrew-cask.git;
    rm -f "$HOME/.brew-china";
    unset HOMEBREW_BOTTLE_DOMAIN;
    brew update;
  }
else
  if [[ "$OSTYPE" == "darwin"* ]] && [ ! -f $HOME/.zp-nobrew ]; then
    puts-err "brew is not installed. To silence, touch \$HOME/.zp-nobrew.";
  fi
fi
