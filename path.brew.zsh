# Leo's zsh Profiles
# Homebrew
#
# This script adds useful commands if Homebrew is present.

if command -v brew &> /dev/null; then
  eval "$(brew shellenv)"
  source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
  source /opt/homebrew/share/zsh-history-substring-search/zsh-history-substring-search.zsh
  source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

  if [[ -f "$HOME/.brew-china" ]]; then
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
  fi

  brew-checkup() {
    brew update 
    brew upgrade 
    brew upgrade --cask 
    brew cleanup -s 
    # brew doctor 
  }

  brew-china-enable() {
    git -C "$(brew --repo)" remote set-url origin https://mirrors.ustc.edu.cn/brew.git
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-core" remote set-url origin https://mirrors.ustc.edu.cn/homebrew-core.git
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-cask" remote set-url origin https://mirrors.ustc.edu.cn/homebrew-cask.git
    touch "$HOME/.brew-china"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
    brew update
  }

  brew-china-disable() {
    git -C "$(brew --repo)" remote set-url origin https://github.com/Homebrew/brew.git
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-core" remote set-url origin https://github.com/Homebrew/homebrew-core.git
    git -C "$(brew --repo)/Library/Taps/homebrew/homebrew-cask" remote set-url origin https://github.com/Homebrew/homebrew-cask.git
    rm -f "$HOME/.brew-china"
    unset HOMEBREW_BOTTLE_DOMAIN
    brew update
  }
  
else
  if [[ "$OSTYPE" == "darwin"* ]] && [ ! -f $HOME/.lp-nobrew ]; then
    puts-err "brew is not installed. To silence, touch \$HOME/.lp-nobrew."
  fi
fi
