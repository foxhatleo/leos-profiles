# Leo's Profiles — interactive stack: plugins, completion, Starship.
# Loaded LAST so zsh-syntax-highlighting is the final plugin sourced.

_leos_plugin() {
  [[ -e $LEOS_PROFILES_ZSH/plugins/$1 ]] || return 0
  source "$LEOS_PROFILES_ZSH/plugins/$1"
}

# zsh-completions must extend fpath BEFORE compinit.
[[ -d $LEOS_PROFILES_ZSH/plugins/zsh-completions/src ]] && \
  fpath=("$LEOS_PROFILES_ZSH/plugins/zsh-completions/src" $fpath)

# compinit — regenerate at most once/day, else fast path. If the host exposes
# insecure completion directories, ignore those directories instead of asking
# an interactive question during shell startup.
autoload -Uz compinit compaudit
() {
  # Localize options so the freshness qualifier below (which needs EXTENDED_GLOB,
  # normally enabled in env.zsh) works regardless of the ambient option set.
  emulate -L zsh
  setopt extended_glob
  local dump=$HOME/.zcompdump insecure
  insecure=$(compaudit 2>/dev/null) || true
  if [[ -n $insecure ]]; then
    puts-err "Ignoring insecure Zsh completion path(s): ${(j:, :)${(f)insecure}}"
    compinit -i -d "$dump" || { puts-err "Zsh completion initialization failed; continuing without completion."; return 0; }
  elif [[ -n $dump(#qN.mh-24) ]]; then
    compinit -C -d "$dump" || { puts-err "Cached Zsh completion initialization failed; retrying safely."; compinit -i -d "$dump" || return 0; }
  else
    compinit -d "$dump" || { puts-err "Zsh completion initialization failed; continuing without completion."; return 0; }
  fi
  return 0
}

# fzf completion and widgets load after compinit, but before fzf-tab.
entry "path/fzf"

# fzf-tab must load after compinit but BEFORE plugins that wrap ZLE widgets.
_leos_plugin fzf-tab/fzf-tab.plugin.zsh
_leos_plugin zsh-autosuggestions/zsh-autosuggestions.zsh

# Custom completions (after compinit).
if (( $+functions[compdef] )); then
  compdef _directories mkcdir
  _leos_bye() {
    _values 'option' \
      '--no-exit[Do not quit the terminal]' \
      '--keep-history[Preserve history files]' \
      '--non-interactive[Run upgrades without confirmation prompts]' \
      '--aggressive-history[Also remove legacy history and HSTS matches]' \
      '--purge-recycle-bins[Permit removal of macOS recycle-bin directories]' \
      '--shutdown-wsl[Shut down WSL after maintenance]'
  }
  compdef _leos_bye bye
fi

# Syntax highlighting must be the final interactive plugin action, after
# completion definitions and prompt widget setup.
_leos_plugin zsh-syntax-highlighting/zsh-syntax-highlighting.zsh   # MUST be last

# Starship prompt.
if command -v starship >/dev/null 2>&1; then
  # Keep Leo's established themed prompt as the default.  The plain prompt is
  # an explicit fallback for terminals without Nerd Font support.
  if [[ ${LEOS_PLAIN_PROMPT:-0} == 1 ]]; then
    export STARSHIP_CONFIG="$LEOS_PROFILES_ZSH/starship-plain.toml"
  else
    export STARSHIP_CONFIG="$LEOS_PROFILES_ZSH/starship.toml"
  fi
  eval "$(starship init zsh)"
else
  if [[ ! -f ${LEOS_PROFILES_ZSH:h}/local/flags/no-starship-warning ]]; then
    puts-err "Starship is not installed; using the built-in fallback prompt. Run the installer plugins step to restore it, or touch local/flags/no-starship-warning under the profile root to silence this."
  fi
  PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %# '
fi

:
