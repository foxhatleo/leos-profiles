if type "brew" > /dev/null; then
  add-path "/usr/local/opt/coreutils/libexec/gnubin" required
  add-path "/usr/local/opt/findutils/libexec/gnubin" required
  add-path "/usr/local/opt/gnu-sed/libexec/gnubin" required
  if add-path "/usr/local/opt/ruby/bin" required; then
    export LDFLAGS="-L/usr/local/opt/ruby/lib"
    export CPPFLAGS="-I/usr/local/opt/ruby/include"
    export PKG_CONFIG_PATH="/usr/local/opt/ruby/lib/pkgconfig"
  fi
fi
