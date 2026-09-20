#!/usr/bin/env zsh
# Cache/security regressions use only temporary files and explicit fake tools.
if [[ ${1:-} != --isolated ]]; then
  exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/zsh \
    "${commands[zsh]:-/bin/zsh}" -df "$0" --isolated
fi
emulate -L zsh
setopt errexit nounset pipefail no_bgnice
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export HOME=$tmp/home XDG_CACHE_HOME=$tmp/cache
mkdir -p "$HOME" "$tmp/bin"
source "$root/zsh/cache.zsh"
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }
puts() { :; }
puts-err() { :; }

cat > "$tmp/bin/generator" <<'GENERATOR'
#!/bin/sh
printf 'typeset -g CACHE_VALUE=%s\n' "${1:-fresh}"
GENERATOR
chmod +x "$tmp/bin/generator"
bin=$tmp/bin/generator

# Private creation under a cooperative umask, without changing the caller's mask.
umask 002
leos-source-cached secure "$bin" fresh
[[ $CACHE_VALUE == fresh && $(umask) == 002 ]] || fail 'fresh generation or umask restoration'
__leos_init_cache secure "$bin" fresh
cache=$REPLY
zmodload zsh/stat
for f in "$XDG_CACHE_HOME/leos-profiles" "${cache:h}" "$cache" "$cache.zwc"; do
  zstat -H info -- "$f"
  (( (info[mode] & 8#77) == 0 )) || fail "non-private creation: $f"
done
# A normal hit executes the compiled result without invoking the generator.
CACHE_VALUE=unset
leos-source-cached secure "$bin" fresh
[[ $CACHE_VALUE == fresh ]] || fail 'compiled cache hit'

# Group-writable text, a hostile compiled sibling and symlink text are all
# rejected. In each case freshly generated code still initializes the shell.
print -r -- 'typeset -g CACHE_VALUE=attacker' > "$cache"
chmod 664 "$cache"
leos-source-cached secure "$bin" fresh
[[ $CACHE_VALUE == fresh ]] || fail 'group-writable cache executed'
chmod 600 "$cache"
print -r -- 'typeset -g CACHE_VALUE=attacker' > "$tmp/hostile.zsh"
zcompile -R "$cache.zwc" "$tmp/hostile.zsh"
chmod 664 "$cache.zwc"
leos-source-cached secure "$bin" fresh
[[ $CACHE_VALUE == fresh ]] || fail 'group-writable compiled cache executed'
rm -f -- "$cache" "$cache.zwc"
ln -s "$tmp/hostile.zsh" "$cache"
leos-source-cached secure "$bin" fresh
[[ $CACHE_VALUE == fresh ]] || fail 'symlink cache executed'
rm -- "$cache"
# A compiled symlink is unsafe even when its text sibling is otherwise valid.
__leos_init_cache secure "$bin" fresh
cache=$REPLY
rm -f -- "$cache.zwc"
ln -s "$tmp/hostile.zsh" "$cache.zwc"
leos-source-cached secure "$bin" fresh
[[ $CACHE_VALUE == fresh ]] || fail 'symlink compiled cache accepted'
rm -- "$cache.zwc"

# Migrate owned legacy directories only after protecting their parent. Even
# owner-only compiled files must be discarded after a writable-dir exposure.
print -r -- 'typeset -g CACHE_VALUE=attacker' > "$cache"
zcompile -R "$cache.zwc" "$tmp/hostile.zsh"
chmod 664 "$cache"
chmod 600 "$cache.zwc"
chmod 775 "$XDG_CACHE_HOME/leos-profiles" "${cache:h}"
leos-source-cached secure "$bin" fresh
[[ $CACHE_VALUE == fresh ]] || fail 'legacy writable directory code executed'
for f in "$XDG_CACHE_HOME/leos-profiles" "${cache:h}"; do
  zstat -H info -- "$f"
  (( (info[mode] & 8#777) == 8#700 )) || fail 'legacy directory not secured'
done
for f in "$cache" "$cache.zwc"; do
  zstat -H info -- "$f"
  (( (info[mode] & 8#777) == 8#600 )) || fail 'legacy cache not regenerated privately'
done
chmod 644 "$cache" "$cache.zwc"
leos-source-cached secure "$bin" fresh
for f in "$cache" "$cache.zwc"; do
  zstat -H info -- "$f"
  (( (info[mode] & 8#777) == 8#600 )) || fail 'readable existing cache not made private'
done

# Shared external XDG roots are never chmodded or written. Degrade once per
# shell with a diagnostic, while keeping initialization working on every call.
before=$(ls -A "${cache:h}")
chmod 777 "$XDG_CACHE_HOME"
(
  unset __leos_cache_fallback_warned
  leos-source-cached unsafe-parent "$bin" safe
  leos-source-cached unsafe-parent "$bin" safe
  [[ $CACHE_VALUE == safe ]] || fail 'unsafe-directory fallback'
) 2> "$tmp/fallback-warning"
[[ $(wc -l < "$tmp/fallback-warning") -eq 1 ]] || fail 'fallback diagnostic must appear once per shell'
[[ $(ls -A "${cache:h}") == $before ]] || fail 'unsafe external-directory cache write'
zstat -H info -- "$XDG_CACHE_HOME"
(( (info[mode] & 8#777) == 8#777 )) || fail 'external XDG root was chmodded'
chmod 700 "$XDG_CACHE_HOME"

# A literal symlink/.. path must not hide writable physical ancestors behind
# an apparently safe normalized path.
mkdir -p "$tmp/safe/cache" "$tmp/shared/sub" "$tmp/shared/cache"
chmod 777 "$tmp/shared"
ln -s "$tmp/shared/sub" "$tmp/safe/bridge"
(
  export XDG_CACHE_HOME=$tmp/safe/bridge/../cache
  if __leos_cache_dir; then fail 'symlink/.. ancestry bypass accepted'; fi
  leos-source-cached dotdot "$bin" safe
  [[ $CACHE_VALUE == safe && ! -e $tmp/shared/cache/leos-profiles ]] || fail 'symlink/.. fallback'
)

# Symlink cache roots also never receive cache writes.
old_cache_root=$XDG_CACHE_HOME
mkdir "$tmp/target"
ln -s "$tmp/target" "$tmp/alias"
export XDG_CACHE_HOME=$tmp/alias
leos-source-cached alias "$bin" safe
[[ $CACHE_VALUE == safe && ! -e $tmp/target/leos-profiles ]] || fail 'symlink root fallback'
export XDG_CACHE_HOME=$tmp/not-a-directory
: > "$XDG_CACHE_HOME"
leos-source-cached unavailable "$bin" safe
[[ $CACHE_VALUE == safe ]] || fail 'unwritable storage fallback'
export XDG_CACHE_HOME=$old_cache_root

# Names which used to flatten to the same filename must remain distinct.
cp "$bin" "$tmp/bin/a-b"
cp "$bin" "$tmp/bin/a_b"
__leos_init_cache collision "$tmp/bin/a-b" one; first=$REPLY
__leos_init_cache collision "$tmp/bin/a_b" one; second=$REPLY
[[ $first != $second ]] || fail 'launcher identity collision'
__leos_init_cache args "$bin" 'one two'; first=$REPLY
__leos_init_cache args "$bin" one two; second=$REPLY
[[ $first != $second ]] || fail 'argument boundary collision'
export PYENV_ROOT=$tmp/python-one
__leos_init_cache roots "$bin" one; first=$REPLY
export PYENV_ROOT=$tmp/python-two
__leos_init_cache roots "$bin" one; second=$REPLY
[[ $first != $second ]] || fail 'version-manager root identity collision'

# Errors can include partial script output: never execute it or negative-cache
# a transient error. A successful retry must work without manual clearing.
cat > "$tmp/bin/transient" <<'GENERATOR'
#!/bin/sh
if [ ! -f "$HOME/recovered" ]; then
  printf 'typeset -g CACHE_VALUE=attacker\n'
  exit 1
fi
printf 'typeset -g CACHE_VALUE=recovered\n'
GENERATOR
chmod +x "$tmp/bin/transient"
CACHE_VALUE=unchanged
if leos-source-cached transient "$tmp/bin/transient"; then fail 'failed generator accepted'; fi
[[ $CACHE_VALUE == unchanged ]] || fail 'partial output executed'
touch "$HOME/recovered"
leos-source-cached transient "$tmp/bin/transient"
[[ $CACHE_VALUE == recovered ]] || fail 'transient generator never retried'

# Concurrent cold starts publish only complete scripts/compiled files.
typeset -a workers
for i in 1 2 3 4; do
  "$commands[zsh]" -dfc 'source "$1/zsh/cache.zsh"; leos-source-cached parallel "$2" concurrent; [[ $CACHE_VALUE == concurrent ]]' zsh "$root" "$bin" &
  workers+=($!)
done
for worker in $workers; do wait "$worker" || fail 'concurrent initialization'; done
leos-source-cached parallel "$bin" concurrent
[[ $CACHE_VALUE == concurrent ]] || fail 'published compiled cache'
stages=("$XDG_CACHE_HOME/leos-profiles/init"/.init.*(N) "$XDG_CACHE_HOME/leos-profiles/init"/.compile.*(N))
(( $#stages == 0 )) || fail 'staging files leaked'

# Homebrew's empty success is process-dependent, and must not poison a later
# shell. The stub also rejects dialect inference by requiring an explicit zsh.
cat > "$tmp/bin/brew" <<'BREW'
#!/bin/sh
[ "$*" = 'shellenv zsh' ] || exit 1
printf '%s\n' "$*" >> "$HOME/brew-calls"
[ "${BREW_READY:-0}" = 1 ] && exit 0
printf 'typeset -g BREW_LOADED=yes\n'
BREW
chmod +x "$tmp/bin/brew"
__leos_brew_bin() { print -r -- "$tmp/bin/brew"; }
add-path() { :; }
LEOS_PROFILES=$tmp/profile
export BREW_READY=1
source "$root/zsh/path/brew.zsh"
unset BREW_READY
source "$root/zsh/path/brew.zsh"
[[ $BREW_LOADED == yes && $(wc -l < "$HOME/brew-calls") -eq 2 ]] || fail 'empty brew shellenv success poisoned later startup'

# Existing version-manager roots remain authoritative. Only fake binaries are
# visible under these names; rehash is stubbed to avoid background side effects.
for tool in pyenv rbenv; do
  print -rl -- '#!/bin/sh' 'printf ":\n"' > "$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done
path=("$tmp/bin" $path)
__leos_rehash_daily() { :; }
export PYENV_ROOT=$tmp/custom-python RBENV_ROOT=$tmp/custom-ruby
source "$root/zsh/path/pyenv.zsh"
source "$root/zsh/path/rbenv.zsh"
[[ $PYENV_ROOT == $tmp/custom-python && $RBENV_ROOT == $tmp/custom-ruby ]] || fail 'version-manager roots overwritten'

# Bun selects a dialect from SHELL even when the running interpreter is Zsh.
# A parent Bash/Fish shell must not cause Bash/Fish code to enter the cache.
cat > "$tmp/bin/bun" <<'BUN'
#!/bin/sh
[ "$SHELL" = zsh ] || exit 1
printf 'typeset -g BUN_ZSH_COMPLETION=yes\n'
BUN
chmod +x "$tmp/bin/bun"
rehash
export SHELL=/bin/fish
compdef() { :; }
source "$root/zsh/path/node.zsh"
leos-node-completions
[[ $BUN_ZSH_COMPLETION == yes && $SHELL == /bin/fish ]] || fail 'Bun dialect or parent-shell preservation'
print -r -- 'runtime cache tests: PASS'
