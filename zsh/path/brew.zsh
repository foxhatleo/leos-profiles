# Homebrew

if __leos_brew_bin_path=$(__leos_brew_bin); then
  add-path "${__leos_brew_bin_path:h}"
  # `brew shellenv` costs ~20ms per shell for deterministic output; cache it.
  # Its embedded path_helper call still runs at source time, as it must.
  leos-source-cached-warn "brew shellenv produced no output; Homebrew paths may be missing." \
    brew-shellenv "$__leos_brew_bin_path" shellenv

  # Single definition of the mirror endpoints, used both by the startup block
  # below and by brew-china-enable, so the two cannot drift apart.
  __leos_brew_china_export() {
    export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
    export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
  }

  if [[ -f $LEOS_PROFILES/local/flags/brew-china ]]; then
    __leos_brew_china_export
  fi

  brew-checkup() {
    brew update && brew upgrade && brew upgrade --cask && brew cleanup -s || return 1
    # A brew upgrade can rewrite a tool's init logic (brew's own shellenv.sh,
    # starship, direnv, zoxide) without touching the launcher the init cache is
    # keyed on, so drop the cache here rather than leaving a stale copy behind.
    (( $+functions[leos-refresh-init-cache] )) && leos-refresh-init-cache
    return 0
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
    # Save prior values so a failed enable restores instead of clobbering
    # mirror env that startup legitimately exported from the flag file.
    local had_remote=$+HOMEBREW_BREW_GIT_REMOTE prev_remote=${HOMEBREW_BREW_GIT_REMOTE:-}
    local had_bottle=$+HOMEBREW_BOTTLE_DOMAIN  prev_bottle=${HOMEBREW_BOTTLE_DOMAIN:-}
    local had_api=$+HOMEBREW_API_DOMAIN        prev_api=${HOMEBREW_API_DOMAIN:-}
    __leos_brew_china_export
    if brew update; then
      mkdir -p "$LEOS_PROFILES/local/flags" && chmod 700 "$LEOS_PROFILES/local" "$LEOS_PROFILES/local/flags"
      touch "$LEOS_PROFILES/local/flags/brew-china" && chmod 600 "$LEOS_PROFILES/local/flags/brew-china"
    else
      (( had_remote )) && export HOMEBREW_BREW_GIT_REMOTE=$prev_remote || unset HOMEBREW_BREW_GIT_REMOTE
      (( had_bottle )) && export HOMEBREW_BOTTLE_DOMAIN=$prev_bottle   || unset HOMEBREW_BOTTLE_DOMAIN
      (( had_api ))    && export HOMEBREW_API_DOMAIN=$prev_api         || unset HOMEBREW_API_DOMAIN
      return 1
    fi
  }

  brew-china-disable() {
    rm -f "$LEOS_PROFILES/local/flags/brew-china"
    unset HOMEBREW_BREW_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN
    command git -C "$(brew --repo)" remote set-url origin https://github.com/Homebrew/brew.git || return 1
    # The pre-env-var implementation of brew-china-enable rewrote tap
    # remotes; reset them too so disable fully undoes an old enable.
    local _leos_tap_path
    _leos_tap_path=$(brew --repository homebrew/core 2>/dev/null)
    if [[ -n $_leos_tap_path ]] && command git -C "$_leos_tap_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      command git -C "$_leos_tap_path" remote set-url origin https://github.com/Homebrew/homebrew-core.git || return 1
    fi
    _leos_tap_path=$(brew --repository homebrew/cask 2>/dev/null)
    if [[ -n $_leos_tap_path ]] && command git -C "$_leos_tap_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      command git -C "$_leos_tap_path" remote set-url origin https://github.com/Homebrew/homebrew-cask.git || return 1
    fi
    brew update
  }
else
  if [[ $OSTYPE == darwin* && ! -f $LEOS_PROFILES/local/flags/no-brew ]]; then
    puts-err "brew is not installed. To silence, touch \$LEOS_PROFILES/local/flags/no-brew."
  fi
fi

unset __leos_brew_bin_path

:
