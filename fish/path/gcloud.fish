# Leo's Profiles
# GCloud via Homebrew
#
# This script sets up GCloud if installed through Homebrew.

if set -l brew_prefix (__leos_brew_prefix)
    if test -d "$brew_prefix/share/google-cloud-sdk"
        source "$brew_prefix/share/google-cloud-sdk/path.fish.inc"
    end
end
