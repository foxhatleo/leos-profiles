# Leo's Profiles — interactive stack: plugins, completion, Starship.
# Loaded LAST so zsh-syntax-highlighting is the final plugin sourced.

# Every other file reads flags from $LEOS_PROFILES, but this one is also sourced
# standalone by the test suite with only LEOS_PROFILES_ZSH set. Derive the root
# once from either, so a flag cannot resolve against a different root here than
# it does everywhere else.
typeset -g _leos_root=${LEOS_PROFILES:-${LEOS_PROFILES_ZSH:h}}

_leos_plugin() {
  [[ -e $LEOS_PROFILES_ZSH/plugins/$1 ]] || return 0
  source "$LEOS_PROFILES_ZSH/plugins/$1"
}

# Pin the keymap before any plugin binds a key. Without this zsh picks the
# initial keymap from $VISUAL/$EDITOR, so a machine that exports EDITOR=vim
# silently starts in vi mode — with none of the plugins or the prompt set up for
# it. This states today's behaviour (env.zsh defaults EDITOR to nano) explicitly
# instead of leaving it to inherited environment.
#
# An `if`, not `&&`: with no line editor the guard is false, and a false guard
# mid-file aborts the whole file under ERR_RETURN (how the tests source it).
if [[ -o zle ]]; then
  bindkey -e
fi

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
  # Compile the dump so later shells map it instead of re-parsing ~60KB of Zsh
  # source; compinit prefers a .zwc that is newer than its origin.
  if [[ -s $dump && ( ! -s $dump.zwc || $dump -nt $dump.zwc ) ]]; then
    zcompile -R "$dump" 2>/dev/null || true
  fi
  return 0
}

# These all register completions with `compdef`, so they must load after
# compinit — during the PATH phase their registrations silently no-op.
# fzf specifically must also come before fzf-tab, per fzf-tab's docs.
entry "path/fzf"
entry "path/zoxide"
entry "path/gcloud-completion"
entry "path/heroku"

# fzf-tab must load after compinit but BEFORE plugins that wrap ZLE widgets.
_leos_plugin fzf-tab/fzf-tab.plugin.zsh

# Suggest from the completion system as well as history, so a command typed for
# the first time still gets a suggestion. Capped buffer size keeps the
# completion strategy from adding latency on very long lines.
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
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

  # npm/pnpm completions (cached; defined in path/node.zsh).
  (( $+functions[leos-node-completions] )) && leos-node-completions
fi

# Syntax highlighting must be the final interactive plugin action, after
# completion definitions and prompt widget setup.
_leos_plugin zsh-syntax-highlighting/zsh-syntax-highlighting.zsh   # MUST be last

# Starship prompt.
# $+commands, not `command -v`: the cached init below needs the binary's path,
# and only $commands is guaranteed to hold one.
if (( $+commands[starship] )); then
  # Keep Leo's established themed prompt as the default.  The plain prompt is
  # an explicit fallback for terminals without Nerd Font support.
  if [[ ${LEOS_PLAIN_PROMPT:-0} == 1 ]]; then
    export STARSHIP_CONFIG="$LEOS_PROFILES_ZSH/starship-plain.toml"
  else
    export STARSHIP_CONFIG="$LEOS_PROFILES_ZSH/starship.toml"
  fi
  # Cached: the init script is deterministic, and the parts that must vary per
  # shell (the session key, PROMPT2) are expanded when it is sourced.
  leos-source-cached starship-init $commands[starship] init zsh
else
  if [[ ! -f $_leos_root/local/flags/no-starship-warning ]]; then
    puts-err "Starship is not installed; using the built-in fallback prompt. Run the installer plugins step to restore it, or touch local/flags/no-starship-warning under the profile root to silence this."
  fi
  PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %# '
fi

# Machine-local interactive overrides, last of all: this is the counterpart to
# local/private.zsh for anything that needs `compdef`, a ZLE widget, or the final
# word over the plugin stack — none of which exist yet when private.zsh loads.
if [[ -r $_leos_root/local/private-interactive.zsh ]]; then
  source "$_leos_root/local/private-interactive.zsh"
fi

unset _leos_root

:
