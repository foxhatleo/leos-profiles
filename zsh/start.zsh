# Leo's Profiles — starting point (zsh)
# Defines helper functions and loads zsh/entries.zsh.

puts()     { print -Pn "%B%F{blue}===>%f%b "; print -r -- "$*"; }
puts-err() { print -Pn "%B%F{red}===>%f%b " >&2; print -r -- "$*" >&2; }

# Prepend $1 to PATH (dedup, move-to-front) if it is a real dir.
# add-path <dir> [required]  — with "required", warn + return 1 when missing.
add-path() {
  local dir=$1 mode=$2
  if [[ -d $dir ]]; then
    path=("$dir" ${path:#$dir})
    typeset -gU path
    return 0
  elif [[ $mode == required ]]; then
    puts-err "$dir is not found."
    return 1
  fi
  return 0
}

__leos_brew_bin() {
  if command -v brew >/dev/null 2>&1; then command -v brew; return 0; fi
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew "$HOME/.linuxbrew/bin/brew" /home/linuxbrew/.linuxbrew/bin/brew; do
    [[ -x $b ]] && { print -r -- "$b"; return 0; }
  done
  return 1
}

__leos_brew_prefix() {
  local b; b=$(__leos_brew_bin) || return 1
  "$b" --prefix
}

# Shell-internal (not exported into child environments — matches fish's `set`).
# Prefer an explicit override, otherwise derive the root from this sourced file.
# This keeps ~/.leos-profiles as the installer default without requiring it.
typeset -g __leos_start_file="${(%):-%N}"
typeset -g LEOS_PROFILES="${LEOS_PROFILES_HOME:-${__leos_start_file:A:h:h}}"
typeset -g LEOS_PROFILES_ZSH=$LEOS_PROFILES/zsh

# Source zsh/<name>.zsh; warn unless mode is "optional".
entry() {
  local name=$1 mode=$2
  if [[ -e $LEOS_PROFILES_ZSH/$name.zsh ]]; then
    source "$LEOS_PROFILES_ZSH/$name.zsh"
  elif [[ $mode != optional ]]; then
    puts-err "$name is not found. Check $LEOS_PROFILES_ZSH/entries.zsh."
  fi
}

entry entries
