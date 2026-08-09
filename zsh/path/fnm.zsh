# fnm — fast Node version manager with per-directory auto-switch
#
# ~/.local/bin (where the installer puts fnm) is added by path/bin.zsh, which
# loads earlier on purpose; re-adding it here would move it back in front of
# fnm's own shim directory and defeat per-directory switching.
if (( $+commands[fnm] )); then
  # NOT cached: `fnm env` mints a unique FNM_MULTISHELL_PATH per invocation, so
  # a cached copy would make every shell share one version-switching sandbox.
  # `--shell zsh` because fnm otherwise guesses from the parent process tree and
  # can fall back to POSIX output — which omits the zsh chpwd hook --use-on-cd
  # relies on — when zsh is started by something that is not a shell.
  eval "$(fnm env --use-on-cd --shell zsh)"
fi

:
