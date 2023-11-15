# Leo's zsh Profiles
# APT
#
# This script adds useful commands if apt-get is present.

if command -v apt-get &> /dev/null; then
  apt-checkup() {
    sudo apt update -y 
    sudo apt upgrade -y 
    sudo apt autoremove --purge -y 
    sudo apt clean -y 
  }
fi
