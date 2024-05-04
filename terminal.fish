# Leo's Profiles
# Terminal
#
# This script sets up the terminal environment in fish shell.

# Languages
set -gx LC_ALL en_GB.UTF-8
set -gx LANG en_GB.UTF-8

# Term colours
set -gx CLICOLOR 1
set -gx LSCOLORS gxBxhxDxfxhxhxhxhxcxcx
set -gx LS_COLORS 'di=36:ln=1;31:so=37:pi=1;33:ex=35:bd=37:cd=37:su=37:sg=37:tw=32:ow=32'

# Editor
set -gx EDITOR nano

# Colourful term output
alias ls 'ls --color=auto'
alias grep 'grep --color=auto'
alias fgrep 'fgrep --color=auto'
alias egrep 'egrep --color=auto'

# iTerm2 shell integration (assumes you have a similar integration file for fish)
if test -e "$HOME/.iterm2_shell_integration.fish"
    source $HOME/.iterm2_shell_integration.fish
end

# Settings that are typically not directly available or required in fish due to different handling:

# Fish has natural support for colors with ls and grep. These aliases are here for familiarity.
# Fish does not support zstyle, setopt, or the extensive completion system similar to Zsh directly.
# Fish has a different history mechanism, which auto-merges and manages duplicates more cleanly by default.
# Fish has some similar behavior like auto-correct and extended globbing but handled differently.

# Case-insensitive completions are default in fish, customization can be done using `complete` command.
# Fish's globbing is case insensitive by default and it does not beep.
# Some Zsh-specific features are not directly transferrable to fish and are best managed through fish's native capabilities.
