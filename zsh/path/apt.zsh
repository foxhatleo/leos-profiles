# APT checkup — in-release package upgrade only; never do-release-upgrade or
# `apt full-upgrade` against a bumped release.
if command -v apt-get >/dev/null 2>&1; then
  apt-checkup() {
    sudo apt-get update &&
      sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y &&
      sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y &&
      sudo apt-get clean
  }
fi

:
