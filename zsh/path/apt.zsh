# APT checkup — in-release package upgrade only; never do-release-upgrade or
# `apt full-upgrade` against a bumped release. A changed configuration file
# keeps the local version instead of stopping at dpkg's prompt (confdef takes
# the package default when there is one), as the installer does.
if command -v apt-get >/dev/null 2>&1; then
  apt-checkup() {
    __leos_sudo apt-get update &&
      __leos_sudo env DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y &&
      __leos_sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y &&
      __leos_sudo apt-get clean
  }
fi

:
