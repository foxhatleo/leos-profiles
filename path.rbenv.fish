# Leo's Profiles
# pyenv
#
# This script sets up pyenv if present.

set -Ux RBENV_ROOT $HOME/.rbenv
add-path "$RBENV_ROOT/bin"

if not type -q rbenv
    if not test -f $HOME/.lp-norbenv
        puts-err "rbenv is not installed. To silence, touch \$HOME/.lp-nopyenv." >&2
    end
else
    rbenv init - | source
end
