if type "apt" > /dev/null; then
  apt-checkup() {
    sudo apt update -y;
    sudo apt upgrade -y;
    sudo apt autoremove --purge -y;
  }
fi
