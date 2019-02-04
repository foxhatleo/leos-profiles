# Languages
export LC_ALL=en_GB.UTF-8
export LANG=en_GB.UTF-8

# Term colours
export CLICOLOR=1
export LSCOLORS=gxBxhxDxfxhxhxhxhxcxcx
export LS_COLORS="di=36:ln=1;31:so=37:pi=1;33:ex=35:bd=37:cd=37:su=37:sg=37:tw=32:ow=32"
zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}

# Colourful term output
alias ls="ls --color=auto -N"
alias grep="grep --color=auto"
alias fgrep="fgrep --color=auto"
alias egrep="egrep --color=auto"

# Correction
setopt correct
setopt correct_all

# iTerm2 shell integration
test -e "${HOME}/.iterm2_shell_integration.zsh" && source "${HOME}/.iterm2_shell_integration.zsh"
