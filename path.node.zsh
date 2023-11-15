# Leo's zsh Profiles
# Node.js & Yarn
#
# This script adds yarn global binary path if it exists.

if command -v yarn &> /dev/null; then
  add-path "$(yarn global bin)" required
fi
