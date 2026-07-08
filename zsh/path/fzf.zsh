# fzf — key-bindings (^R history, ^T paste, Alt-C cd) + ** completion trigger.
# Loaded before interactive.zsh's fzf-tab, per fzf-tab's docs.
command -v fzf >/dev/null 2>&1 && eval "$(fzf --zsh)"
