add-path() {
  if [ -d $1 ]; then
    export PATH="$1:$PATH"
    return true
  else
    puts-err "$1 is not found."
    return false
  fi
}

if type "brew" > /dev/null; then
  add-path "/usr/local/opt/coreutils/libexec/gnubin"
  add-path "/usr/local/opt/findutils/libexec/gnubin"
  add-path "/usr/local/opt/gnu-sed/libexec/gnubin"
  if add-path "/usr/local/opt/ruby/bin"; then
    export LDFLAGS="-L/usr/local/opt/ruby/lib"
    export CPPFLAGS="-I/usr/local/opt/ruby/include"
    export PKG_CONFIG_PATH="/usr/local/opt/ruby/lib/pkgconfig"
  fi
fi
