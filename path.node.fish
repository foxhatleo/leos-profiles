# Leo's Profiles
# Node.js & Yarn
#
# This script adds yarn global binary path if it exists.

if type -q yarn
    add-path (yarn global bin) required
end
