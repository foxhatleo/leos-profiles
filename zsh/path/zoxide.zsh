# zoxide — frecency-ranked directory jumps: `z <words>` jumps to the best
# match (and behaves like cd for a literal path), `zi` picks one interactively.
# `cd` stays the shell builtin, so scripts, functions and muscle memory that
# rely on its exact behaviour are unaffected.
#
# Loaded from interactive.zsh, AFTER compinit: the generated script registers
# its `z` completion with `compdef`, guarded on compdef existing, so running
# this during the PATH phase silently lost that completion.
#
# _ZO_ECHO and _ZO_RESOLVE_SYMLINKS change the code `zoxide init` generates
# (zoxide's other variables are read at run time), so they are part of the
# cache identity: changing either in local/private.zsh regenerates the script.
# The key's `v2` marks the move away from `--cmd cd`; the arguments are part of
# the identity too, so an entry cached with `--cmd cd` is never reused.
if whence -p zoxide >/dev/null; then
  leos-source-cached-warn "zoxide init produced no output; z and zi are unavailable." \
    "zoxide-init-v2:${+_ZO_ECHO}${_ZO_ECHO-}:${+_ZO_RESOLVE_SYMLINKS}${_ZO_RESOLVE_SYMLINKS-}" \
    $commands[zoxide] init zsh
fi

:
