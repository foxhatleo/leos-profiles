# Leo's Profiles — terminal environment (zsh)

# Respect an existing locale/editor preference. A deterministic UTF-8 fallback
# is useful on minimal machines, but forcing LC_ALL changes every child tool.
if [[ -z ${LANG:-} ]]; then
  if locale -a 2>/dev/null | command grep -qEi '^C\.(UTF-8|utf8)$'; then
    export LANG=C.UTF-8
  else
    export LANG=en_US.UTF-8
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
  elif [[ $(uname -s) == Darwin ]]; then
    alias ls='ls -G'
  fi
  command -v bat >/dev/null 2>&1 && alias cat='bat --style=plain --paging=never'
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
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS INC_APPEND_HISTORY HIST_VERIFY EXTENDED_HISTORY

# Interactive behavior
setopt AUTO_CD EXTENDED_GLOB INTERACTIVE_COMMENTS NO_BEEP NO_CASE_GLOB NUMERIC_GLOB_SORT

# Completion styling (compinit itself runs in interactive.zsh)
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' menu select
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}        # colorize menu; also picked up by fzf-tab
zstyle ':completion:*' rehash true                           # find newly-installed executables without a restart
zstyle ':completion:*' accept-exact '*(N)'
zstyle ':completion:*' use-cache on
mkdir -p "$HOME/.zsh/cache"
zstyle ':completion:*' cache-path "$HOME/.zsh/cache"

# iTerm2 integration is deliberately opt-in: it is external shell code and is
# no longer downloaded by the installer. Install it through iTerm2, then set
# LEOS_ENABLE_ITERM2_INTEGRATION=1 if you want this profile to source it.
[[ ${LEOS_ENABLE_ITERM2_INTEGRATION:-0} == 1 && -r $HOME/.iterm2_shell_integration.zsh ]] && \
  source "$HOME/.iterm2_shell_integration.zsh"

:
