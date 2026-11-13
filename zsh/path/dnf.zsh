# DNF checkup — in-release package upgrade only; never `dnf system-upgrade`.
# Drops the init cache afterwards, as apt-checkup does (see path/apt.zsh).
if command -v dnf >/dev/null 2>&1; then
  dnf-checkup() {
    sudo dnf upgrade -y && sudo dnf autoremove -y && sudo dnf -y clean all || return 1
    (( ! $+functions[leos-refresh-init-cache] )) || leos-refresh-init-cache
  }
fi

:
