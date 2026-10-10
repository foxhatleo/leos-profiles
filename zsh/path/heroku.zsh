# Heroku CLI completions — loaded from interactive.zsh, AFTER compinit.
#
# install.sh installs heroku in the `network` package group but nothing ever
# wired up its completions. heroku is a Node CLI, so spawning it per shell is
# far too slow: the generator's output is cached like the others.
#
# The emitted snippet sources heroku's own zsh_setup, which extends fpath with
# heroku's `_heroku` and only runs compinit when compdef does not exist yet
# (older CLIs ran it unconditionally) — hence loading it after ours rather than
# during the PATH phase. That file is only built once `heroku autocomplete` has
# been run interactively; until then the snippet's own `test -f` makes it a
# no-op.
if (( $+commands[heroku] )); then
  # `|| true`, not the -warn form: heroku completions are optional enough that a
  # missing generator is not worth a startup message. The status must still be
  # consumed, or a non-zero return aborts this file under ERR_RETURN.
  leos-source-cached heroku-completion $commands[heroku] autocomplete:script zsh || true
  # Because current CLIs skip that compinit, nothing registers the `_heroku`
  # they just put on fpath. Register it here when it exists.
  if (( $+functions[compdef] && ! ${+_comps[heroku]} )); then
    () {
      emulate -L zsh
      local -a found=(${^fpath}/_heroku(N))
      (( $#found )) || return 0
      autoload -Uz _heroku && compdef _heroku heroku
    }
  fi
fi

:
