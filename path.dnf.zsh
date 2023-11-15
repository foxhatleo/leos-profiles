# Leo's zsh Profiles
# DNF
#
# This script adds useful commands if dnf is present.

if command -v dnf &> /dev/null; then
  dnf-checkup() {
    sudo dnf update -y 
    sudo dnf autoremove -y 
    sudo dnf clean all -y 
  }
fi
