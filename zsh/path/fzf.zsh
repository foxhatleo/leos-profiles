# fzf — key-bindings (^R history, ^T paste, Alt-C cd) + ** completion trigger.
# Loaded before interactive.zsh's fzf-tab, per fzf-tab's docs.
#
# Everything here installs ZLE widgets, so it is both pointless and noisy in an
# interactive shell with no line editor (editor shell integrations, CI,
# `zsh -ic`): fzf's own script prints "can't change option: zle" twice there.
if [[ -o zle ]] && (( $+commands[fzf] )); then
  # `fzf --zsh` is deterministic, so it is cached. A non-zero return means this
  # fzf predates that flag, in which case the distribution ships the scripts as
  # files: load the first layout that exists so multiple installed copies do
  # not double-bind widgets.
  if ! leos-source-cached fzf-init $commands[fzf] --zsh; then
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
fi

:
