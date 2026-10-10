# Leo's Profiles — terminal environment (zsh)

# Respect an existing locale/editor preference. A deterministic UTF-8 fallback
# is useful on minimal machines, but forcing LC_ALL changes every child tool.
if [[ -z ${LANG:-} ]]; then
  if locale -a 2>/dev/null | command grep -qEi '^C\.(UTF-8|utf8)$'; then
    export LANG=C.UTF-8
  elif locale -a 2>/dev/null | command grep -qEi '^en_US\.(UTF-8|utf8)$'; then
    export LANG=en_US.UTF-8
  else
    export LANG=C
  fi
fi

# Term colors
export CLICOLOR=1
export LSCOLORS=gxBxhxDxfxhxhxhxhxcxcx
export LS_COLORS='di=36:ln=1;31:so=37:pi=1;33:ex=35:bd=37:cd=37:su=37:sg=37:tw=32:ow=32'

# Editor
export EDITOR="${EDITOR:-nano}"

# Colorful output. Set LEOS_DISABLE_ALIASES=1 for scripts, recovery shells, or
# users who prefer the underlying commands unchanged.
if [[ ${LEOS_DISABLE_ALIASES:-0} != 1 ]]; then
  if command -v eza >/dev/null 2>&1; then
    alias ls='eza --color=auto --group-directories-first'
  elif command ls --color=auto -d . >/dev/null 2>&1; then
    alias ls='ls --color=auto'
  elif [[ $OSTYPE == darwin* ]]; then
    alias ls='ls -G'
  fi
  if command -v bat >/dev/null 2>&1; then
    alias cat='bat --style=plain --paging=never'
    # Colorized man pages from the same pager. `col -bx` strips the overstrike
    # sequences groff emits, which bat would otherwise render literally.
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
    export MANROFFOPT='-c'          # keeps groff from re-adding those sequences
  fi
  if command grep --color=auto '' /dev/null >/dev/null 2>&1 || [[ $? == 1 ]]; then
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
  fi
fi

# History — fish-like: shared, dedup, trimmed
HISTFILE=$HOME/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
# SHARE_HISTORY already implies incremental appending (plus import from other
# shells), and the manual advises picking one of SHARE_HISTORY /
# INC_APPEND_HISTORY / INC_APPEND_HISTORY_TIME rather than combining them.
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY EXTENDED_HISTORY

# Interactive behavior
setopt AUTO_CD EXTENDED_GLOB INTERACTIVE_COMMENTS NO_BEEP NO_CASE_GLOB NUMERIC_GLOB_SORT

# Completion styling (compinit itself runs in interactive.zsh)
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
# `menu no`, not `menu select`: fzf-tab provides the menu UI and its README asks
# for this so it can capture the unambiguous prefix before opening the finder.
zstyle ':completion:*' menu no
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}        # colorize menu; also picked up by fzf-tab
zstyle ':completion:*:descriptions' format '[%d]'            # fzf-tab uses these as group headers
# Directory preview in fzf-tab's finder, matching the eza/bat aesthetic above.
if command -v eza >/dev/null 2>&1; then
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
fi
zstyle ':completion:*' rehash true                           # find newly-installed executables without a restart
zstyle ':completion:*' accept-exact '*(N)'
# The completion cache lives beside the init cache in the same validated,
# private root. If that storage is unsafe, completion caching stays off rather
# than creating directories with the caller's umask.
if __leos_cache_dir; then
  _leos_zcompcache=${REPLY:h}/zcompcache
  if [[ ! -e $_leos_zcompcache ]]; then
    mkdir -m 700 -- "$_leos_zcompcache" 2>/dev/null
  fi
  if [[ -d $_leos_zcompcache && ! -L $_leos_zcompcache && -O $_leos_zcompcache ]]; then
    zstyle ':completion:*' use-cache on
    zstyle ':completion:*' cache-path "$_leos_zcompcache"
  fi
  unset _leos_zcompcache
fi

# iTerm2 integration is deliberately opt-in: it is external shell code and is
# no longer downloaded by the installer. Install it through iTerm2, then set
# LEOS_ENABLE_ITERM2_INTEGRATION=1 if you want this profile to source it.
[[ ${LEOS_ENABLE_ITERM2_INTEGRATION:-0} == 1 && -r $HOME/.iterm2_shell_integration.zsh ]] && \
  source "$HOME/.iterm2_shell_integration.zsh"

:
