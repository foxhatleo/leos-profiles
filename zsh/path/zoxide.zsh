# zoxide — smarter cd: --cmd cd makes `cd` itself frecency-aware, falling
# back to real cd for literal paths (also adds cdi/zi interactive jump).
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh --cmd cd)"
