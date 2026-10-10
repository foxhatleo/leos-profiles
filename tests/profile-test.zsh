#!/usr/bin/env zsh

# Re-exec before loading fixtures so inherited tool roots, XDG paths, function
# exports and private shell configuration cannot reach the test process.
if [[ ${1:-} != --isolated ]]; then
  exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/zsh \
    "${commands[zsh]:-/bin/zsh}" -df "$0" --isolated
fi

emulate -L zsh
setopt err_return no_unset pipe_fail

source_root=${0:A:h:h}
tmp=$(mktemp -d)
export HOME=$tmp
root=$tmp/runtime
mkdir -p "$root/zsh" "$root/util" "$root/local/flags"
cp "$source_root"/zsh/*.zsh "$source_root"/zsh/*.toml "$root/zsh/"
cp -R "$source_root/zsh/path" "$root/zsh/path"
# Include the actual installed plugin code, but never the repository's private
# overrides. Plugin availability remains optional for clean-checkout testing.
[[ ! -d $source_root/zsh/plugins ]] || cp -R "$source_root/zsh/plugins" "$root/zsh/plugins"
cp "$source_root/util/rmdsstore.py" "$root/util/"
# Rehash is an asynchronous maintenance side effect, not part of these profile
# assertions. Disable it in the temporary fixture so no detached writer can
# outlive the shell or race removal of its HOME.
print -r -- '__leos_rehash_daily() { :; }' >> "$root/zsh/cache.zsh"
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
# Shadow tools that may exist even in /usr/bin on Linux; no generator or rehash
# in this suite is allowed to invoke a developer's installed version manager.
for tool in pyenv rbenv fnm direnv zoxide npm pnpm bun heroku; do
  print -rl -- '#!/bin/sh' 'printf ":\\n"' > "$tmp/fakebin/$tool"
  chmod +x "$tmp/fakebin/$tool"
done
print -rl -- '#!/bin/sh' 'case "$1" in' \
  ' shellenv) printf "export HOMEBREW_PREFIX=%s\\n" "$HOME/fake-brew" ;;' \
  ' --prefix) printf "%s\\n" "$HOME/fake-brew" ;;' \
  ' *) exit 91 ;;' 'esac' > "$tmp/fakebin/brew"
chmod +x "$tmp/fakebin/brew"
# thefuck must be absent except where a test supplies its own implementation.
print -rl -- '#!/bin/sh' 'exit 1' > "$tmp/fakebin/thefuck"
chmod +x "$tmp/fakebin/thefuck"
# Make the system Zsh reachable on platforms where it is outside /usr/bin.
ln -s "${commands[zsh]:-/bin/zsh}" "$tmp/fakebin/zsh"
fakepath="$tmp/fakebin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH=$fakepath
zsh_bin=${commands[zsh]:-/bin/zsh}

# run_block <label> [NAME=value ...] -- <script>
#
# Run <script> with `zsh -dfc` in the given environment (stdin from /dev/null)
# and fail unless the block exits 0 AND reaches a sentinel appended after its
# last line. The exit status alone proves nothing: a shell error such as an
# unmatched glob, or an unset parameter under NO_UNSET (including one inside a
# function's `local` assignment), aborts `zsh -c` with status 0, so a block
# could skip its remaining assertions and still pass. The block's combined
# output, minus the sentinel, is left in $block_out for diagnostic assertions.
typeset -g block_out=
run_block() {
  local label=$1 sentinel="__leos_block_reached_end_$$" st=0 reached=yes
  shift
  local -a assignments=()
  while (( $# )) && [[ $1 != -- ]]; do assignments+=("$1"); shift; done
  (( $# == 2 )) || fail "run_block $label: expected [NAME=value ...] -- <script>"
  block_out=$(/usr/bin/env "${assignments[@]}" "$zsh_bin" -dfc "$2"$'\n'"print -r -- $sentinel" \
    2>&1 </dev/null) || st=$?
  [[ $block_out == *$sentinel* ]] || reached=no
  block_out=${block_out//$sentinel/}
  (( st == 0 )) && [[ $reached == yes ]] ||
    fail "$label (exit $st, reached end: $reached): $block_out"
}

run_block 'default themed profile' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" -- '
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
  '

run_block 'plain Starship profile' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" LEOS_PLAIN_PROMPT=1 TERM=xterm-256color PATH="$fakepath" -- '
    setopt err_return no_unset pipe_fail
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    [[ "$STARSHIP_CONFIG" == "$LEOS_PROFILES_HOME/zsh/starship-plain.toml" ]]
  '

run_block 'alias opt-out and locale preservation' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" LEOS_DISABLE_ALIASES=1 TERM=xterm-256color PATH="$fakepath" -- '
    setopt err_return no_unset pipe_fail
    unset LC_ALL
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    (( ! $+aliases[ls] ))
    (( ! $+aliases[grep] ))
    [[ -z ${LC_ALL:-} ]]
  '

run_block 'lazy thefuck first invocation' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_TEST_ROOT="$root" -- '
  setopt err_return no_unset pipe_fail
  thefuck() { print "alias fuck=\047true\047"; }
  source "$LEOS_TEST_ROOT/zsh/path/thefuck.zsh"
  fuck first-call
'

run_block 'node.zsh adds ~/.yarn/bin from disk without spawning yarn' \
  HOME="$tmp/yarn-home" LEOS_TEST_ROOT="$root" -- '
  setopt err_return no_unset pipe_fail
  mkdir -p "$HOME/.yarn/bin"
  yarn() { : > "$HOME/yarn-spawned"; }        # node.zsh must never invoke yarn
  typeset -ga path=()
  add-path() { [[ -d $1 ]] && path=("$1" $path); return 0; }
  source "$LEOS_TEST_ROOT/zsh/path/node.zsh"
  (( ${path[(Ie)$HOME/.yarn/bin]} ))          # ~/.yarn/bin was added from disk
  [[ ! -e $HOME/yarn-spawned ]]               # ...without spawning a Node process
'

# Fake npm/pnpm/bun ahead of the real ones on PATH, so the spawn count below
# measures only this profile's behaviour and never the host's package managers.
run_block 'node.zsh caches npm/pnpm/bun completions without respawning them' \
  HOME="$tmp/pm-home" LEOS_TEST_ROOT="$root" -- '
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
'

run_block 'multi-root metadata cleanup wrapper' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" -- '
    setopt err_return no_unset pipe_fail
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    uname() { print -r -- Darwin; }
    sudo() { command "$@"; }
    mkdir -p "$HOME/metadata-one" "$HOME/metadata-two"
    : > "$HOME/metadata-one/.DS_Store"
    : > "$HOME/metadata-two/Thumbs.db"
    rmdsstore --dry-run "$HOME/metadata-one" "$HOME/metadata-two"
    [[ -e $HOME/metadata-one/.DS_Store && -e $HOME/metadata-two/Thumbs.db ]]
  '

run_block 'rmdsstore must run the pinned, isolated system python under sudo, not a PATH-resolved one' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" -- '
    setopt err_return no_unset pipe_fail
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    uname() { print -r -- Darwin; }
    typeset -g SUDO_LOG="$HOME/sudo-args"
    sudo() { print -r -- "$*" > "$SUDO_LOG"; }    # capture the full sudo argv
    rmdsstore --dry-run "$HOME" >/dev/null 2>&1
    [[ "$(<$SUDO_LOG)" == "/usr/bin/python3 -I "* ]]
  '

run_block 'entries.zsh ends with the public command layer' LEOS_TEST_ROOT="$root" -- '
  setopt err_return no_unset pipe_fail
  typeset -a loaded
  entry() { loaded+=("$1"); }
  LEOS_PROFILES="$LEOS_TEST_ROOT"
  source "$LEOS_TEST_ROOT/zsh/entries.zsh"
  [[ ${loaded[-2]} == env && ${loaded[-1]} == commands ]]
  (( ! ${loaded[(Ie)interactive]} ))           # start.zsh loads it, after private.zsh
'

# start.zsh's own load structure, against stub layers that record their order.
# The private files use bare declarations on purpose: start.zsh sources them at
# top level, so `typeset -A`, `local` and plain `typeset` must stay global.
mkdir -p "$tmp/profile/local" "$tmp/profile/zsh"
cp "$root/zsh/start.zsh" "$tmp/profile/zsh/start.zsh"
: > "$tmp/profile/zsh/cache.zsh"
print -r -- 'typeset -ga LEOS_ORDER; LEOS_ORDER+=(entries)' > "$tmp/profile/zsh/entries.zsh"
print -r -- 'LEOS_ORDER+=(interactive)' > "$tmp/profile/zsh/interactive.zsh"
print -rl -- 'LEOS_ORDER+=(private)' 'typeset -g LEOS_PRIVATE_LOADED=yes' \
  'typeset -A LEOS_PRIVATE_MAP; LEOS_PRIVATE_MAP[a]=1' 'local LEOS_PRIVATE_LOCAL=kept' \
  'typeset LEOS_PRIVATE_SCALAR=kept' > "$tmp/profile/local/private.zsh"
print -rl -- 'LEOS_ORDER+=(private-interactive)' 'typeset -A LEOS_PI_MAP; LEOS_PI_MAP[b]=2' \
  > "$tmp/profile/local/private-interactive.zsh"
# 600 is the mode a secrets file is supposed to have, and the mode the installer
# enforces; a laxer fixture would trip the permission warning asserted below.
chmod 600 "$tmp/profile/local/private.zsh" "$tmp/profile/local/private-interactive.zsh"

run_block 'start.zsh load order keeps private declarations global' \
  HOME="$tmp" LEOS_PROFILES_HOME="$tmp/profile" TERM=xterm-256color -- '
  setopt err_return no_unset pipe_fail
  source "$LEOS_PROFILES_HOME/zsh/start.zsh"
  [[ ${(j: :)LEOS_ORDER} == "entries private interactive private-interactive" ]] || {
    print -u2 -r -- "load order: ${(j: :)LEOS_ORDER}"; exit 1
  }
  [[ $LEOS_PRIVATE_LOADED == yes && ${LEOS_PRIVATE_MAP[a]} == 1 ]]
  [[ ${(t)LEOS_PRIVATE_MAP} == association ]]
  [[ $LEOS_PRIVATE_LOCAL == kept && $LEOS_PRIVATE_SCALAR == kept ]]
  [[ ${LEOS_PI_MAP[b]} == 2 ]]
'
[[ $block_out != *"readable beyond its owner"* ]] || fail 'mode 600 private files warned anyway'

run_block 'start.zsh loads once per shell' \
  HOME="$tmp" LEOS_PROFILES_HOME="$tmp/profile" TERM=xterm-256color -- '
  setopt err_return no_unset pipe_fail
  source "$LEOS_PROFILES_HOME/zsh/start.zsh"
  source "$LEOS_PROFILES_HOME/zsh/start.zsh"
  (( $#LEOS_ORDER == 4 )) || { print -u2 -r -- "loaded twice: ${(j: :)LEOS_ORDER}"; exit 1; }
  # A nested shell does not inherit the guard, so it still gets its profile.
  [[ $(zsh -dfc "source ${(q)LEOS_PROFILES_HOME}/zsh/start.zsh; print -r -- \${(j: :)LEOS_ORDER}") == *private-interactive ]]
'

run_block 'TERM=dumb keeps PATH and private.zsh but skips the interactive layer' \
  HOME="$tmp" LEOS_PROFILES_HOME="$tmp/profile" TERM=dumb -- '
  setopt err_return no_unset pipe_fail
  source "$LEOS_PROFILES_HOME/zsh/start.zsh"
  [[ ${(j: :)LEOS_ORDER} == "entries private" ]]
  [[ $PS1 == "\$ " && ! -o zle ]]
'

# The root guard itself needs EUID 0; a non-root shell whose HOME it does not
# own (here /) must still load normally.
run_block 'non-root shell with a foreign HOME still loads' \
  HOME=/ LEOS_PROFILES_HOME="$tmp/profile" TERM=xterm-256color -- '
  setopt err_return no_unset pipe_fail
  (( EUID != 0 )) || exit 0
  source "$LEOS_PROFILES_HOME/zsh/start.zsh"
  (( $#LEOS_ORDER == 4 ))
'

# A secrets file readable beyond its owner must be reported, and must still load
# (warn, never silently drop the override or rewrite the user's mode). Both
# private files get the same check.
for private_file in private private-interactive; do
  for mode in 600 640 604 644; do
    chmod $mode "$tmp/profile/local/$private_file.zsh"
    run_block "$private_file.zsh at mode $mode" \
      HOME="$tmp" LEOS_PROFILES_HOME="$tmp/profile" TERM=xterm-256color -- '
      setopt err_return no_unset pipe_fail
      source "$LEOS_PROFILES_HOME/zsh/start.zsh"
      (( $#LEOS_ORDER == 4 ))
    '
    if [[ $mode == 600 ]]; then
      [[ $block_out != *"readable beyond its owner"* ]] || fail "mode 600 $private_file.zsh warned anyway"
    else
      [[ $block_out == *"$private_file.zsh is readable beyond its owner"* ]] ||
        fail "mode $mode $private_file.zsh did not warn"
    fi
  done
  chmod 600 "$tmp/profile/local/$private_file.zsh"
done

# A symlink to a correctly locked file must not warn: mode qualifiers lstat by
# default, and a symlink's own mode is 0777, so the check has to follow links.
mkdir -p "$tmp/symprofile/zsh" "$tmp/symprofile/local" "$tmp/symtarget"
cp "$tmp/profile/zsh/"*.zsh "$tmp/symprofile/zsh/"
print -r -- 'typeset -g LEOS_PRIVATE_LOADED=yes' > "$tmp/symtarget/private.zsh"
ln -sf "$tmp/symtarget/private.zsh" "$tmp/symprofile/local/private.zsh"
for target_mode in 600 644; do
  chmod $target_mode "$tmp/symtarget/private.zsh"
  run_block "symlinked private.zsh at target mode $target_mode" \
    HOME="$tmp" LEOS_PROFILES_HOME="$tmp/symprofile" TERM=xterm-256color -- '
    setopt err_return no_unset pipe_fail
    source "$LEOS_PROFILES_HOME/zsh/start.zsh"
    [[ $LEOS_PRIVATE_LOADED == yes ]]
  '
  if [[ $target_mode == 600 ]]; then
    [[ $block_out != *"readable beyond its owner"* ]] ||
      fail 'a symlink to a 600 private.zsh warned about the link mode'
  else
    [[ $block_out == *"readable beyond its owner"* ]] ||
      fail 'a symlink to a 644 private.zsh did not warn'
  fi
done

# heroku must load BEFORE the other post-compinit entries: its zsh_setup runs a
# second compinit, which discards every compdef registered up to that point.
run_block 'path/heroku loads before the other compdef-registering entries' \
  LEOS_TEST_ROOT="$root" LEOS_PROFILES_ZSH="$root/zsh" -- '
  setopt err_return no_unset pipe_fail
  typeset -a loaded
  entry() { loaded+=("$1"); }
  puts-err() { :; }
  autoload -Uz compinit compaudit
  compinit() { : ; }
  compaudit() { : ; }
  _leos_plugin() { :; }
  source "$LEOS_PROFILES_ZSH/cache.zsh"
  source "$LEOS_PROFILES_ZSH/interactive.zsh"
  h=${loaded[(ie)path/heroku]}
  for other in path/fzf path/zoxide path/gcloud-completion; do
    (( h < ${loaded[(ie)$other]} )) || {
      print -u2 -r -- "path/heroku ($h) must load before $other (${loaded[(ie)$other]})"; exit 1
    }
  done
'

# The init-cache status contract, which every startup file depends on:
#   0  something was sourced — even if the sourced script's own last command was
#      false (heroku's ends in `test -f … && source …`). Getting this wrong sends
#      path/fzf.zsh down a fallback that double-binds its widgets.
#   1  nothing available, first time — worth one message.
#   2  nothing available, already reported — stay silent.
# leos-source-cached-warn must additionally always return 0, because a non-zero
# return from a bare call (or from the right side of `&&`) aborts the calling file
# under ERR_RETURN.
mkdir -p "$tmp/cachehome/bin"
print -rl -- '#!/bin/sh' \
  'printf "%s\n" "typeset -g LEOS_CACHE_SOURCED=yes" "test -f /nonexistent/leos && source /nonexistent/leos"' \
  > "$tmp/cachehome/bin/falsetail"
print -rl -- '#!/bin/sh' 'exit 0' > "$tmp/cachehome/bin/silenttool"
chmod +x "$tmp/cachehome/bin/falsetail" "$tmp/cachehome/bin/silenttool"
run_block 'init-cache status contract and warn-once behaviour' \
  HOME="$tmp/cachehome" LEOS_TEST_ROOT="$root" -- '
  setopt err_return no_unset pipe_fail
  typeset -g WARNINGS=0
  puts() { :; }
  # NOT (( WARNINGS++ )): post-increment yields the old value, so the first
  # call evaluates to 0 and returns status 1, which err_return would treat as
  # a failure inside this stub.
  puts-err() { WARNINGS=$(( WARNINGS + 1 )); }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"

  typeset -g st=0
  leos-source-cached ft "$HOME/bin/falsetail" || st=$?
  (( st == 0 ))                                  # a false last command is still "sourced"
  [[ ${LEOS_CACHE_SOURCED:-no} == yes ]]

  st=0; leos-source-cached et "$HOME/bin/silenttool" || st=$?
  (( st == 1 ))                                  # nothing produced, first time
  st=0; leos-source-cached et "$HOME/bin/silenttool" || st=$?
  (( st == 2 ))                                  # ...and remembered afterwards

  # The -warn wrapper: one message for the fresh failure, none on the repeat,
  # and status 0 every time so a bare call can never abort the caller.
  WARNINGS=0
  leos-source-cached-warn "nope" et2 "$HOME/bin/silenttool"; (( $? == 0 ))
  (( WARNINGS == 1 ))
  leos-source-cached-warn "nope" et2 "$HOME/bin/silenttool"; (( $? == 0 ))
  (( WARNINGS == 1 ))
'

# A generator that yields nothing must not take the rest of the profile down with
# it. This is the ERR_RETURN hazard that `(( guard )) && leos-source-cached …`
# reintroduces: a failing command on the right of && does abort a sourced file.
mkdir -p "$tmp/deadtool/bin"
print -rl -- '#!/bin/sh' 'exit 0' > "$tmp/deadtool/bin/zoxide"
print -rl -- '#!/bin/sh' 'exit 0' > "$tmp/deadtool/bin/direnv"
chmod +x "$tmp/deadtool/bin/zoxide" "$tmp/deadtool/bin/direnv"
for broken in zoxide direnv; do
  run_block "a silent $broken generator must not abort path/$broken.zsh" \
    HOME="$tmp/deadtool" LEOS_TEST_ROOT="$root" BROKEN="$broken" -- '
    setopt err_return no_unset pipe_fail
    path=("$HOME/bin" $path)
    puts() { :; }; puts-err() { :; }
    source "$LEOS_TEST_ROOT/zsh/cache.zsh"
    source "$LEOS_TEST_ROOT/zsh/path/$BROKEN.zsh"   # reaching the sentinel IS the assertion
  '
done

# leos-refresh-init-cache must actually delete the cached scripts (an unmatched
# glob would otherwise abort the whole rm under NOMATCH and clear nothing), leave
# the rehash stamps alone, and cope with awkward filenames. An unmatched glob
# aborts the block yet still exits 0, which is why run_block checks a sentinel.
# Private like the directories the profile creates: under a umask 002 session a
# group-writable fixture would make the profile discard the planted files first.
mkdir -p -m 700 "$tmp/refreshhome/.cache" "$tmp/refreshhome/.cache/leos-profiles" \
  "$tmp/refreshhome/.cache/leos-profiles/init"
run_block 'leos-refresh-init-cache clears init scripts and keeps rehash stamps' \
  HOME="$tmp/refreshhome" LEOS_TEST_ROOT="$root" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  d=$HOME/.cache/leos-profiles/init
  : > "$d/brew-shellenv_x.zsh"
  : > "$d/brew-shellenv_x.zsh.zwc"
  : > "$d/some tool_y.zsh"          # a space in the name must not split
  : > "$d/pyenv-rehash"             # not an init cache; must survive
  leos-refresh-init-cache
  [[ ! -e $d/brew-shellenv_x.zsh && ! -e $d/brew-shellenv_x.zsh.zwc ]]
  [[ ! -e "$d/some tool_y.zsh" ]]
  [[ -e $d/pyenv-rehash ]]
  leos-refresh-init-cache            # idempotent on an already-empty cache
  [[ -e $d/pyenv-rehash ]]
'

# brew-checkup gained a `|| return 1` and a cache-refresh call: it must still
# report success on a clean run, fail when brew fails, and only clear the cache
# when the upgrade actually succeeded.
mkdir -p "$tmp/checkuphome/bin" "$tmp/checkuphome/profile/local/flags"
print -rl -- '#!/bin/sh' 'case "$1" in' \
  '  shellenv) printf "%s\\n" "export HOMEBREW_PREFIX=/fake/brew" ;;' \
  '  update) exit "${FAKE_BREW_UPDATE_STATUS:-0}" ;;' \
  '  *) exit 0 ;;' \
  'esac' > "$tmp/checkuphome/bin/brew"
chmod +x "$tmp/checkuphome/bin/brew"
for expect in success failure; do
  run_block "brew-checkup control flow on $expect" \
    HOME="$tmp/checkuphome" LEOS_TEST_ROOT="$root" EXPECT="$expect" -- '
    setopt no_unset pipe_fail
    path=("$HOME/bin" $path)
    puts() { :; }; puts-err() { :; }
    add-path() { return 0; }
    __leos_brew_bin() { print -r -- "$HOME/bin/brew"; }
    LEOS_PROFILES="$HOME/profile"
    source "$LEOS_TEST_ROOT/zsh/cache.zsh"
    source "$LEOS_TEST_ROOT/zsh/path/brew.zsh"
    d=${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init
    mkdir -p "$d"; : > "$d/marker_x.zsh"
    if [[ $EXPECT == success ]]; then
      export FAKE_BREW_UPDATE_STATUS=0
      brew-checkup >/dev/null 2>&1 || exit 1        # must report success
      [[ ! -e $d/marker_x.zsh ]] || exit 1          # ...and clear the cache
    else
      export FAKE_BREW_UPDATE_STATUS=1
      brew-checkup >/dev/null 2>&1 && exit 1        # must report failure
      [[ -e $d/marker_x.zsh ]] || exit 1            # ...and leave the cache alone
    fi
  '
done

# brew-china-enable snapshots three HOMEBREW_* vars and must restore them exactly
# when `brew update` fails — including restoring "was not set" as unset, not "".
# This needs a real brew on disk, not a shell function: brew.zsh resolves
# __leos_brew_bin and evaluates shellenv output directly.
mkdir -p "$tmp/brewhome/bin"
print -rl -- '#!/bin/sh' 'case "$1" in' \
  '  shellenv) printf "%s\\n" "export HOMEBREW_PREFIX=/fake/brew" ;;' \
  '  update) exit "${FAKE_BREW_UPDATE_STATUS:-0}" ;;' \
  'esac' > "$tmp/brewhome/bin/brew"
chmod +x "$tmp/brewhome/bin/brew"

for preset in unset preset; do
  run_block "brew-china-enable rollback preserves prior env ($preset)" \
    HOME="$tmp/brewhome" LEOS_TEST_ROOT="$root" BREW_PRESET="$preset" -- '
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
  '
done

run_block 'brew-china-enable records the flag and exports the mirrors on success' \
  HOME="$tmp/brewhome" LEOS_TEST_ROOT="$root" -- '
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
'

# add-path's dedup escapes pattern metacharacters. zsh only reinterprets an
# expanded value as a pattern under GLOB_SUBST, so the test sets it explicitly:
# without the escaping this is where a directory named `a[1]` evicts `a1`.
mkdir -p "$tmp/globroot/zsh" "$tmp/globdirs/a[1]/bin" "$tmp/globdirs/a1/bin" "$tmp/globdirs/keep/bin"
cp "$root/zsh/start.zsh" "$root/zsh/cache.zsh" "$tmp/globroot/zsh/"
: > "$tmp/globroot/zsh/entries.zsh"          # keep start.zsh from loading the world
run_block 'add-path escapes glob metacharacters when deduping' \
  HOME="$tmp/globroot" LEOS_PROFILES_HOME="$tmp/globroot" GLOBDIRS="$tmp/globdirs" -- '
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
'

# Completion-registering entries must load from interactive.zsh (after compinit),
# never from entries.zsh (the PATH phase), where `compdef` does not exist yet and
# their registrations silently no-op.
run_block 'compdef-registering entries must not load from entries.zsh' LEOS_TEST_ROOT="$root" -- '
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
'

run_block 'interactive.zsh must load the compdef-registering entries' \
  LEOS_TEST_ROOT="$root" LEOS_PROFILES_ZSH="$root/zsh" -- '
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
  for late in path/fzf path/zoxide path/gcloud-completion path/heroku; do
    (( ${loaded[(Ie)$late]} )) || {
      print -u2 -r -- "$late is not loaded by interactive.zsh"; exit 1
    }
  done
'

# zoxide registers its `cd` completion with a compdef guarded on compdef being
# defined, so a load before compinit loses it with no error at all.
run_block 'zoxide registers its cd completion when loaded after compinit' \
  HOME="$tmp/zoxide-home" LEOS_TEST_ROOT="$root" -- '
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
'

# Fresh HOME: earlier blocks leave a valid .zcompdump in $tmp, and a cached
# dump lets even pre-compaudit code pass this test via the compinit -C path.
insecure_home=$(mktemp -d)
run_block 'insecure completion path handling' \
  HOME="$insecure_home" ZDOTDIR="$insecure_home" LEOS_PROFILES_HOME="$root" TERM=xterm-256color PATH="$fakepath" -- '
    setopt err_return no_unset pipe_fail
    mkdir -p "$HOME/insecure-completions"
    chmod 777 "$HOME/insecure-completions"
    fpath=("$HOME/insecure-completions" $fpath)
    source "$LEOS_PROFILES_HOME/zsh/start.zsh" 2>/dev/null
    (( $+functions[compdef] ))
  '
rm -rf "$insecure_home"

run_block 'missing-Starship fallback prompt' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$root/zsh" PATH=/usr/bin:/bin TERM=xterm-256color -- '
    setopt err_return no_unset pipe_fail
    puts-err() { :; }
    entry() { :; }
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ $PROMPT == *"%n@%m"* ]]
  '

run_block 'startup resilient when compinit fails' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$root/zsh" TERM=xterm-256color PATH="$fakepath" -- '
    setopt err_return no_unset pipe_fail
    puts-err() { :; }
    entry() { :; }
    compinit() { return 1 }   # a defined function survives autoload -Uz
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ -n ${STARSHIP_CONFIG:-} ]]
  '

flag_root=$(mktemp -d)
mkdir -p "$flag_root/zsh" "$flag_root/local/flags"
cp "$root/zsh/interactive.zsh" "$flag_root/zsh/interactive.zsh"
: > "$flag_root/local/flags/no-starship-warning"
run_block 'silenced-warning block' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$flag_root/zsh" PATH=/usr/bin:/bin TERM=xterm-256color -- '
    setopt err_return no_unset pipe_fail
    puts-err() { print -r -- "WARN: $*"; }
    entry() { :; }
    source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
    [[ $PROMPT == *"%n@%m"* ]]
  '
[[ $block_out != *"Starship is not installed"* ]] || fail 'no-starship-warning flag did not silence the warning'
rm -rf "$flag_root"

run_block 'clean checkout without cloned plugins' \
  HOME="$tmp" ZDOTDIR="$tmp" LEOS_PROFILES_ZSH="$tmp/empty-zsh" LEOS_TEST_ROOT="$root" TERM=xterm-256color PATH="$fakepath" -- '
    setopt err_return no_unset pipe_fail
    mkdir -p "$LEOS_PROFILES_ZSH"
    puts-err() { :; }
    entry() { :; }
    source "$LEOS_TEST_ROOT/zsh/interactive.zsh" 2>/dev/null
    [[ $STARSHIP_CONFIG == "$LEOS_PROFILES_ZSH/starship.toml" ]]
  '

run_block 'safe and aggressive history boundaries' HOME="$tmp/history-home" LEOS_TEST_ROOT="$root" -- '
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
'

run_block 'native AI updates and contradictory bye options' \
  HOME="$tmp/ai-home" LEOS_TEST_ROOT="$root" AI_LOG="$tmp/ai-log" PATH="$fakepath" \
  HOMEBREW_PREFIX="$tmp/not-a-real-brew" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  claude() { print -r -- "claude $*" >> "$AI_LOG"; }
  codex() { print -r -- "codex $*" >> "$AI_LOG"; }
  npm() { print -r -- BAD >> "$AI_LOG"; return 1; }
  source "$LEOS_TEST_ROOT/zsh/commands.zsh"
  ai-checkup
  [[ "$(<$AI_LOG)" == $'"'"'claude update\ncodex update\nopencode upgrade'"'"' ]]
  ! bye --shutdown-wsl --no-exit >/dev/null 2>&1
'

mkdir -p "$tmp/updater-profile" "$tmp/fake-bin"
: > "$tmp/updater-profile/install.sh"
print -rl -- '#!/bin/sh' 'printf "%s\n" "$*" > "$UPGRADE_LOG"' > "$tmp/fake-bin/bash"
chmod +x "$tmp/fake-bin/bash"
run_block 'configured-upstream reconciliation' \
  HOME="$tmp/updater-home" PATH="$tmp/fake-bin:$PATH" LEOS_TEST_ROOT="$root" \
  LEOS_PROFILES="$tmp/updater-profile" UPGRADE_LOG="$tmp/upgrade-log" -- '
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
'

# Interactive shells on a real pseudo-terminal, loading the fixture profile
# through a ZDOTDIR .zshrc exactly as the managed loader does. The helper types
# a command that prints a marker and exits, then returns the whole transcript.
mkdir -p "$tmp/ptyrc"
print -r -- 'source "$LEOS_PROFILES_HOME/zsh/start.zsh"' > "$tmp/ptyrc/.zshrc"
cat > "$tmp/pty.py" <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
os.write(fd, b"print -r -- LEOS_PTY_DONE; exit\n")
out = bytearray()
deadline = time.time() + 30
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 1)
    if not ready:
        continue
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
PY
pty_transcript() {
  /usr/bin/env HOME="$tmp/pty-home" ZDOTDIR="$tmp/ptyrc" LEOS_PROFILES_HOME="$root" \
    PATH="$fakepath" "$@" python3 -I "$tmp/pty.py" "$zsh_bin" -di
}
mkdir -p "$tmp/pty-home"
if (( $+commands[python3] )); then
  # Control: a normal terminal does get line-editor escape sequences, so the
  # assertion below would notice them.
  out=$(pty_transcript TERM=xterm-256color)
  [[ $out == *LEOS_PTY_DONE* ]] || fail "pty shell did not run its command: $out"
  [[ $out == *$'\e'* ]] || fail 'pty control transcript has no escape sequences; the dumb test proves nothing'
  out=$(pty_transcript TERM=dumb)
  [[ $out == *LEOS_PTY_DONE* ]] || fail "TERM=dumb shell did not run its command: $out"
  [[ $out != *$'\e'* ]] || fail "TERM=dumb shell emitted escape sequences: ${(q+)out}"
  [[ $out == *'$ '* ]] || fail "TERM=dumb shell did not show the plain prompt: ${(q+)out}"
else
  print -u2 -r -- 'SKIP: python3 unavailable; pty TERM=dumb test not run'
fi

print -r -- 'profile tests: PASS'
