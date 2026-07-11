# Homebrew

if __leos_brew_bin_path=$(__leos_brew_bin); then
  add-path "$(dirname "$__leos_brew_bin_path")"
  eval "$("$__leos_brew_bin_path" shellenv)"

  if [[ -f $LEOS_PROFILES/local/flags/brew-china ]]; then
    export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
    export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
  fi

  brew-checkup() {
    brew update && brew upgrade && brew upgrade --cask && brew cleanup -s
  }

  brew-china-enable() {
    local answer
    if (( $# > 1 )) || [[ $# == 1 && $1 != --yes ]]; then
      puts-err "Usage: brew-china-enable [--yes]"; return 2
    fi
    if [[ ${1:-} != --yes ]]; then
      puts-err "This routes Homebrew metadata and bottles through the third-party USTC mirror."
      read -r "answer?Enable it? [y/N] "
      [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { puts "Cancelled."; return 1; }
    fi
    export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
    export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
    if brew update; then
      mkdir -p "$LEOS_PROFILES/local/flags" && chmod 700 "$LEOS_PROFILES/local" "$LEOS_PROFILES/local/flags"
      touch "$LEOS_PROFILES/local/flags/brew-china" && chmod 600 "$LEOS_PROFILES/local/flags/brew-china"
    else
      unset HOMEBREW_BREW_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN
      return 1
    fi
  }

  brew-china-disable() {
    rm -f "$LEOS_PROFILES/local/flags/brew-china"
    unset HOMEBREW_BREW_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN
    command git -C "$(brew --repo)" remote set-url origin https://github.com/Homebrew/brew.git || return 1
    brew update
  }
else
  if [[ $(uname -s) == Darwin && ! -f $LEOS_PROFILES/local/flags/no-brew ]]; then
    puts-err "brew is not installed. To silence, touch \$LEOS_PROFILES/local/flags/no-brew."
  fi
fi

unset __leos_brew_bin_path

:
