# Leo's zsh Profiles
# GNU tools
#
# This script replaces BSD tools on macOS with GNU tools if enabled.

if [[ "$OSTYPE" == "darwin"* ]] && ! [ -f "$HOME/.lp-no-gnu" ]; then
  add-path "/opt/homebrew/opt/coreutils/libexec/gnubin"
  add-path "/opt/homebrew/opt/findutils/libexec/gnubin"
  add-path "/opt/homebrew/opt/gnu-indent/libexec/gnubin"
  add-path "/opt/homebrew/opt/gnu-sed/libexec/gnubin"
  add-path "/opt/homebrew/opt/grep/libexec/gnubin"
  add-path "/opt/homebrew/opt/gnu-tar/libexec/gnubin"
  add-path "/opt/homebrew/opt/gawk/libexec/gnubin"
  add-path "/opt/homebrew/opt/ed/libexec/gnubin"
  add-path "/opt/homebrew/opt/gnu-which/libexec/gnubin"
fi

enable-gnu() {
  rm "$HOME/.lp-no-gnu"
  puts "Enabled GNU tools. Restart shell to take effect."
}

disable-gnu() {
  touch "$HOME/.lp-no-gnu"
  puts "Disabled GNU tools. Restart shell to take effect."
}
