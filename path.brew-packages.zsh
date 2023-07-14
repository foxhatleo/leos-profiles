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
