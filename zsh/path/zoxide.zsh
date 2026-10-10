# zoxide — smarter cd: --cmd cd makes `cd` itself frecency-aware, falling
# back to real cd for literal paths (also adds cdi/zi interactive jump).
#
# Loaded from interactive.zsh, AFTER compinit: the generated script registers
# its `cd` completion with `compdef`, guarded on compdef existing, so running
# this during the PATH phase silently lost that completion.
#
# _ZO_ECHO and _ZO_RESOLVE_SYMLINKS change the code `zoxide init` generates
# (zoxide's other variables are read at run time), so they are part of the
# cache identity: changing either in local/private.zsh regenerates the script.
if (( $+commands[zoxide] )); then
  leos-source-cached-warn "zoxide init produced no output; cd will not be frecency-aware." \
    "zoxide-init:${+_ZO_ECHO}${_ZO_ECHO-}:${+_ZO_RESOLVE_SYMLINKS}${_ZO_RESOLVE_SYMLINKS-}" \
    $commands[zoxide] init zsh --cmd cd
fi

:
