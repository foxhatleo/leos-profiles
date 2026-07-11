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
    [[ "$LEOS_PROFILES" == "$LEOS_PROFILES_HOME" ]] || { print -u2 -r -- "profile root mismatch: $LEOS_PROFILES"; exit 1; }
    (( $+functions[bye] )) || { print -u2 -r -- "bye function was not loaded"; exit 1; }
    [[ ${aliases[ls]:-} == "ls --color=auto" || ${aliases[ls]:-} == "ls -G" || ${aliases[ls]:-} == "eza --color=auto --group-directories-first" ]] || {
      print -u2 -r -- "unexpected ls alias: ${aliases[ls]:-(unset)}"; exit 1
    }
    [[ "$STARSHIP_CONFIG" == "$LEOS_PROFILES_HOME/zsh/starship.toml" ]] || {
      print -u2 -r -- "themed Starship config mismatch: ${STARSHIP_CONFIG:-unset}"; exit 1
    }
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
  LEOS_PROFILES="$LEOS_TEST_ROOT"
  source "$LEOS_TEST_ROOT/zsh/entries.zsh"
  [[ ${loaded[-2]} == commands && ${loaded[-1]} == interactive ]]
' || fail 'private override load order'

mkdir -p "$tmp/profile/local" "$tmp/profile/zsh"
cp "$root/zsh/entries.zsh" "$tmp/profile/zsh/entries.zsh"
print -r -- 'typeset -g LEOS_PRIVATE_LOADED=yes' > "$tmp/profile/local/private.zsh"
LEOS_TEST_ROOT="$tmp/profile" zsh -dfc '
  setopt err_return no_unset pipe_fail
  entry() { :; }
  LEOS_PROFILES="$LEOS_TEST_ROOT"
  source "$LEOS_TEST_ROOT/zsh/entries.zsh"
  [[ $LEOS_PRIVATE_LOADED == yes ]]
' || fail 'local private override'

# Fresh HOME: earlier blocks leave a valid .zcompdump in $tmp, and a cached
# dump lets even pre-compaudit code pass this test via the compinit -C path.
insecure_home=$(mktemp -d)
HOME="$insecure_home" ZDOTDIR="$insecure_home" LEOS_PROFILES_HOME="$root" TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    mkdir -p "$HOME/insecure-completions"
    chmod 777 "$HOME/insecure-completions"
    fpath=("$HOME/insecure-completions" $fpath)
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_PROFILES_HOME/zsh/start.zsh" 2>/dev/null
    (( $+functions[compdef] ))
  ' </dev/null || fail 'insecure completion path handling'
rm -rf "$insecure_home"

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$root/zsh" PATH=/usr/bin:/bin TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    puts-err() { :; }
    entry() { :; }
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ $PROMPT == *"%n@%m"* ]]
  ' || fail 'missing-Starship fallback prompt'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$root/zsh" TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    puts-err() { :; }
    entry() { :; }
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    compinit() { return 1 }   # a defined function survives autoload -Uz
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ -n ${STARSHIP_CONFIG:-} ]]
  ' || fail 'startup resilient when compinit fails'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$tmp/empty-zsh" LEOS_TEST_ROOT="$root" TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    mkdir -p "$LEOS_PROFILES_ZSH"
    puts-err() { :; }
    entry() { :; }
    starship() { [[ $1 == init ]] && print -r -- ":"; }
    source "$LEOS_TEST_ROOT/zsh/interactive.zsh" 2>/dev/null
    [[ $STARSHIP_CONFIG == "$LEOS_PROFILES_ZSH/starship.toml" ]]
  ' || fail 'clean checkout without cloned plugins'

HOME="$tmp/history-home" LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail extended_glob
  mkdir -p "$HOME/.directory_history"
  : > "$HOME/.zsh_history"
  : > "$HOME/.legacy_history"
  HISTFILE="$HOME/.zsh_history"
  puts() { :; }; puts-err() { :; }; fc() { :; }
  source "$LEOS_TEST_ROOT/zsh/commands.zsh"
  clear-history
  [[ ! -s $HOME/.zsh_history && -e $HOME/.legacy_history && -d $HOME/.directory_history ]]
  clear-history --aggressive
  [[ ! -e $HOME/.legacy_history && -d $HOME/.directory_history ]]
' || fail 'safe and aggressive history boundaries'

HOME="$tmp/ai-home" LEOS_TEST_ROOT="$root" AI_LOG="$tmp/ai-log" zsh -dfc '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  claude() { print -r -- "claude $*" >> "$AI_LOG"; }
  codex() { print -r -- "codex $*" >> "$AI_LOG"; }
  npm() { print -r -- BAD >> "$AI_LOG"; return 1; }
  source "$LEOS_TEST_ROOT/zsh/commands.zsh"
  ai-checkup
  [[ "$(<$AI_LOG)" == $'"'"'claude update\ncodex update'"'"' ]]
  ! bye --shutdown-wsl --no-exit >/dev/null 2>&1
' || fail 'native AI updates and contradictory bye options'

mkdir -p "$tmp/updater-profile" "$tmp/fake-bin"
: > "$tmp/updater-profile/install.sh"
print -rl -- '#!/bin/sh' 'printf "%s\n" "$*" > "$UPGRADE_LOG"' > "$tmp/fake-bin/bash"
chmod +x "$tmp/fake-bin/bash"
HOME="$tmp/updater-home" PATH="$tmp/fake-bin:$PATH" LEOS_TEST_ROOT="$root" LEOS_PROFILES="$tmp/updater-profile" UPGRADE_LOG="$tmp/upgrade-log" zsh -dfc '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  git() {
    case "$*" in
      *"symbolic-ref --quiet --short HEAD"*) print -r -- feature ;;
      *"rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) print -r -- fork/feature ;;
      *"status --porcelain"*) [[ -z ${DIRTY:-} ]] || print -r -- " M local-edit"; return 0 ;;
      *"pull --ff-only"*) return 0 ;;
      *) return 1 ;;
    esac
  }
  source "$LEOS_TEST_ROOT/zsh/commands.zsh"
  upgrade-leos-profiles --full-upgrade
  [[ "$(<$UPGRADE_LOG)" == "$LEOS_PROFILES/install.sh reconcile --yes --full-upgrade" ]]
  DIRTY=1
  ! upgrade-leos-profiles >/dev/null 2>&1
' || fail 'configured-upstream reconciliation'

print -r -- 'profile tests: PASS'
