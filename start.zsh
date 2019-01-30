function entry () { source "$HOME/.zsh_profiles/$1.zsh" }

entry "oh-my-zsh"
entry "term"

if [[ -e "$HOME/.zsh_profiles/ssh-shortcuts.zsh" ]]; then
  entry "ssh-shortcuts"
fi

entry "path.brew"
entry "path.rbenv"
entry "path.thefuck"
entry "path.wine"
entry "path.powerline"
entry "path.opam"

entry "command"
entry "command.macos"
entry "command.linux"
entry "command.shopify"
