# Heroku CLI completions — loaded from interactive.zsh, AFTER compinit.
#
# install.sh installs heroku in the `network` package group but nothing ever
# wired up its completions. heroku is a Node CLI, so spawning it per shell is
# far too slow: the generator's output is cached like the others.
#
# The emitted snippet sources heroku's own zsh_setup, which runs its own compinit
# and extends fpath — hence loading it after ours rather than during the PATH
# phase. That file is only built once `heroku autocomplete` has been run
# interactively; until then the snippet's own `test -f` makes it a no-op.
if (( $+commands[heroku] )); then
  # Status consumed with `|| true`: a bare command that returns non-zero aborts
  # the file under ERR_RETURN (how the tests source it), and absent heroku
  # completions are not worth a startup warning.
  leos-source-cached heroku-completion $commands[heroku] autocomplete:script zsh || true
fi

:
