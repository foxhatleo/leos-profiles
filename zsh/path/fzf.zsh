# fzf — key-bindings (^R history, ^T paste, Alt-C cd) + ** completion trigger.
# Loaded before interactive.zsh's fzf-tab, per fzf-tab's docs.
if command -v fzf >/dev/null 2>&1; then
  if _leos_fzf_init=$(fzf --zsh 2>/dev/null); then
    eval "$_leos_fzf_init"
  else
    # Distribution packages predating `fzf --zsh` ship these as files. Load
    # the first layout that exists so multiple installed copies don't
    # double-bind widgets.
    for _leos_fzf_dir in \
      "$HOME/.fzf/shell" \
      /usr/share/fzf/shell \
      /usr/share/fzf \
      /usr/share/doc/fzf/examples; do
      if [[ -r $_leos_fzf_dir/key-bindings.zsh ]]; then
        source "$_leos_fzf_dir/key-bindings.zsh"
        [[ -r $_leos_fzf_dir/completion.zsh ]] && source "$_leos_fzf_dir/completion.zsh"
        break
      fi
    done
    unset _leos_fzf_dir
  fi
  unset _leos_fzf_init
fi

:
