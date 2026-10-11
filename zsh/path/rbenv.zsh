# rbenv
export RBENV_ROOT=${RBENV_ROOT:-$HOME/.rbenv}
add-path "$RBENV_ROOT/bin"
# The installer's checkout is found by path; otherwise an rbenv elsewhere on
# PATH (e.g. Homebrew). See entries.zsh for why `whence -p`, not $+commands.
if [[ -x $RBENV_ROOT/bin/rbenv && ! -d $RBENV_ROOT/bin/rbenv ]]; then
  typeset -g __leos_rbenv_bin=$RBENV_ROOT/bin/rbenv
elif whence -p rbenv >/dev/null; then
  typeset -g __leos_rbenv_bin=$commands[rbenv]
else
  typeset -g __leos_rbenv_bin=
fi

if [[ -n $__leos_rbenv_bin ]]; then
  # rbenv ships completions/_rbenv but never puts it on fpath, so rbenv had no
  # tab completion at all. fpath additions belong here: compinit runs later.
  [[ ! -d $RBENV_ROOT/completions ]] || fpath=("$RBENV_ROOT/completions" $fpath)
  # --no-rehash plus a throttled background rehash; see path/pyenv.zsh. Unlike
  # pyenv, `rbenv init - zsh` prepends its shims without forking and sources no
  # compctl completion, so its output is cached as is.
  leos-source-cached-warn "rbenv init produced no output; rbenv shims may be missing from PATH." \
    rbenv-init $__leos_rbenv_bin init --no-rehash - zsh
  __leos_rehash_daily rbenv
elif [[ ${LEOS_WARN_OPTIONAL_TOOLS:-0} == 1 && ! -f $LEOS_PROFILES/local/flags/no-rbenv ]]; then
  puts-err "rbenv is not installed. To silence, touch \$LEOS_PROFILES/local/flags/no-rbenv." >&2
fi
unset __leos_rbenv_bin

:
