# pyenv
export PYENV_ROOT=$HOME/.pyenv
add-path "$PYENV_ROOT/bin"
# PATH-wide detection (mirrors fish `type -q pyenv`): finds a pyenv under
# $PYENV_ROOT/bin OR one installed elsewhere on PATH (e.g. Homebrew).
# $commands[] resolves an external command's path without forking a subshell,
# unlike $(command -v pyenv), and is exactly the "real pyenv on PATH" test here.
if (( $+commands[pyenv] )); then
  # --no-rehash keeps the ~150ms synchronous shim rewrite out of startup;
  # __leos_rehash_daily does it in the background instead (see start.zsh).
  leos-source-cached pyenv-init $commands[pyenv] init --no-rehash - zsh ||
    puts-err "pyenv init produced no output; pyenv shims may be missing from PATH."
  __leos_rehash_daily pyenv
elif [[ ${LEOS_WARN_OPTIONAL_TOOLS:-0} == 1 && ! -f $LEOS_PROFILES/local/flags/no-pyenv ]]; then
  puts-err "pyenv is not installed. To silence, touch \$LEOS_PROFILES/local/flags/no-pyenv." >&2
fi

:
