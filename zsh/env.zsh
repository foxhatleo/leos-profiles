# Leo's Profiles — terminal environment (zsh)

# Locale
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Term colors
export CLICOLOR=1
export LSCOLORS=gxBxhxDxfxhxhxhxhxcxcx
export LS_COLORS='di=36:ln=1;31:so=37:pi=1;33:ex=35:bd=37:cd=37:su=37:sg=37:tw=32:ow=32'

# Editor
export EDITOR=nano

# Colorful output (GNU ls/grep; on macOS GNU tools are placed on PATH by path/gnu.zsh)
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --color=auto --group-directories-first'
else
  alias ls='ls --color=auto'
fi
command -v bat >/dev/null 2>&1 && alias cat='bat --style=plain --paging=never'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

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

# iTerm2 shell integration
[[ -e $HOME/.iterm2_shell_integration.zsh ]] && source "$HOME/.iterm2_shell_integration.zsh"
