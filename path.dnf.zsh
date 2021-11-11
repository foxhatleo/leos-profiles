if type "dnf" > /dev/null; then
  dnf-checkup() {
    sudo dnf -y update;
    sudo dnf -y autoremove;
  }
fi
