# APT checkup — in-release package upgrade only; never do-release-upgrade or
# `apt full-upgrade` against a bumped release. A changed configuration file
# keeps the local version instead of stopping at dpkg's prompt (confdef takes
# the package default when there is one), as the installer does.
#
# An upgrade can rewrite a tool's init logic in a file other than the launcher
# the init cache is keyed on, so the cache is dropped afterwards, as
# brew-checkup does (dnf-checkup and pacman-checkup too).
if command -v apt-get >/dev/null 2>&1; then
  apt-checkup() {
    sudo apt-get update &&
      sudo env DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y &&
      sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y &&
      sudo apt-get clean || return 1
    (( ! $+functions[leos-refresh-init-cache] )) || leos-refresh-init-cache
  }
fi

:
