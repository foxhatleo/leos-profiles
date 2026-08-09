# direnv — per-directory environment loader (authorizes and runs .envrc)
# The hook script is deterministic, so it is cached rather than regenerated.
(( $+commands[direnv] )) && leos-source-cached direnv-hook $commands[direnv] hook zsh

:
