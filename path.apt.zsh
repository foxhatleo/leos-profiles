if type "apt-get" > /dev/null; then
  apt-checkup() {
    sudo apt update -y ;
    sudo apt upgrade -y ;
    sudo apt autoremove --purge -y ;
    sudo apt clean -y ;
  }
fi
