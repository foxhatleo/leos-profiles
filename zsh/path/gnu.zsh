# GNU tools on macOS (replace BSD tools when enabled)

if [[ $OSTYPE == darwin* && ! -f $LEOS_PROFILES/local/flags/no-gnu ]] && __leos_gnu_prefix=${HOMEBREW_PREFIX:-$(__leos_brew_prefix)}; then
  add-path "$__leos_gnu_prefix/opt/coreutils/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/findutils/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/gnu-indent/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/gnu-sed/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/grep/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/gnu-tar/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/gawk/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/ed/libexec/gnubin"
  add-path "$__leos_gnu_prefix/opt/gnu-which/libexec/gnubin"
fi

# Defined unconditionally (not gated on the block above) so disable-gnu's
# effect can always be undone with enable-gnu, even after a restart.
enable-gnu()  { __leos_clear_flag no-gnu && puts "Enabled GNU tools. Restart shell to take effect."; }
disable-gnu() { __leos_set_flag no-gnu && puts "Disabled GNU tools. Restart shell to take effect."; }

unset __leos_gnu_prefix

:
