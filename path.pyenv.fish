# Leo's Profiles
# pyenv
#
# This script sets up pyenv if present.

set -Ux PYENV_ROOT $HOME/.pyenv
add-path "$PYENV_ROOT/bin"

if not type -q pyenv
    if not test -f $HOME/.lp-nopyenv
        echo "pyenv is not installed. To silence, touch \$HOME/.lp-nopyenv." >&2
    end
end
