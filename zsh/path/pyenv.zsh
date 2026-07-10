# pyenv
export PYENV_ROOT=$HOME/.pyenv
add-path "$PYENV_ROOT/bin"
# PATH-wide detection (mirrors fish `type -q pyenv`): finds a pyenv under
# $PYENV_ROOT/bin OR one installed elsewhere on PATH (e.g. Homebrew).
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init - zsh)"
elif [[ ${LEOS_WARN_OPTIONAL_TOOLS:-0} == 1 && ! -f $HOME/.lp-nopyenv ]]; then
  puts-err "pyenv is not installed. To silence, touch \$HOME/.lp-nopyenv." >&2
fi

:
