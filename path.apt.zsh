if type "apt" > /dev/null; then

  apt-checkup() {
    sudo apt update;
    sudo apt upgrade;
    sudo apt autoremove;
  }
  
fi
