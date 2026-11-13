# Pacman checkup — Arch is rolling, so `pacman -Syu` is inherently an in-release
# upgrade (there is no separate OS release to upgrade to). Drops the init cache
# afterwards, as apt-checkup does (see path/apt.zsh).
if command -v pacman >/dev/null 2>&1; then
  pacman-checkup() {
    local -a orphans
    sudo pacman -Syu --noconfirm || return 1
    orphans=(${(f)"$(pacman -Qtdq 2>/dev/null || true)"})
    (( ${#orphans[@]} == 0 )) || sudo pacman -Rns --noconfirm -- "${orphans[@]}" || return 1
    sudo pacman -Sc --noconfirm || return 1
    (( ! $+functions[leos-refresh-init-cache] )) || leos-refresh-init-cache
  }
fi

:
