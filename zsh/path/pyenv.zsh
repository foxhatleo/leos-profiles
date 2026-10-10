# pyenv
export PYENV_ROOT=${PYENV_ROOT:-$HOME/.pyenv}
add-path "$PYENV_ROOT/bin"
# The installer's checkout is found by path, which costs no lookup; otherwise
# a pyenv installed elsewhere on PATH (e.g. Homebrew) is found through
# $commands. That lookup rebuilds zsh's command table after the PATH edits
# above, so it is only made when the cheap test fails (PERF-9).
if [[ -x $PYENV_ROOT/bin/pyenv && ! -d $PYENV_ROOT/bin/pyenv ]]; then
  typeset -g __leos_pyenv_bin=$PYENV_ROOT/bin/pyenv
elif (( $+commands[pyenv] )); then
  typeset -g __leos_pyenv_bin=$commands[pyenv]
else
  typeset -g __leos_pyenv_bin=
fi

# Drop the `source .../completions/pyenv.zsh` line from the init script. That
# file registers an old-style `compctl` completion, and loading the compctl
# module costs about 8 ms on every shell; zsh/completions/_pyenv provides the
# same completion through compsys, loaded only when first used.
__leos_pyenv_init_filter() {
  emulate -L zsh
  local -a lines=("${(@f)REPLY}")
  REPLY=${(F)lines:#source *completions/pyenv.zsh*}
}

if [[ -n $__leos_pyenv_bin ]]; then
  # --no-rehash keeps the ~150ms synchronous shim rewrite out of startup;
  # __leos_rehash_daily does it in the background instead (see cache.zsh).
  # --no-push-path replaces pyenv's PATH rewrite, which forks a bash process
  # on every shell, with a guarded prepend; the line below then moves the
  # shims to the front in-process, which is what pyenv's own rewrite did.
  __leos_init_filter=__leos_pyenv_init_filter leos-source-cached-warn \
    "pyenv init produced no output; pyenv shims may be missing from PATH." \
    pyenv-init $__leos_pyenv_bin init --no-rehash --no-push-path - zsh
  path=("$PYENV_ROOT/shims" ${path:#${(b)PYENV_ROOT}/shims})
  __leos_rehash_daily pyenv
elif [[ ${LEOS_WARN_OPTIONAL_TOOLS:-0} == 1 && ! -f $LEOS_PROFILES/local/flags/no-pyenv ]]; then
  puts-err "pyenv is not installed. To silence, touch \$LEOS_PROFILES/local/flags/no-pyenv." >&2
fi
unset __leos_pyenv_bin

:
