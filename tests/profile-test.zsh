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
cp -R "$source_root/zsh/completions" "$root/zsh/completions"
# Include the actual installed plugin code, but never the repository's private
# overrides. Plugin availability remains optional for clean-checkout testing.
[[ ! -d $source_root/zsh/plugins ]] || cp -R "$source_root/zsh/plugins" "$root/zsh/plugins"
cp "$source_root/util/rmdsstore.py" "$root/util/"
# Rehash and fnm multishell pruning are asynchronous maintenance side effects,
# not part of these profile assertions. Disable them in the temporary fixture so no detached writer can
# outlive the shell or race removal of its HOME.
print -rl -- '__leos_rehash_daily() { :; }' '__leos_fnm_prune_daily() { :; }' >> "$root/zsh/cache.zsh"
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
    (( $+functions[ls] && ! $+aliases[ls] )) || { print -u2 -r -- "ls wrapper was not defined"; exit 1; }
    [[ -o hist_fcntl_lock && -o extended_glob ]]
    print -r -- HEAD^ >/dev/null               # BP-2: no "no matches found"
    [[ $(print -r -- HEAD^) == "HEAD^" ]]
    (( $#fpath == ${#${(@u)fpath}} && $#path == ${#${(@u)path}} ))   # no duplicates
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
    (( ! $+aliases[ls] && ! $+functions[ls] ))
    (( ! $+functions[cat] ))
    (( ! $+aliases[grep] ))
    [[ -z ${LC_ALL:-} ]]
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

# heroku must load BEFORE the other post-compinit entries: an older CLI's
# zsh_setup runs a second compinit, which discards every compdef registered up
# to that point.
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
  for other in path/fzf path/zoxide; do
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

# Compiled profile sources: every startup file and the plugin files they
# source get a .zwc, plugin checkouts stay clean through .git/info/exclude,
# directories others can write get none, and Zsh still prefers a newer source.
mkdir -p "$tmp/zc/zsh/path" "$tmp/zc/zsh/plugins/zsh-autosuggestions" "$tmp/zc/shared"
cp "$root"/zsh/*.zsh "$tmp/zc/zsh/"
cp "$root"/zsh/path/*.zsh "$tmp/zc/zsh/path/"
print -r -- 'typeset -g ZC_SOURCE=compiled' > "$tmp/zc/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
print -r -- 'typeset -g ZC_SOURCE=shared' > "$tmp/zc/shared/x.zsh"
chmod 700 "$tmp/zc/zsh" "$tmp/zc/zsh/path" "$tmp/zc/zsh/plugins/zsh-autosuggestions"
chmod 777 "$tmp/zc/shared"
run_block 'zcompile of profile and plugin sources' \
  HOME="$tmp/zc" LEOS_TEST_ROOT="$root" ZC="$tmp/zc" PATH="$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  plugin=$ZC/zsh/plugins/zsh-autosuggestions
  git -C "$plugin" init -q
  git -C "$plugin" -c user.name=t -c user.email=t@example.invalid add -A
  git -C "$plugin" -c user.name=t -c user.email=t@example.invalid commit -qm fixture
  __leos_zcompile_profile "$ZC/zsh"
  (( REPLY > 0 ))
  for f in $ZC/zsh/*.zsh $ZC/zsh/path/*.zsh $plugin/zsh-autosuggestions.zsh; do
    [[ -s $f.zwc ]] || { print -u2 -r -- "not compiled: $f"; exit 1; }
  done
  [[ -z $(git -C "$plugin" status --porcelain) ]] || { print -u2 -r -- "plugin checkout dirty"; exit 1; }
  leftovers=($ZC/zsh/.compile-*(N) $plugin/.compile-*(N))
  (( ! $#leftovers ))
  # Not a profile path, and its directory is world-writable: never compiled.
  cp "$ZC/shared/x.zsh" "$ZC/zsh/path/zz-shared.zsh"
  chmod 777 "$ZC/zsh/path"
  __leos_zcompile_profile "$ZC/zsh"
  [[ ! -e $ZC/zsh/path/zz-shared.zsh.zwc ]]
  chmod 700 "$ZC/zsh/path"
  # Zsh reads the .zwc when the text is not newer, and the text when it is.
  print -r -- "typeset -g ZC_SOURCE=edited" > "$plugin/zsh-autosuggestions.zsh"
  touch -t 202001010000 "$plugin/zsh-autosuggestions.zsh"
  source "$plugin/zsh-autosuggestions.zsh"
  [[ $ZC_SOURCE == compiled ]]
  touch "$plugin/zsh-autosuggestions.zsh"
  touch -t 202001010000 "$plugin/zsh-autosuggestions.zsh.zwc"
  source "$plugin/zsh-autosuggestions.zsh"
  [[ $ZC_SOURCE == edited ]]
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
  for late in path/fzf path/zoxide; do
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
  for late in path/fzf path/zoxide path/heroku; do
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

# Fresh HOME: earlier blocks leave a valid completion dump in $tmp, and a cached
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

# ls/cat wrappers: fake eza/bat/ls/cat record the argv they were run with, so
# each case shows which program the wrapper chose and with what arguments.
mkdir -p "$tmp/wrapbin" "$tmp/wrap-home"
for tool in eza bat ls cat; do
  print -rl -- '#!/bin/sh' "printf '%s\\n' \"$tool \$*\" >> \"\$WRAP_LOG\"" > "$tmp/wrapbin/$tool"
  chmod +x "$tmp/wrapbin/$tool"
done
print -r -- 'wrapper text' > "$tmp/wrap-home/f"
run_block 'ls/cat wrappers route each flag to the program that understands it' \
  HOME="$tmp/wrap-home" WRAP_LOG="$tmp/wrap-log" LEOS_TEST_ROOT="$root" PATH="$tmp/wrapbin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { print -u2 -r -- "$*"; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  alias ls="ls -F" cat="cat -s"     # a system zshrc alias must not break or win
  source "$LEOS_TEST_ROOT/zsh/env.zsh"
  check() {   # check <expected argv> <command...>
    local expected=$1; shift
    : > "$WRAP_LOG"
    "$@" > /dev/null
    [[ "$(<$WRAP_LOG)" == "$expected" ]] || {
      print -u2 -r -- "$* ran [$(<$WRAP_LOG)], expected [$expected]"; exit 1
    }
  }
  E="eza --color=auto --group-directories-first"
  check "ls --color=auto -ltr"        ls -ltr
  check "ls --color=auto -lh d"       ls -lh d
  check "ls --color=auto -t"          ls -t
  check "ls --color=auto -1F"         ls -1F
  check "ls --color=auto -G"          ls -G
  check "ls --color=auto --sort=time" ls --sort=time
  check "ls --color=auto --color"     ls --color
  check "ls --color=auto --help"      ls --help
  check "$E -la"                      ls -la
  check "$E -1AdR x y"                ls -1AdR x y
  check "$E --git"                    ls --git
  check "$E --tree --level=2 ."       ls --tree --level=2 .
  check "$E"                          ls
  check "$E -l -- -t"                 ls -l -- -t
  check "$E -"                        ls -
  # Not a terminal here: always the real cat, options or not.
  check "cat f"                       cat f
  check "cat -v f"                    cat -v f
  : > "$WRAP_LOG"; cat f | true
  [[ "$(<$WRAP_LOG)" == "cat f" ]]
'

# Startup files test for tools with `whence -p`: a $+commands miss fills zsh's
# whole command table, and each PATH edit empties it again (PERF-9).
startup_lookups=($(command grep -l '^[^#]*\$+commands\[' "$source_root"/zsh/*.zsh "$source_root"/zsh/path/*.zsh /dev/null || true))
(( ! $#startup_lookups )) || fail "startup files still test tools with \$+commands: $startup_lookups"

# env.zsh settles the locale, the ls colour flag and grep colours from paths,
# without running locale, ls or grep (each a fork on every shell).
mkdir -p "$tmp/probe/gnubin"
for tool in ls grep locale; do
  print -rl -- '#!/bin/sh' "printf '%s\\n' \"$tool \$*\" >> \"\$PROBE_LOG\"" > "$tmp/probe/gnubin/$tool"
  chmod +x "$tmp/probe/gnubin/$tool"
done
run_block 'env.zsh decides locale, ls and grep colours without running them' \
  HOME="$tmp/wrap-home" PROBE_LOG="$tmp/probe/log" LEOS_TEST_ROOT="$root" PATH="$tmp/probe/gnubin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  unset LANG LC_ALL
  puts() { :; }; puts-err() { :; }
  : > "$PROBE_LOG"
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/env.zsh"
  [[ ! -s $PROBE_LOG ]] || { print -u2 -r -- "probed: $(<$PROBE_LOG)"; exit 1; }
  [[ $__leos_ls_color == --color=auto ]]
  [[ $(alias grep) == *"grep --color=auto"* ]]
  if [[ -d /usr/lib/locale/C.utf8 || -d /usr/lib/locale/C.UTF-8 || -d /usr/share/locale/C.UTF-8 ]]; then
    [[ $LANG == C.UTF-8 ]]
  fi
'

run_block 'without eza ls keeps the platform colour flag' \
  HOME="$tmp/wrap-home" WRAP_LOG="$tmp/wrap-log" LEOS_TEST_ROOT="$root" PATH="$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { print -u2 -r -- "$*"; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/env.zsh"
  if (( ! $+commands[eza] )); then
    (( $+functions[ls] ))
    [[ $functions[ls] == *"command ls"* && $functions[ls] != *eza* ]]
    zstyle -s ":fzf-tab:complete:cd:*" fzf-preview preview
    [[ $preview == *"command ls -1"* ]] || { print -u2 -r -- "preview: $preview"; exit 1; }
  fi
'

run_block 'env.zsh keeps inherited colours and pager' \
  HOME="$tmp/wrap-home" LEOS_TEST_ROOT="$root" PATH="$tmp/wrapbin:$fakepath" \
  LS_COLORS='di=1;34' LSCOLORS=exfxcxdxbxegedabagacad MANPAGER=less MANROFFOPT=-x -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/env.zsh"
  [[ $LS_COLORS == "di=1;34" && $LSCOLORS == exfxcxdxbxegedabagacad ]]
  [[ $MANPAGER == less && $MANROFFOPT == -x ]]
'

run_block 'env.zsh fills unset colours and pager' \
  HOME="$tmp/wrap-home" LEOS_TEST_ROOT="$root" PATH="$tmp/wrapbin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/env.zsh"
  [[ $LS_COLORS == di=36:* && -n $LSCOLORS ]]
  [[ $MANPAGER == *bat* && $MANROFFOPT == -c ]]
  [[ ${(t)LS_COLORS} == *export* && ${(t)MANPAGER} == *export* ]]
  [[ $(alias egrep) == *"grep -E --color=auto"* && $(alias fgrep) == *"grep -F --color=auto"* ]]
'

# PATH precedence after a full startup: version-manager shims, then
# ~/.local/bin, then Go workspace bins, then Homebrew.
mkdir -p "$tmp/order-home/.local/bin" "$tmp/order-home/go/bin" "$tmp/order-home/.pyenv/shims" "$tmp/orderbin"
print -rl -- '#!/bin/sh' 'case "$1" in' ' shellenv) printf "export HOMEBREW_PREFIX=%s\\n" "$HOME/fake-brew" ;;' \
  ' --prefix) printf "%s\\n" "$HOME/fake-brew" ;;' ' *) exit 91 ;;' 'esac' > "$tmp/orderbin/brew"
print -rl -- '#!/bin/sh' 'exit 0' > "$tmp/orderbin/go"
print -rl -- '#!/bin/sh' '[ "$1" = init ] && printf "%s\\n" "export PATH=\"\$HOME/.pyenv/shims:\${PATH}\""' \
  > "$tmp/orderbin/pyenv"
chmod +x "$tmp/orderbin/"*
run_block 'PATH precedence: shims, ~/.local/bin, go bin, brew' \
  HOME="$tmp/order-home" ZDOTDIR="$tmp/order-home" LEOS_PROFILES_HOME="$root" TERM=xterm-256color \
  PATH="$tmp/orderbin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  source "$LEOS_PROFILES_HOME/zsh/start.zsh" 2>/dev/null
  shims=${path[(ie)$HOME/.pyenv/shims]} local=${path[(ie)$HOME/.local/bin]}
  gobin=${path[(ie)$HOME/go/bin]} brew=${path[(ie)${commands[brew]:h}]}
  (( shims < local && local < gobin && gobin < brew && brew <= $#path )) || {
    print -u2 -r -- "order: shims=$shims local=$local go=$gobin brew=$brew in ${(j.:.)path}"; exit 1
  }
'

# Key bindings survive an EDITOR that would pick vi mode, and the terminal's
# usual Home/End/Delete/arrow sequences reach the intended widgets.
run_block 'emacs keymap with navigation keys and prefix history search' \
  HOME="$tmp" LEOS_PROFILES_ZSH="$root/zsh" EDITOR=vim VISUAL=vim TERM=xterm-256color PATH="$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts-err() { :; }
  entry() { :; }
  source "$LEOS_PROFILES_ZSH/cache.zsh"
  source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
  [[ $(bindkey -lL main) == *emacs* ]]
  for pair in "^[[H:beginning-of-line" "^[OH:beginning-of-line" "^[[1~:beginning-of-line" \
      "^[[F:end-of-line" "^[OF:end-of-line" "^[[4~:end-of-line" "^[[3~:delete-char" \
      "^[[1;5D:backward-word" "^[[1;5C:forward-word" \
      "^[[A:up-line-or-beginning-search" "^[OA:up-line-or-beginning-search" \
      "^[[B:down-line-or-beginning-search"; do
    seq=${pair%%:*} widget=${pair#*:}
    [[ $(bindkey -M emacs "$seq") == *" $widget" ]] || {
      print -u2 -r -- "$seq: $(bindkey -M emacs "$seq"), expected $widget"; exit 1
    }
  done
  (( $+widgets[up-line-or-beginning-search] && $+widgets[down-line-or-beginning-search] ))
'

# heroku >= 11 skips its own compinit once compdef exists, so the `_heroku` its
# setup put on fpath must be registered by the profile.
mkdir -p "$tmp/heroku-home/bin" "$tmp/heroku-home/comp"
print -rl -- '#compdef heroku' '_heroku() { :; }' > "$tmp/heroku-home/comp/_heroku"
print -rl -- '#!/bin/sh' 'printf "%s\\n" "fpath=(\"\$HOME/comp\" \$fpath)"' > "$tmp/heroku-home/bin/heroku"
chmod +x "$tmp/heroku-home/bin/heroku"
run_block 'heroku completion is registered when its setup skipped compinit' \
  HOME="$tmp/heroku-home" LEOS_TEST_ROOT="$root" PATH="$tmp/heroku-home/bin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  autoload -Uz compinit; compinit -D -u
  (( ! ${+_comps[heroku]} ))
  source "$LEOS_TEST_ROOT/zsh/path/heroku.zsh"
  [[ ${_comps[heroku]-} == _heroku ]] || { print -u2 -r -- "heroku -> ${_comps[heroku]-unset}"; exit 1; }
'

# Changing a zoxide variable that alters the generated script must not reuse
# the script cached under the old value.
mkdir -p "$tmp/zo-home/bin"
print -rl -- '#!/bin/sh' 'printf "%s\\n" "typeset -g ZO_GENERATED=${_ZO_ECHO:-none}"' > "$tmp/zo-home/bin/zoxide"
chmod +x "$tmp/zo-home/bin/zoxide"
run_block 'zoxide cache identity includes _ZO_ECHO and _ZO_RESOLVE_SYMLINKS' \
  HOME="$tmp/zo-home" LEOS_TEST_ROOT="$root" PATH="$tmp/zo-home/bin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/path/zoxide.zsh"
  [[ $ZO_GENERATED == none ]]
  export _ZO_ECHO=1
  source "$LEOS_TEST_ROOT/zsh/path/zoxide.zsh"
  [[ $ZO_GENERATED == 1 ]] || { print -u2 -r -- "stale zoxide init: $ZO_GENERATED"; exit 1; }
  ZO_GENERATED=
  export _ZO_RESOLVE_SYMLINKS=1
  source "$LEOS_TEST_ROOT/zsh/path/zoxide.zsh"
  # A new identity regenerates (the fake ignores this variable; the cache key must not).
  cached=($HOME/.cache/leos-profiles/init/*.zsh(N))
  (( $#cached == 3 )) || { print -u2 -r -- "cache entries: $cached"; exit 1; }
'

# fnm: a nested shell must not stack its parent's multishell bin, and the
# daily prune removes only old links whose shell is gone.
mkdir -p "$tmp/fnm-home/bin"
print -rl -- '#!/bin/sh' 'd="$HOME/state/fnm_multishells/$$_1"' \
  'printf "%s\\n" "export FNM_MULTISHELL_PATH=$d" "export PATH=$d/bin:\$PATH"' > "$tmp/fnm-home/bin/fnm"
chmod +x "$tmp/fnm-home/bin/fnm"
run_block 'fnm strips inherited multishell bins and schedules the prune' \
  HOME="$tmp/fnm-home" LEOS_TEST_ROOT="$root" \
  PATH="/x/fnm_multishells/111_1/bin:$tmp/fnm-home/bin:/y/fnm_multishells/222_2/bin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  typeset -g PRUNED=
  __leos_fnm_prune_daily() { PRUNED=$1; }
  source "$LEOS_TEST_ROOT/zsh/path/fnm.zsh"
  multi=(${(M)path:#*/fnm_multishells/*})
  (( $#multi == 1 )) && [[ $multi[1] == $HOME/state/fnm_multishells/*/bin ]] || {
    print -u2 -r -- "multishell entries: $multi"; exit 1
  }
  [[ $PRUNED == $HOME/state/fnm_multishells ]]
'

mkdir -p "$tmp/fnm-prune/fnm_multishells"
(sleep 0) & dead_pid=$!
wait $dead_pid
ms=$tmp/fnm-prune/fnm_multishells
ln -s /nonexistent "$ms/${dead_pid}_100"            # dead, old: removed
ln -s /nonexistent "$ms/${dead_pid}_200"            # dead, recent: kept
ln -s /nonexistent "$ms/$$_300"                     # alive (this test), old: kept
ln -s /nonexistent "$ms/other-name"                 # not fnm's shape: kept
: > "$ms/${dead_pid}_400"                           # not a symlink: kept
touch -h -t 202001010000 "$ms/${dead_pid}_100" "$ms/$$_300" "$ms/other-name" "$ms/${dead_pid}_400"
run_block 'fnm prune removes only old links of dead shells' \
  HOME="$tmp/fnm-prune" LEOS_TEST_ROOT="$root" MS="$ms" DEAD="$dead_pid" LIVE="$$" -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  __leos_fnm_prune "$MS"
  [[ ! -L $MS/${DEAD}_100 ]]
  [[ -L $MS/${DEAD}_200 && -L $MS/${LIVE}_300 && -L $MS/other-name && -f $MS/${DEAD}_400 ]]
'

run_block '__leos_daily_due runs once per day per name' \
  HOME="$tmp/daily-home" LEOS_TEST_ROOT="$root" -- '
  setopt err_return no_unset pipe_fail
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  __leos_daily_due test-job
  ! __leos_daily_due test-job
  __leos_daily_due other-job
  touch -t 202001010000 "$HOME/.cache/leos-profiles/init/test-job"
  __leos_daily_due test-job
'

# fzf wiring when fd and bat exist; user values win.
mkdir -p "$tmp/fzf-home/bin"
for tool in fzf fd bat; do
  print -rl -- '#!/bin/sh' 'exit 0' > "$tmp/fzf-home/bin/$tool"
  chmod +x "$tmp/fzf-home/bin/$tool"
done
run_block 'fzf uses fd and a bat preview when they are installed' \
  HOME="$tmp/fzf-home" LEOS_TEST_ROOT="$root" PATH="$tmp/fzf-home/bin:$fakepath" \
  FZF_ALT_C_COMMAND=mine -- '
  setopt err_return no_unset pipe_fail
  puts() { :; }; puts-err() { :; }
  source "$LEOS_TEST_ROOT/zsh/cache.zsh"
  source "$LEOS_TEST_ROOT/zsh/path/fzf.zsh"
  [[ $FZF_DEFAULT_COMMAND == "fd --type f --hidden --follow --exclude .git" ]]
  [[ $FZF_CTRL_T_COMMAND == "fd --type f --hidden --follow --exclude .git" ]]
  [[ $FZF_ALT_C_COMMAND == mine ]]
  [[ $FZF_CTRL_T_OPTS == *"bat "* ]]
  (( $+functions[_fzf_compgen_path] && $+functions[_fzf_compgen_dir] ))
  [[ ${(t)FZF_DEFAULT_COMMAND} == *export* ]]
'

# The completion dump lives in the private cache root, per Zsh version, and
# dumps earlier versions left in HOME are removed once.
mkdir -p "$tmp/dump-home/.zcompdump-dir"
: > "$tmp/dump-home/.zcompdump"
: > "$tmp/dump-home/.zcompdump.zwc"
: > "$tmp/dump-home/.zcompdump-host-5.9"
: > "$tmp/dump-home/.zcompdumpish"
run_block 'completion dump moves to the cache root; legacy dumps removed once' \
  HOME="$tmp/dump-home" ZDOTDIR="$tmp/dump-home" LEOS_PROFILES_ZSH="$root/zsh" TERM=xterm-256color PATH="$fakepath" -- '
  setopt err_return no_unset pipe_fail
  puts-err() { :; }
  entry() { :; }
  source "$LEOS_PROFILES_ZSH/cache.zsh"
  source "$LEOS_PROFILES_ZSH/interactive.zsh"
  (( $+functions[compdef] ))
  [[ -s $HOME/.cache/leos-profiles/zcompdump-$ZSH_VERSION ]]
  [[ ! -e $HOME/.zcompdump && ! -e $HOME/.zcompdump.zwc && ! -e $HOME/.zcompdump-host-5.9 ]]
  [[ -e $HOME/.zcompdumpish && -d $HOME/.zcompdump-dir ]]
  : > "$HOME/.zcompdump"          # some other tool writes one later
  source "$LEOS_PROFILES_ZSH/interactive.zsh"
  [[ -e $HOME/.zcompdump ]]       # ...and it is not removed again
'

# compinit freshness. Stubbed compinit/compaudit (first on fpath) record their
# calls. A missing or day-old dump, or a changed fpath, takes the slow path
# exactly once: audit, full compinit, and a touch so that the next shells take
# the fast path, `compinit -C` with no audit. No plugins in this fixture.
mkdir -p "$tmp/ci-root/zsh" "$tmp/ci-home/stubs" "$tmp/ci-home/newcomp"
cp "$root/zsh/cache.zsh" "$root/zsh/interactive.zsh" "$tmp/ci-root/zsh/"
print -rl -- 'print -r -- "compinit $*" >> $HOME/calls' \
  '[[ -e ${@[-1]} ]] || print -r -- "#files: 0" > ${@[-1]}' > "$tmp/ci-home/stubs/compinit"
print -rl -- 'print -r -- audit >> $HOME/calls' > "$tmp/ci-home/stubs/compaudit"
ci_dump=$tmp/ci-home/.cache/leos-profiles/zcompdump-$("$zsh_bin" -dfc 'print -r -- $ZSH_VERSION')
compinit_round() {
  local label=$1 extra=${2:-}
  : > "$tmp/ci-home/calls"
  run_block "compinit freshness: $label" \
    HOME="$tmp/ci-home" ZDOTDIR="$tmp/ci-home" LEOS_PROFILES_ZSH="$tmp/ci-root/zsh" \
    TERM=xterm-256color PATH="$fakepath" CI_EXTRA="$extra" -- '
    setopt err_return no_unset pipe_fail
    puts() { :; }; puts-err() { :; }; entry() { :; }
    fpath=("$HOME/stubs" ${CI_EXTRA:+$CI_EXTRA} $fpath)
    source "$LEOS_PROFILES_ZSH/cache.zsh"
    source "$LEOS_PROFILES_ZSH/interactive.zsh"
  '
  REPLY=$(<"$tmp/ci-home/calls")
}
compinit_round 'no dump'
[[ $REPLY == $'audit\ncompinit -d '$ci_dump ]] || fail "first shell must audit and build: ${(q+)REPLY}"
compinit_round 'fresh dump'
[[ $REPLY == "compinit -C -d $ci_dump" ]] || fail "fresh dump must take the fast path: ${(q+)REPLY}"
touch -t 202001010000 "$ci_dump"
compinit_round 'day-old dump'
[[ $REPLY == $'audit\ncompinit -d '$ci_dump ]] || fail "day-old dump must audit and rebuild: ${(q+)REPLY}"
[[ -n $ci_dump(#qN.mh-1) ]] || fail 'the slow path did not touch the dump'
compinit_round 'after the daily rebuild'
[[ $REPLY == "compinit -C -d $ci_dump" ]] || fail "after a rebuild the fast path must return: ${(q+)REPLY}"
compinit_round 'new fpath directory' "$tmp/ci-home/newcomp"
[[ $REPLY == $'audit\ncompinit -d '$ci_dump ]] || fail "a changed fpath must rebuild: ${(q+)REPLY}"
compinit_round 'same new fpath' "$tmp/ci-home/newcomp"
[[ $REPLY == "compinit -C -d $ci_dump" ]] || fail "an unchanged fpath must take the fast path: ${(q+)REPLY}"

mkdir -p "$tmp/unsafe-home/shared"
chmod 777 "$tmp/unsafe-home/shared"
run_block 'completion dump falls back to ZDOTDIR when the cache root is unsafe' \
  HOME="$tmp/unsafe-home" ZDOTDIR="$tmp/unsafe-home/zdot" XDG_CACHE_HOME="$tmp/unsafe-home/shared/cache" \
  LEOS_PROFILES_ZSH="$root/zsh" TERM=xterm-256color PATH="$fakepath" -- '
  setopt err_return no_unset pipe_fail
  mkdir -p "$ZDOTDIR"
  puts-err() { :; }
  entry() { :; }
  source "$LEOS_PROFILES_ZSH/cache.zsh"
  source "$LEOS_PROFILES_ZSH/interactive.zsh" 2>/dev/null
  [[ -s $ZDOTDIR/.zcompdump && ! -e $XDG_CACHE_HOME ]]
'

run_block 'aggressive clear-history removes the cache-root dump' \
  HOME="$tmp/dump-home" LEOS_TEST_ROOT="$root" -- '
  setopt err_return no_unset pipe_fail
  HISTFILE="$HOME/.zsh_history"
  puts() { :; }; puts-err() { :; }; fc() { :; }
  source "$LEOS_TEST_ROOT/zsh/commands.zsh"
  clear-history --aggressive
  dumps=($HOME/.cache/leos-profiles/zcompdump-[0-9]*(N))
  (( ! $#dumps ))
  [[ -e $HOME/.cache/leos-profiles/zcompdump-legacy-removed ]]
'

# No terminal at all (IDE tasks, agents, CI): an interactive shell must start
# without writing anything to stderr. A fake fzf would announce itself there.
print -rl -- '#!/bin/sh' 'printf "%s\\n" "print -u2 FZF-WIDGETS-LOADED"' > "$tmp/notty-fzf"
mkdir -p "$tmp/notty-bin" "$tmp/notty-home"
mv "$tmp/notty-fzf" "$tmp/notty-bin/fzf"
chmod +x "$tmp/notty-bin/fzf"
run_block 'zsh -ic without a terminal prints nothing to stderr' \
  HOME="$tmp/notty-home" ZDOTDIR="$tmp/ptyrc" LEOS_PROFILES_HOME="$root" TERM=xterm-256color \
  PATH="$tmp/notty-bin:$fakepath" -- '
  setopt err_return no_unset pipe_fail
  err=$(zsh -dic true 2>&1 >/dev/null </dev/null)
  # compaudit findings reflect the host (GitHub Ubuntu images ship a
  # group-writable /usr/share/zsh), not terminal handling; ignore only those.
  err=${(F)${(@)${(f)err}:#*Ignoring insecure Zsh completion path*}}
  [[ -z $err ]] || { print -u2 -r -- "stderr: $err"; exit 1; }
'

if (( $+commands[python3] )); then
  # On a terminal, cat with plain operands is bat; any option is the real cat.
  out=$(/usr/bin/env HOME="$tmp/wrap-home" WRAP_LOG="$tmp/wrap-log" LEOS_TEST_ROOT="$root" \
    PATH="$tmp/wrapbin:$fakepath" python3 -I "$tmp/pty.py" "$zsh_bin" -dfc '
      puts() { :; }; puts-err() { :; }
      source "$LEOS_TEST_ROOT/zsh/cache.zsh"
      source "$LEOS_TEST_ROOT/zsh/env.zsh"
      : > "$WRAP_LOG"
      cat f; cat -n f; cat -- f
      print -r -- "LOG[$(<$WRAP_LOG)]"')
  out=${out//$'\r'/}
  [[ $out == *$'LOG[bat --style=plain --paging=never f\ncat -n f\ncat -- f]'* ]] ||
    fail "cat wrapper on a terminal: ${(q+)out}"
fi

# Starship formats show user@host over SSH only, with no dangling `@` locally.
# CI validates the TOML itself; this checks the modules wiring when a Python
# with tomllib (3.11+) is available.
toml_python=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  (( $+commands[$candidate] )) || continue
  $candidate -c 'import tomllib' 2>/dev/null && { toml_python=$candidate; break; }
done
if [[ -n $toml_python ]]; then
  $toml_python -I - "$root/zsh/starship.toml" "$root/zsh/starship-plain.toml" <<'PY' || fail 'Starship hostname wiring'
import sys, tomllib
for name in sys.argv[1:]:
    with open(name, "rb") as handle:
        config = tomllib.load(handle)
    assert "$username$hostname" in config["format"], name
    assert config["hostname"]["ssh_only"] is True, name
    assert "@" not in config["username"]["format"], name
    assert "@" in config["hostname"]["format"], name
PY
fi

print -r -- 'profile tests: PASS'
