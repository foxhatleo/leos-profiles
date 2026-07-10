# DNF checkup
if command -v dnf >/dev/null 2>&1; then
  dnf-checkup() { sudo dnf upgrade -y && sudo dnf autoremove -y && sudo dnf -y clean all; }
fi

:
