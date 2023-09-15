if [ "$(arch)" = "arm64" ] && [ -d "/opt/homebrew/bin" ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ "$(arch)" = "i386" ] && [ -d "/usr/local/bin" ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

if (type "brew" > /dev/null) && [ "$(arch)" = "arm64" ]; then
  add-path "/opt/homebrew/opt/coreutils/libexec/gnubin" required
  add-path "/opt/homebrew/opt/findutils/libexec/gnubin" required
  add-path "/opt/homebrew/opt/gnu-sed/libexec/gnubin" required
  if add-path "/opt/homebrew/opt/ruby/bin" required; then
    add-path "/opt/homebrew/lib/ruby/gems/3.2.0/bin" required
    export LDFLAGS="-L/opt/homebrew/opt/ruby/lib $LDFLAGS"
    export CPPFLAGS="-I/opt/homebrew/opt/ruby/include $CPPFLAGS"
  fi
  add-path "/opt/homebrew/opt/ssh-copy-id/bin"
fi

if (type "brew" > /dev/null); then
  source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
  source $(brew --prefix)/share/zsh-history-substring-search/zsh-history-substring-search.zsh
  source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi