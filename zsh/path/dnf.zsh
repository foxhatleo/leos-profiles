# DNF checkup — in-release package upgrade only; never `dnf system-upgrade`.
if command -v dnf >/dev/null 2>&1; then
  dnf-checkup() { __leos_sudo dnf upgrade -y && __leos_sudo dnf autoremove -y && __leos_sudo dnf -y clean all; }
fi

:
