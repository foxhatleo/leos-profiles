# Pacman checkup — Arch is rolling, so `pacman -Syu` is inherently an in-release
# upgrade (there is no separate OS release to upgrade to).
if command -v pacman >/dev/null 2>&1; then
  pacman-checkup() {
    local -a orphans
    sudo pacman -Syu --noconfirm || return 1
    orphans=(${(f)"$(pacman -Qtdq 2>/dev/null || true)"})
    (( ${#orphans[@]} == 0 )) || sudo pacman -Rns --noconfirm -- "${orphans[@]}" || return 1
    sudo pacman -Sc --noconfirm
  }
fi

:
