# fzf — key-bindings (^R history, ^T paste, Alt-C cd) + ** completion trigger.
# Loaded before interactive.zsh's fzf-tab, per fzf-tab's docs.

if (( $+commands[fzf] )); then
  # fd honours .gitignore and is much faster than fzf's built-in walker. Debian
  # and Ubuntu ship it as fdfind; the installer links that to fd where it can.
  # Values the user already set (environment or local/private.zsh) win.
  if (( $+commands[fd] )); then
    typeset -g _leos_fzf_fd=fd
  elif (( $+commands[fdfind] )); then
    typeset -g _leos_fzf_fd=fdfind
  fi
  if [[ -n ${_leos_fzf_fd:-} ]]; then
    : ${FZF_DEFAULT_COMMAND:="$_leos_fzf_fd --type f --hidden --follow --exclude .git"}
    : ${FZF_CTRL_T_COMMAND:="$_leos_fzf_fd --type f --hidden --follow --exclude .git"}
    : ${FZF_ALT_C_COMMAND:="$_leos_fzf_fd --type d --hidden --follow --exclude .git"}
    export FZF_DEFAULT_COMMAND FZF_CTRL_T_COMMAND FZF_ALT_C_COMMAND
    # Candidates for the `**<Tab>` trigger; fzf passes the directory being
    # completed. A user's own definition wins.
    if (( ! $+functions[_fzf_compgen_path] )); then
      _fzf_compgen_path() {
        command "$_leos_fzf_fd" --hidden --follow --exclude .git . "$1"
      }
    fi
    if (( ! $+functions[_fzf_compgen_dir] )); then
      _fzf_compgen_dir() {
        command "$_leos_fzf_fd" --type d --hidden --follow --exclude .git . "$1"
      }
    fi
  fi
  # Ctrl-T previews files with bat when it is available.
  if (( $+commands[bat] )) && [[ -z ${FZF_CTRL_T_OPTS:-} ]]; then
    export FZF_CTRL_T_OPTS="--preview 'bat --style=numbers --color=always --line-range :500 {}'"
  fi
fi

# Everything below installs ZLE widgets, so it is both pointless and noisy in a
# shell that cannot edit a line: editor shell integrations, CI, agents running
# `zsh -ic` without a terminal. `-o zle` alone is not enough there — the option
# stays set until zsh actually starts the editor — and fzf's own script then
# prints "can't change option: zle" twice. So require a terminal on both stdin
# and stdout as well.
if [[ -o zle && -n ${TTY:-} && -t 0 && -t 1 ]] && (( $+commands[fzf] )); then
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
