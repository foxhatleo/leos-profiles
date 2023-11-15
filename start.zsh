# Leo's zsh Profiles
# Starting point script
#
# This script adds basic utility functions, and loads "entries.zsh".

puts () {
  echo "$(tput setaf 4 bold)===>$(tput sgr0)$(tput bold) $1$(tput sgr0)"
}

puts-err () {
  echo "$(tput setaf 1 bold)===>$(tput sgr0)$(tput bold) $1$(tput sgr0)"
}

add-path() {
  if [ -d $1 ]; then
    export PATH="$1:$PATH"
  elif [[ "$2" == "required" ]]; then
    puts-err "$1 is not found."
    return false
  fi
  return true
}

LEOS_PROFILES=$HOME/.leos-profiles

entry () {
  if [ -e "$LEOS_PROFILES/$1.zsh" ]; then
    source "$LEOS_PROFILES/$1.zsh"
  elif ! [ "$2" = "optional" ]; then
    puts-err "$1 is not found. Check $LEOS_PROFILES/entries.zsh."
  fi
}

entry "entries"
