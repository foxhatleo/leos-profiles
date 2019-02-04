puts () {
  echo "$(tput setaf 4 bold)===>$(tput sgr0)$(tput bold) $1$(tput sgr0)";
}

puts-err () {
  echo "$(tput setaf 1 bold)===>$(tput sgr0)$(tput bold) $1$(tput sgr0)";
}

entry () {
  if [ -e "$HOME/.zsh_profiles/$1.zsh" ]; then
    source "$HOME/.zsh_profiles/$1.zsh"
  elif ! [ "$2" = "optional" ]; then
    puts-err "$1 is not found. Check ~/.zsh_profiles/start.zsh."
  fi
}
