# rbenv
export RBENV_ROOT=$HOME/.rbenv
add-path "$RBENV_ROOT/bin"
# PATH-wide detection (mirrors fish `type -q rbenv`): finds an rbenv under
# $RBENV_ROOT/bin OR one installed elsewhere on PATH (e.g. Homebrew).
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - zsh)"
elif [[ ${LEOS_WARN_OPTIONAL_TOOLS:-0} == 1 && ! -f $LEOS_PROFILES/local/flags/no-rbenv ]]; then
  puts-err "rbenv is not installed. To silence, touch \$LEOS_PROFILES/local/flags/no-rbenv." >&2
fi

:
