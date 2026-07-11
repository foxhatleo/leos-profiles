# GNU tools on macOS (replace BSD tools when enabled)

if [[ $(uname -s) == Darwin && ! -f $LEOS_PROFILES/local/flags/no-gnu ]] && __leos_gnu_prefix=${HOMEBREW_PREFIX:-$(__leos_brew_prefix)}; then
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
enable-gnu()  { rm -f "$LEOS_PROFILES/local/flags/no-gnu"; puts "Enabled GNU tools. Restart shell to take effect."; }
disable-gnu() { mkdir -p "$LEOS_PROFILES/local/flags" && chmod 700 "$LEOS_PROFILES/local" "$LEOS_PROFILES/local/flags"; touch "$LEOS_PROFILES/local/flags/no-gnu" && chmod 600 "$LEOS_PROFILES/local/flags/no-gnu"; puts "Disabled GNU tools. Restart shell to take effect."; }

unset __leos_gnu_prefix

:
