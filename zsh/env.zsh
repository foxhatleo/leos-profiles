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
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# History — fish-like: shared, dedup, trimmed
HISTFILE=$HOME/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS INC_APPEND_HISTORY

# Interactive behavior
setopt AUTO_CD EXTENDED_GLOB INTERACTIVE_COMMENTS NO_BEEP

# Completion styling (compinit itself runs in interactive.zsh)
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' menu select

# iTerm2 shell integration
[[ -e $HOME/.iterm2_shell_integration.zsh ]] && source "$HOME/.iterm2_shell_integration.zsh"
