# direnv — per-directory environment loader (authorizes and runs .envrc)
# The hook script is deterministic, so it is cached rather than regenerated.
if (( $+commands[direnv] )); then
  leos-source-cached-warn "direnv hook produced no output; .envrc files will not load." \
    direnv-hook $commands[direnv] hook zsh
fi

:
