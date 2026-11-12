# pyenv. The installer no longer installs it (uv's CPython in ~/.local/bin is
# the profile's Python since 2026-11), but an existing one keeps working: its
# shims then come before uv's python3, as before.
export PYENV_ROOT=${PYENV_ROOT:-$HOME/.pyenv}
__leos_add_path "$PYENV_ROOT/bin"
# The installer's checkout is found by path; otherwise a pyenv elsewhere on
# PATH (e.g. Homebrew). See entries.zsh for why `whence -p`, not $+commands.
if [[ -x $PYENV_ROOT/bin/pyenv && ! -d $PYENV_ROOT/bin/pyenv ]]; then
  typeset -g __leos_pyenv_bin=$PYENV_ROOT/bin/pyenv
elif whence -p pyenv >/dev/null; then
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
  # `pyenv` is only a dispatcher: the script comes from libexec/pyenv-init
  # beside the resolved launcher, so that file's stat is part of the identity.
  __leos_init_deps=${__leos_pyenv_bin:A:h}/pyenv-init \
  __leos_init_filter=__leos_pyenv_init_filter leos-source-cached-warn \
    "pyenv init produced no output; pyenv shims may be missing from PATH." \
    pyenv-init $__leos_pyenv_bin init --no-rehash --no-push-path - zsh
  path=("$PYENV_ROOT/shims" ${path:#${(b)PYENV_ROOT}/shims})
  __leos_rehash_daily pyenv
fi
# No LEOS_WARN_OPTIONAL_TOOLS warning without pyenv: the installer no longer
# provides it, so a missing pyenv is the expected state.
unset __leos_pyenv_bin

:
