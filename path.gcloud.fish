# Leo's Profiles
# GCloud on macOS
#
# This script sets up GCloud on macOS.

if test -d "$(brew --prefix)/share/google-cloud-sdk"
    source "$(brew --prefix)/share/google-cloud-sdk/path.fish.inc"
end
