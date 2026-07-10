# APT checkup
if command -v apt-get >/dev/null 2>&1; then
  apt-checkup() {
    sudo apt-get update &&
      sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y &&
      sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y &&
      sudo apt-get clean
  }
fi

:
