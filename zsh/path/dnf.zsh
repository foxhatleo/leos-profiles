# DNF checkup
if command -v dnf >/dev/null 2>&1; then
  dnf-checkup() { sudo dnf update -y; sudo dnf autoremove -y; sudo dnf clean all -y; }
fi
