#!/usr/bin/env zsh

emulate -L zsh
setopt err_return no_unset pipe_fail

root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }

# interactive.zsh resolves starship through $commands (it needs the binary's path
# for the cached init), and $commands never sees a shell function — so blocks that
# expect starship to be present need a real executable on PATH, not a stub.
mkdir -p "$tmp/fakebin"
print -rl -- '#!/bin/sh' 'case "$1" in' '  init) printf ":\n" ;;' '  prompt) printf "%s" "fake> " ;;' 'esac' \
  > "$tmp/fakebin/starship"
chmod +x "$tmp/fakebin/starship"
# Likewise opencode: ai-checkup decides brew-managed vs self-installed from
# $commands[opencode], which a shell function never populates, so the host's real
# (Homebrew) copy would otherwise decide the branch — and could really be upgraded.
print -rl -- '#!/bin/sh' 'printf "%s\n" "opencode $*" >> "$AI_LOG"' > "$tmp/fakebin/opencode"
chmod +x "$tmp/fakebin/opencode"
fakepath="$tmp/fakebin:$PATH"

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
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

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" LEOS_PLAIN_PROMPT=1 TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    [[ "$STARSHIP_CONFIG" == "$LEOS_PROFILES_HOME/zsh/starship-plain.toml" ]]
  ' || fail 'plain Starship profile'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" LEOS_DISABLE_ALIASES=1 TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    unset LC_ALL
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

HOME="$tmp/yarn-home" LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail
  mkdir -p "$HOME/.yarn/bin"
  yarn() { : > "$HOME/yarn-spawned"; }        # node.zsh must never invoke yarn
  typeset -ga path=()
  add-path() { [[ -d $1 ]] && path=("$1" $path); return 0; }
  source "$LEOS_TEST_ROOT/zsh/path/node.zsh"
  (( ${path[(Ie)$HOME/.yarn/bin]} ))          # ~/.yarn/bin was added from disk
  [[ ! -e $HOME/yarn-spawned ]]               # ...without spawning a Node process
' || fail "node.zsh adds ~/.yarn/bin from disk without spawning yarn"

# Fake npm/pnpm/bun ahead of the real ones on PATH, so the spawn count below
# measures only this profile's behaviour and never the host's package managers.
HOME="$tmp/pm-home" LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail
  mkdir -p "$HOME/bin"
  for tool in npm pnpm bun; do
    print -r -- "#!/bin/sh
printf %s\\\\n \"\$0 \$*\" >> \"\$HOME/spawns\"
printf %s\\\\n \"_${tool}_stub() { :; }\"
printf %s\\\\n \"compdef _${tool}_stub ${tool}\"" > "$HOME/bin/$tool"
    chmod +x "$HOME/bin/$tool"
  done
  path=("$HOME/bin" $path)
  add-path() { return 0; }
  puts()     { : ; }
  puts-err() { print -u2 -r -- "$*"; }
  compdef() { : ; }                             # stand in for the completion system
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"        # leos-source-cached lives here
  source "$LEOS_TEST_ROOT/zsh/path/node.zsh"
  leos-node-completions
  (( $+functions[_npm_stub] && $+functions[_pnpm_stub] && $+functions[_bun_stub] ))
  [[ $(wc -l < "$HOME/spawns") -eq 3 ]]
  grep -q -- "npm completion$" "$HOME/spawns"
  grep -q -- "pnpm completion zsh$" "$HOME/spawns"
  grep -q -- "bun completions$" "$HOME/spawns"
  unset -f _npm_stub _pnpm_stub _bun_stub
  leos-node-completions                         # second shell: cache hit only
  (( $+functions[_npm_stub] && $+functions[_pnpm_stub] && $+functions[_bun_stub] ))
  [[ $(wc -l < "$HOME/spawns") -eq 3 ]]
' || fail "node.zsh caches npm/pnpm/bun completions without respawning them"

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    uname() { print -r -- Darwin; }
    sudo() { command "$@"; }
    mkdir -p "$HOME/metadata-one" "$HOME/metadata-two"
    : > "$HOME/metadata-one/.DS_Store"
    : > "$HOME/metadata-two/Thumbs.db"
    rmdsstore --dry-run "$HOME/metadata-one" "$HOME/metadata-two"
    [[ -e $HOME/metadata-one/.DS_Store && -e $HOME/metadata-two/Thumbs.db ]]
  ' || fail 'multi-root metadata cleanup wrapper'

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    uname() { print -r -- Darwin; }
    typeset -g SUDO_LOG="$HOME/sudo-args"
    sudo() { print -r -- "$*" > "$SUDO_LOG"; }    # capture the full sudo argv
    rmdsstore --dry-run "$HOME" >/dev/null 2>&1
    [[ "$(<$SUDO_LOG)" == "/usr/bin/python3 -I "* ]]
  ' || fail 'rmdsstore must run the pinned, isolated system python under sudo, not a PATH-resolved one'

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
# 600 is the mode a secrets file is supposed to have, and the mode the installer
# enforces; a laxer fixture would trip the permission warning asserted below.
chmod 600 "$tmp/profile/local/private.zsh"
LEOS_TEST_ROOT="$tmp/profile" zsh -dfc '
  setopt err_return no_unset pipe_fail
  entry() { :; }
  puts-err() { print -u2 -r -- "$*"; }
  LEOS_PROFILES="$LEOS_TEST_ROOT"
  source "$LEOS_TEST_ROOT/zsh/entries.zsh"
  [[ $LEOS_PRIVATE_LOADED == yes ]]
' || fail 'local private override'

# A secrets file readable beyond its owner must be reported, and must still load
# (warn, never silently drop the override or rewrite the user's mode).
for mode in 600 640 604 644; do
  chmod $mode "$tmp/profile/local/private.zsh"
  private_warning=$(LEOS_TEST_ROOT="$tmp/profile" zsh -dfc '
    setopt err_return no_unset pipe_fail
    entry() { :; }
    puts-err() { print -u2 -r -- "$*"; }
    LEOS_PROFILES="$LEOS_TEST_ROOT"
    source "$LEOS_TEST_ROOT/zsh/entries.zsh"
    [[ $LEOS_PRIVATE_LOADED == yes ]]
  ' 2>&1) || fail "private override errored at mode $mode"
  if [[ $mode == 600 ]]; then
    [[ $private_warning != *"readable beyond its owner"* ]] || fail 'mode 600 private.zsh warned anyway'
  else
    [[ $private_warning == *"readable beyond its owner"* ]] || fail "mode $mode private.zsh did not warn"
  fi
done
chmod 600 "$tmp/profile/local/private.zsh"

# brew-china-enable snapshots three HOMEBREW_* vars and must restore them exactly
# when `brew update` fails — including restoring "was not set" as unset, not "".
# This needs a real brew on disk, not a shell function: brew.zsh resolves
# __leos_brew_bin and sources the shellenv output through the init cache.
mkdir -p "$tmp/brewhome/bin"
print -rl -- '#!/bin/sh' 'case "$1" in' \
  '  shellenv) printf "%s\\n" "export HOMEBREW_PREFIX=/fake/brew" ;;' \
  '  update) exit "${FAKE_BREW_UPDATE_STATUS:-0}" ;;' \
  'esac' > "$tmp/brewhome/bin/brew"
chmod +x "$tmp/brewhome/bin/brew"

for preset in unset preset; do
  HOME="$tmp/brewhome" LEOS_TEST_ROOT="$root" BREW_PRESET="$preset" zsh -dfc '
    setopt err_return no_unset pipe_fail
    path=("$HOME/bin" $path)
    puts() { :; }; puts-err() { :; }
    add-path() { return 0; }
    __leos_brew_bin() { print -r -- "$HOME/bin/brew"; }   # from start.zsh
    LEOS_PROFILES="$HOME/profile"; mkdir -p "$LEOS_PROFILES/local/flags"
    source "$LEOS_TEST_ROOT/zsh/cache.zsh"
    source "$LEOS_TEST_ROOT/zsh/path/brew.zsh"
    if [[ $BREW_PRESET == preset ]]; then
      export HOMEBREW_BOTTLE_DOMAIN=https://prior.example
    fi
    export FAKE_BREW_UPDATE_STATUS=1   # a child process must see it
    ! brew-china-enable --yes                     # must report the failure
    # A failed enable must neither write the flag nor leave mirror env behind.
    [[ ! -e $LEOS_PROFILES/local/flags/brew-china ]]
    if [[ $BREW_PRESET == preset ]]; then
      [[ $HOMEBREW_BOTTLE_DOMAIN == https://prior.example ]]
    else
      (( ! ${+HOMEBREW_BOTTLE_DOMAIN} ))          # unset must stay unset, not ""
    fi
    (( ! ${+HOMEBREW_BREW_GIT_REMOTE} ))
    (( ! ${+HOMEBREW_API_DOMAIN} ))
  ' || fail "brew-china-enable rollback preserves prior env ($preset)"
done

HOME="$tmp/brewhome" LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail
  path=("$HOME/bin" $path)
  puts() { :; }; puts-err() { :; }
  add-path() { return 0; }
  __leos_brew_bin() { print -r -- "$HOME/bin/brew"; }     # from start.zsh
  LEOS_PROFILES="$HOME/profile"; mkdir -p "$LEOS_PROFILES/local/flags"
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/path/brew.zsh"
  export FAKE_BREW_UPDATE_STATUS=0
  brew-china-enable --yes
  [[ -f $LEOS_PROFILES/local/flags/brew-china ]]          # flag recorded
  [[ $HOMEBREW_BOTTLE_DOMAIN == *mirrors.ustc.edu.cn* ]]  # mirror env exported
' || fail 'brew-china-enable records the flag and exports the mirrors on success'

# add-path's dedup escapes pattern metacharacters. zsh only reinterprets an
# expanded value as a pattern under GLOB_SUBST, so the test sets it explicitly:
# without the escaping this is where a directory named `a[1]` evicts `a1`.
mkdir -p "$tmp/globroot/zsh" "$tmp/globdirs/a[1]/bin" "$tmp/globdirs/a1/bin" "$tmp/globdirs/keep/bin"
cp "$root/zsh/start.zsh" "$root/zsh/cache.zsh" "$tmp/globroot/zsh/"
: > "$tmp/globroot/zsh/entries.zsh"          # keep start.zsh from loading the world
HOME="$tmp/globroot" LEOS_PROFILES_HOME="$tmp/globroot" GLOBDIRS="$tmp/globdirs" zsh -dfc '
  setopt err_return no_unset pipe_fail
  source "$LEOS_PROFILES_HOME/zsh/start.zsh"
  setopt glob_subst
  typeset -ga path=("$GLOBDIRS/keep/bin" "$GLOBDIRS/a1/bin")
  add-path "$GLOBDIRS/a[1]/bin"
  (( $#path == 3 ))                                     # added, nothing evicted
  (( ${path[(ie)$GLOBDIRS/a1/bin]}   <= $#path ))       # sibling survived
  (( ${path[(ie)$GLOBDIRS/keep/bin]} <= $#path ))
  add-path "$GLOBDIRS/a[1]/bin"
  (( $#path == 3 ))                                     # re-adding dedups
' || fail 'add-path escapes glob metacharacters when deduping'

# Completion-registering entries must load from interactive.zsh (after compinit),
# never from entries.zsh (the PATH phase), where `compdef` does not exist yet and
# their registrations silently no-op.
LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail
  typeset -a loaded
  entry() { loaded+=("$1"); }
  LEOS_PROFILES="$LEOS_TEST_ROOT"
  source "$LEOS_TEST_ROOT/zsh/entries.zsh"
  for late in path/fzf path/zoxide path/gcloud-completion; do
    (( ! ${loaded[(Ie)$late]} )) || {
      print -u2 -r -- "$late is loaded during the PATH phase"; exit 1
    }
  done
' || fail 'compdef-registering entries must not load from entries.zsh'

LEOS_TEST_ROOT="$root" LEOS_PROFILES_ZSH="$root/zsh" zsh -dfc '
  setopt err_return no_unset pipe_fail
  typeset -a loaded
  entry() { loaded+=("$1"); }
  puts-err() { :; }
  autoload -Uz compinit compaudit
  compinit() { : ; }
  compaudit() { : ; }
  _leos_plugin() { :; }
  source "$LEOS_PROFILES_ZSH/cache.zsh"     # interactive.zsh uses leos-source-cached
  source "$LEOS_PROFILES_ZSH/interactive.zsh"
  for late in path/fzf path/zoxide path/gcloud-completion; do
    (( ${loaded[(Ie)$late]} )) || {
      print -u2 -r -- "$late is not loaded by interactive.zsh"; exit 1
    }
  done
' || fail 'interactive.zsh must load the compdef-registering entries'

# zoxide registers its `cd` completion with a compdef guarded on compdef being
# defined, so a load before compinit loses it with no error at all.
HOME="$tmp/zoxide-home" LEOS_TEST_ROOT="$root" zsh -dfc '
  setopt err_return no_unset pipe_fail
  mkdir -p "$HOME/bin"
  print -rl -- "#!/bin/sh" \
    "printf %s\\\\n \"__zoxide_cd() { :; }\"" \
    "printf %s\\\\n \"[[ \\\"\\\${+functions[compdef]}\\\" -ne 0 ]] && compdef __zoxide_z_complete cd\"" \
    > "$HOME/bin/zoxide"
  chmod +x "$HOME/bin/zoxide"
  path=("$HOME/bin" $path)
  puts-err() { print -u2 -r -- "$*"; }
  typeset -g COMPDEF_LOG=""
  compdef() { COMPDEF_LOG="$*"; }          # capture the registration argv
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/path/zoxide.zsh"
  [[ $COMPDEF_LOG == "__zoxide_z_complete cd" ]] || {
    print -u2 -r -- "zoxide compdef not registered: ${COMPDEF_LOG:-<none>}"; exit 1
  }
' || fail 'zoxide registers its cd completion when loaded after compinit'

# Fresh HOME: earlier blocks leave a valid .zcompdump in $tmp, and a cached
# dump lets even pre-compaudit code pass this test via the compinit -C path.
insecure_home=$(mktemp -d)
HOME="$insecure_home" ZDOTDIR="$insecure_home" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    mkdir -p "$HOME/insecure-completions"
    chmod 777 "$HOME/insecure-completions"
    fpath=("$HOME/insecure-completions" $fpath)
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

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$root/zsh" TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    puts-err() { :; }
    entry() { :; }
    compinit() { return 1 }   # a defined function survives autoload -Uz
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ -n ${STARSHIP_CONFIG:-} ]]
  ' || fail 'startup resilient when compinit fails'

flag_root=$(mktemp -d)
mkdir -p "$flag_root/zsh" "$flag_root/local/flags"
cp "$root/zsh/interactive.zsh" "$flag_root/zsh/interactive.zsh"
: > "$flag_root/local/flags/no-starship-warning"
warning_output=$(HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$flag_root/zsh" PATH=/usr/bin:/bin TERM=xterm-256color \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    puts-err() { print -r -- "WARN: $*"; }
    entry() { :; }
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ $PROMPT == *"%n@%m"* ]]
  ' 2>&1) || fail 'silenced-warning block errored'
[[ $warning_output != *"Starship is not installed"* ]] || fail 'no-starship-warning flag did not silence the warning'
rm -rf "$flag_root"

HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$tmp/empty-zsh" LEOS_TEST_ROOT="$root" TERM=xterm-256color PATH="$fakepath" \
  zsh -dfc '
    setopt err_return no_unset pipe_fail
    mkdir -p "$LEOS_PROFILES_ZSH"
    puts-err() { :; }
    entry() { :; }
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

HOME="$tmp/ai-home" LEOS_TEST_ROOT="$root" AI_LOG="$tmp/ai-log" PATH="$fakepath" \
  HOMEBREW_PREFIX="$tmp/not-a-real-brew" zsh -dfc '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  claude() { print -r -- "claude $*" >> "$AI_LOG"; }
  codex() { print -r -- "codex $*" >> "$AI_LOG"; }
  npm() { print -r -- BAD >> "$AI_LOG"; return 1; }
  source "$LEOS_TEST_ROOT/zsh/commands.zsh"
  ai-checkup
  [[ "$(<$AI_LOG)" == $'"'"'claude update\ncodex update\nopencode upgrade'"'"' ]]
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
