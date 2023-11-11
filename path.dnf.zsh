if type "dnf" > /dev/null; then
  dnf-checkup() {
    sudo dnf update -y ;
    sudo dnf autoremove -y ;
    sudo dnf clean all -y ;
  }
fi
