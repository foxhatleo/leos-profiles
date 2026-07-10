#!/usr/bin/env zsh

emulate -L zsh
setopt err_return no_unset pipe_fail

root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    [[ "$LEOS_PROFILES" == "$LEOS_PROFILES_HOME" ]]
    (( $+functions[bye] ))
    [[ ${aliases[ls]:-} == "ls --color=auto" || ${aliases[ls]:-} == "ls -G" || ${aliases[ls]:-} == "eza --color=auto --group-directories-first" ]]
    [[ "$STARSHIP_CONFIG" == "$LEOS_PROFILES_HOME/zsh/starship.toml" ]]
  ' || fail 'default themed profile'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" LEOS_PLAIN_PROMPT=1 TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    [[ "$STARSHIP_CONFIG" == "$LEOS_PROFILES_HOME/zsh/starship-plain.toml" ]]
  ' || fail 'plain Starship profile'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" LEOS_DISABLE_ALIASES=1 TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    unset LC_ALL
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    (( ! $+aliases[ls] ))
    (( ! $+aliases[grep] ))
    [[ -z ${LC_ALL:-} ]]
  ' || fail 'alias opt-out and locale preservation'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail
  thefuck() { print "alias fuck=\047true\047"; }
  source "$LEOS_TEST_ROOT/zsh/path/thefuck.zsh"
  fuck first-call
' || fail 'lazy thefuck first invocation'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    uname() { print -r -- Darwin; }
    sudo() { command "$@"; }
    mkdir -p "$HOME/metadata-one" "$HOME/metadata-two"
    : > "$HOME/metadata-one/.DS_Store"
    : > "$HOME/metadata-two/Thumbs.db"
    rmdsstore --dry-run "$HOME/metadata-one" "$HOME/metadata-two"
    [[ -e $HOME/metadata-one/.DS_Store && -e $HOME/metadata-two/Thumbs.db ]]
  ' || fail 'multi-root metadata cleanup wrapper'

LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail
  typeset -a loaded
  entry() { loaded+=("$1"); }
  source "$LEOS_TEST_ROOT/zsh/entries.zsh"
  [[ ${loaded[-3]} == commands && ${loaded[-2]} == _private && ${loaded[-1]} == interactive ]]
' || fail 'private override load order'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    mkdir -p "$HOME/insecure-completions"
    chmod 777 "$HOME/insecure-completions"
    fpath=("$HOME/insecure-completions" $fpath)
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh" 2>/dev/null
    (( $+functions[compdef] ))
  ' || fail 'insecure completion path handling'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$root/zsh" PATH=/usr/bin:/bin TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    puts-err() { :; }
    entry() { :; }
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ $PROMPT == *"%n@%m"* ]]
  ' || fail 'missing-Starship fallback prompt'

print -r -- 'profile tests: PASS'
