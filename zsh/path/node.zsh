# Yarn (Classic) global bin. Add the default location from disk instead of
# running `yarn global bin`, which spawns a Node process on every interactive
# shell (and Yarn Berry has no global bin at all). A non-default global prefix
# can be added in local/private.zsh.
add-path "$HOME/.yarn/bin"

:
