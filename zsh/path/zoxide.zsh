# zoxide — smarter cd: --cmd cd makes `cd` itself frecency-aware, falling
# back to real cd for literal paths (also adds cdi/zi interactive jump).
#
# Loaded from interactive.zsh, AFTER compinit: the generated script registers
# its `cd` completion with `compdef`, guarded on compdef existing, so running
# this during the PATH phase silently lost that completion.
(( $+commands[zoxide] )) && leos-source-cached zoxide-init $commands[zoxide] init zsh --cmd cd

:
