# Homebrew

__leos_brew_set_remote() {
  local repo_path=$1 remote_url=$2 repo_label=$3
  if [[ -z $repo_path ]]; then
    puts "Skipping $repo_label; repository path is unavailable."; return 0
  fi
  if command git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    command git -C "$repo_path" remote set-url origin "$remote_url"; return $?
  fi
  puts "Skipping $repo_label; local git clone is not present."; return 0
}

if __leos_brew_bin_path=$(__leos_brew_bin); then
  add-path "$(dirname "$__leos_brew_bin_path")"
  eval "$("$__leos_brew_bin_path" shellenv)"

  [[ -f $HOME/.brew-china ]] && export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"

  brew-checkup() {
    brew update; brew upgrade; brew upgrade --cask; brew cleanup -s
  }

  brew-china-enable() {
    __leos_brew_set_remote "$(brew --repo)"                     https://mirrors.ustc.edu.cn/brew.git          "Homebrew/brew" || return 1
    __leos_brew_set_remote "$(brew --repository homebrew/core)" https://mirrors.ustc.edu.cn/homebrew-core.git "homebrew/core" || return 1
    __leos_brew_set_remote "$(brew --repository homebrew/cask)" https://mirrors.ustc.edu.cn/homebrew-cask.git "homebrew/cask" || return 1
    touch "$HOME/.brew-china"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
    brew update
  }

  brew-china-disable() {
    __leos_brew_set_remote "$(brew --repo)"                     https://github.com/Homebrew/brew.git          "Homebrew/brew" || return 1
    __leos_brew_set_remote "$(brew --repository homebrew/core)" https://github.com/Homebrew/homebrew-core.git "homebrew/core" || return 1
    __leos_brew_set_remote "$(brew --repository homebrew/cask)" https://github.com/Homebrew/homebrew-cask.git "homebrew/cask" || return 1
    rm -f "$HOME/.brew-china"
    unset HOMEBREW_BOTTLE_DOMAIN
    brew update
  }
else
  if [[ $(uname -s) == Darwin && ! -f $HOME/.lp-nobrew ]]; then
    puts-err "brew is not installed. To silence, touch \$HOME/.lp-nobrew."
  fi
fi
