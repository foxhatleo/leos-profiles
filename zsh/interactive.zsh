# Leo's Profiles — interactive stack: plugins, completion, Starship.
# start.zsh loads this after the PATH/environment layer and local/private.zsh,
# and sources only local/private-interactive.zsh after it.

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
# Unguarded on purpose: verified that `bindkey -e` returns 0 and prints nothing
# even when the shell has no line editor, so there is nothing to guard against.
bindkey -e

# Navigation keys, bound again in the emacs keymap: `bindkey -e` drops whatever
# a system zshrc bound in another keymap (macOS binds Home/End/Delete into viins
# when EDITOR is vim), and some distributions bind none of them. terminfo gives
# the keypad-transmit sequence; the literal fallbacks cover the normal cursor
# mode zle actually runs in, since it never sends smkx.
#
# Up/Down search history for lines starting with what is already typed. The
# widgets exist before zsh-autosuggestions and zsh-syntax-highlighting load,
# so both wrap them (autosuggestions also clears its suggestion on them).
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
() {
  emulate -L zsh
  zmodload zsh/terminfo 2>/dev/null
  local widget seq
  local -a seqs
  for widget in beginning-of-line end-of-line delete-char backward-word forward-word \
      up-line-or-beginning-search down-line-or-beginning-search; do
    case $widget in
      beginning-of-line) seqs=("${terminfo[khome]-}" $'\e[H' $'\eOH' $'\e[1~' $'\e[7~') ;;
      end-of-line)       seqs=("${terminfo[kend]-}" $'\e[F' $'\eOF' $'\e[4~' $'\e[8~') ;;
      delete-char)       seqs=("${terminfo[kdch1]-}" $'\e[3~') ;;
      backward-word)     seqs=("${terminfo[kLFT5]-}" $'\e[1;5D' $'\e[5D') ;;   # Ctrl-Left
      forward-word)      seqs=("${terminfo[kRIT5]-}" $'\e[1;5C' $'\e[5C') ;;   # Ctrl-Right
      up-line-or-beginning-search)   seqs=("${terminfo[kcuu1]-}" $'\e[A' $'\eOA') ;;
      down-line-or-beginning-search) seqs=("${terminfo[kcud1]-}" $'\e[B' $'\eOB') ;;
    esac
    for seq in $seqs; do
      bindkey -M emacs -- "$seq" "$widget"
    done
  done
}

# zsh-completions must extend fpath BEFORE compinit. So must the profile's own
# completions (zsh/completions: compsys replacements for tools that ship only
# compctl ones), which come first.
[[ -d $LEOS_PROFILES_ZSH/plugins/zsh-completions/src ]] && \
  fpath=("$LEOS_PROFILES_ZSH/plugins/zsh-completions/src" $fpath)
[[ -d $LEOS_PROFILES_ZSH/completions ]] && \
  fpath=("$LEOS_PROFILES_ZSH/completions" $fpath)

# compinit — rebuild and audit at most once a day, else the fast path.
#
# Fast path: the dump was (re)written or confirmed in the last 24 hours and was
# built from the same fpath directories. `compinit -C` then just loads it, with
# no audit and no scan of every fpath file. Slow path, otherwise: compaudit
# first, then a full compinit, which rebuilds the dump if its file count no
# longer matches. compinit leaves an up-to-date dump untouched, so the dump is
# touched afterwards, as Prezto does; without that its mtime stays old and every
# later shell would take the slow path again. If the host exposes insecure
# completion directories, ignore those directories (-i) instead of asking an
# interactive question during shell startup.
#
# The dump lives in the same validated, private cache root as the init cache,
# named per Zsh version so an upgrade never reads an older version's dump. If
# that storage is unsafe it falls back to Zsh's usual ${ZDOTDIR:-$HOME}. The
# fpath the dump was built from is kept beside it in the cache root only.
autoload -Uz compinit compaudit
() {
  # Localize options so the freshness qualifier below (which needs EXTENDED_GLOB,
  # normally enabled in env.zsh) works regardless of the ambient option set.
  emulate -L zsh
  setopt extended_glob
  local dump insecure stamp fpath_record= fresh=0
  local -a legacy
  if (( $+functions[__leos_cache_dir] )) && __leos_cache_dir; then
    dump=${REPLY:h}/zcompdump-$ZSH_VERSION
    fpath_record=$dump.fpath
    # Never let compinit source a dump that is not this user's regular file.
    if [[ -e $dump || -L $dump ]] && [[ ! -f $dump || -L $dump || ! -O $dump ]]; then
      rm -f -- "$dump" "$dump.zwc" 2>/dev/null
    fi
    # Once: remove the dumps earlier versions of this profile left in HOME
    # (only regular files this user owns, and only these names).
    stamp=${REPLY:h}/zcompdump-legacy-removed
    if [[ ! -e $stamp ]]; then
      legacy=(${ZDOTDIR:-$HOME}/.zcompdump(N.U) ${ZDOTDIR:-$HOME}/.zcompdump.zwc(N.U)
              ${ZDOTDIR:-$HOME}/.zcompdump-*(N.U))
      (( ! $#legacy )) || rm -f -- $legacy 2>/dev/null
      : > "$stamp" 2>/dev/null
    fi
  else
    dump=${ZDOTDIR:-$HOME}/.zcompdump
  fi
  if [[ -n $dump(#qN.mh-24) ]]; then
    fresh=1
    # A tool that added an fpath directory since (rbenv, heroku, a new plugin)
    # must not wait a day for its completions. `$(<file)` reads in-process.
    if [[ -n $fpath_record ]]; then
      [[ -f $fpath_record && ! -L $fpath_record && "$(<$fpath_record)" == "${(pj:\n:)fpath}" ]] || fresh=0
    fi
  fi
  if (( fresh )); then
    compinit -C -d "$dump" || { puts-err "Cached Zsh completion initialization failed; retrying safely."; compinit -i -d "$dump" || return 0; }
  else
    insecure=$(compaudit 2>/dev/null) || true
    if [[ -n $insecure ]]; then
      puts-err "Ignoring insecure Zsh completion path(s): ${(j:, :)${(f)insecure}}"
      compinit -i -d "$dump" || { puts-err "Zsh completion initialization failed; continuing without completion."; return 0; }
    else
      compinit -d "$dump" || { puts-err "Zsh completion initialization failed; continuing without completion."; return 0; }
    fi
    # Mark the dump as confirmed today, even when compinit found nothing to
    # rewrite. Only this user's regular file is touched.
    if [[ -f $dump && ! -L $dump && -O $dump ]]; then
      command touch -- "$dump" 2>/dev/null || true
    fi
    if [[ -n $fpath_record ]]; then
      # The directory is private; still, never write through anything but this
      # user's own regular file.
      if [[ -e $fpath_record || -L $fpath_record ]] &&
          [[ ! -f $fpath_record || -L $fpath_record || ! -O $fpath_record ]]; then
        rm -f -- "$fpath_record" 2>/dev/null
      fi
      print -r -- "${(pj:\n:)fpath}" > "$fpath_record" 2>/dev/null || true
    fi
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
#
# heroku stays first: current CLIs skip their own compinit once compdef exists
# (heroku/cli#3839), but an older CLI's zsh_setup still runs a second compinit,
# which would discard every compdef registered before it — including zoxide's
# `cd` completion.
entry "path/heroku"
entry "path/fzf"
entry "path/zoxide"

# fzf-tab must load after compinit but BEFORE plugins that wrap ZLE widgets.
_leos_plugin fzf-tab/fzf-tab.plugin.zsh

# Suggest from history first, then from the completion system, so a command
# typed for the first time still gets a suggestion. The size cap switches off
# EVERY strategy once the line is longer, not just the completion one, so it is
# set well above ordinary command lengths; it still keeps a large paste from
# running the completion strategy on every keystroke.
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=100
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

# Syntax highlighting is the final plugin, after completion definitions.
# Prompt initialization follows below; start.zsh then sources
# local/private-interactive.zsh.
_leos_plugin zsh-syntax-highlighting/zsh-syntax-highlighting.zsh   # MUST be last

# Starship prompt. The built-in fallback is used whenever Starship cannot drive
# the prompt, whether because it is absent or because its init produced nothing.
typeset -g _leos_fallback_prompt='%F{cyan}%n@%m%f %F{blue}%~%f %# '

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
  typeset -g _leos_starship_status=0
  leos-source-cached starship-init $commands[starship] init zsh || _leos_starship_status=$?
  if (( _leos_starship_status )); then
    # Only warn on a fresh failure (1); 2 means an earlier shell already said so.
    (( _leos_starship_status == 1 )) &&
      puts-err "starship init produced no output; using the built-in fallback prompt."
    # Actually install that fallback, rather than leaving the prompt unset.
    PROMPT=$_leos_fallback_prompt
  fi
  unset _leos_starship_status
else
  if [[ ! -f $_leos_root/local/flags/no-starship-warning ]]; then
    puts-err "Starship is not installed; using the built-in fallback prompt. Run the installer plugins step to restore it, or touch local/flags/no-starship-warning under the profile root to silence this."
  fi
  PROMPT=$_leos_fallback_prompt
fi
unset _leos_fallback_prompt

# Tool init scripts above may have prepended PATH/fpath entries again.
typeset -gU path fpath
path=($path)

unset _leos_root

:
