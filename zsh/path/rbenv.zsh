# rbenv
export RBENV_ROOT=$HOME/.rbenv
add-path "$RBENV_ROOT/bin"
# PATH-wide detection (mirrors fish `type -q rbenv`): finds an rbenv under
# $RBENV_ROOT/bin OR one installed elsewhere on PATH (e.g. Homebrew).
# See path/pyenv.zsh for why $commands[] is used instead of $(command -v ...).
if (( $+commands[rbenv] )); then
  # rbenv ships completions/_rbenv but never puts it on fpath, so rbenv had no
  # tab completion at all. fpath additions belong here: compinit runs later.
  [[ ! -d $RBENV_ROOT/completions ]] || fpath=("$RBENV_ROOT/completions" $fpath)
  # --no-rehash plus a throttled background rehash; see path/pyenv.zsh.
  leos-source-cached rbenv-init $commands[rbenv] init --no-rehash - zsh
  __leos_rehash_daily rbenv
elif [[ ${LEOS_WARN_OPTIONAL_TOOLS:-0} == 1 && ! -f $LEOS_PROFILES/local/flags/no-rbenv ]]; then
  puts-err "rbenv is not installed. To silence, touch \$LEOS_PROFILES/local/flags/no-rbenv." >&2
fi

:
