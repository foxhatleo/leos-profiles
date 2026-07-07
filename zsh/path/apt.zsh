# APT checkup
if command -v apt-get >/dev/null 2>&1; then
  apt-checkup() {
    sudo DEBIAN_FRONTEND=noninteractive apt update -y
    sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
    sudo DEBIAN_FRONTEND=noninteractive apt autoremove --purge -y
    sudo DEBIAN_FRONTEND=noninteractive apt clean -y
  }
fi
