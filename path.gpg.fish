# Leo's Profiles
# GPG
#
# This script sets up GPG.

if status is-interactive
    set -l gpg_tty (tty)
    if test $status -eq 0
        set -gx GPG_TTY $gpg_tty
    end
end
