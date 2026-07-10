# fzf — key-bindings (^R history, ^T paste, Alt-C cd) + ** completion trigger.
# Loaded before interactive.zsh's fzf-tab, per fzf-tab's docs.
if command -v fzf >/dev/null 2>&1; then
  if fzf --zsh >/dev/null 2>&1; then
    eval "$(fzf --zsh)"
  else
    # Distribution packages predating `fzf --zsh` ship these as files.
    for _leos_fzf_file in \
      "$HOME/.fzf/shell/completion.zsh" \
      "$HOME/.fzf/shell/key-bindings.zsh" \
      /usr/share/doc/fzf/examples/completion.zsh \
      /usr/share/doc/fzf/examples/key-bindings.zsh \
      /usr/share/fzf/completion.zsh \
      /usr/share/fzf/key-bindings.zsh; do
      [[ -r $_leos_fzf_file ]] && source "$_leos_fzf_file"
    done
    unset _leos_fzf_file
  fi
fi

:
