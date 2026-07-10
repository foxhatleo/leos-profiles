#!/usr/bin/env zsh

emulate -LR zsh
setopt err_return no_unset pipe_fail

root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color \
  zsh -dfc '
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    [[ "$LEOS_PROFILES" == "$LEOS_PROFILES_HOME" ]]
    (( $+functions[bye] ))
    [[ ${aliases[ls]} == "ls --color=auto" || ${aliases[ls]} == "eza --color=auto --group-directories-first" ]]
    [[ "$STARSHIP_CONFIG" == "$LEOS_PROFILES_HOME/zsh/starship.toml" ]]
  '

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" LEOS_PLAIN_PROMPT=1 TERM=xterm-256color \
  zsh -dfc '
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    [[ "$STARSHIP_CONFIG" == "$LEOS_PROFILES_HOME/zsh/starship-plain.toml" ]]
  '

HOME="$tmp" ZDOTDIR="$tmp" LEOS_TEST_ROOT="$root" zsh -dfc '
  thefuck() { print "alias fuck=\047true\047"; }
  source "$LEOS_TEST_ROOT/zsh/path/thefuck.zsh"
  fuck first-call
'

print -r -- 'profile tests: PASS'
