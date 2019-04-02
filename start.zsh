puts () {
  echo "$(tput setaf 4 bold)===>$(tput sgr0)$(tput bold) $1$(tput sgr0)";
}

puts-err () {
  echo "$(tput setaf 1 bold)===>$(tput sgr0)$(tput bold) $1$(tput sgr0)";
}

LEOS_PROFILES=$HOME/.leos-profiles

if ! [ -d $ZSH ]; then
  puts-err "$LEO_PROFILES is not found!";
fi

entry () {
  if [ -e "$LEOS_PROFILES/$1.zsh" ]; then
    source "$LEOS_PROFILES/$1.zsh"
  elif ! [ "$2" = "optional" ]; then
    puts-err "$1 is not found. Check $LEOS_PROFILES/entries.zsh."
  fi
}

entry "entries"
