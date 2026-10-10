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
grep -Fq "Unsafe path: $XDG_CACHE_HOME; if it should be private to you, run: chmod go-w $XDG_CACHE_HOME" \
  "$tmp/fallback-warning" || fail "fallback diagnostic must name the unsafe path: $(<$tmp/fallback-warning)"
[[ $(ls -A "${cache:h}") == $before ]] || fail 'unsafe external-directory cache write'
zstat -H info -- "$XDG_CACHE_HOME"
(( (info[mode] & 8#777) == 8#777 )) || fail 'external XDG root was chmodded'
chmod 700 "$XDG_CACHE_HOME"

# Debian/Ubuntu sessions often run with umask 002 and user-private groups. A
# group-writable directory is safe only when that group is the user's own:
# primary gid, same name as the user, no other members. Never world-writable.
mkdir -p "$tmp/getent-bin" "$tmp/upg/cache"
cat > "$tmp/getent-bin/getent" <<'GETENT'
#!/bin/sh
[ "$1" = group ] && [ "$2" = "$FAKE_GID" ] || exit 2
printf '%s\n' "$FAKE_GROUP_ENTRY"
GETENT
chmod +x "$tmp/getent-bin/getent"
chgrp "$GID" "$tmp/upg" "$tmp/upg/cache"
chmod 775 "$tmp/upg" "$tmp/upg/cache"
upg_case() {
  local expect=$1 entry=$2 mode=$3
  (
    export PATH=$tmp/getent-bin:$PATH XDG_CACHE_HOME=$tmp/upg/cache FAKE_GID=$GID
    export FAKE_GROUP_ENTRY=$entry
    unset __leos_private_gid
    chmod "$mode" "$tmp/upg/cache"
    if __leos_cache_dir; then
      [[ $expect == accept ]] || fail "user-private group case accepted: $entry ($mode)"
      zstat -H info -- "$XDG_CACHE_HOME/leos-profiles/init"
      (( (info[mode] & 8#777) == 8#700 )) || fail 'profile-owned cache directory must still be private'
    else
      [[ $expect == reject ]] || fail "user-private group case rejected: $entry ($mode)"
      [[ $__leos_cache_unsafe == $tmp/upg/cache ]] || fail "unsafe path not recorded: $__leos_cache_unsafe"
    fi
  )
}
upg_case accept "${USERNAME}:x:${GID}:" 775
upg_case accept "${USERNAME}:x:${GID}:$USERNAME" 775
upg_case reject "${USERNAME}:x:${GID}:someone-else" 775
upg_case reject "not-${USERNAME}:x:${GID}:" 775
upg_case reject "${USERNAME}:x:${GID}:" 777
rm -rf -- "$tmp/upg"

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

# Freshness is the launcher's mtime: an unchanged launcher keeps the cached
# script even when its output would now differ, and a newer one regenerates.
# Backdate the cache rather than future-date the launcher, so no clock skew or
# one-second mtime granularity can make the comparison a tie.
cat > "$tmp/bin/versioned" <<'GENERATOR'
#!/bin/sh
printf '%s\n' "$0" >> "$HOME/versioned-calls"
printf 'typeset -g CACHE_VALUE=%s\n' "$(cat "$HOME/version")"
GENERATOR
chmod +x "$tmp/bin/versioned"
print -r -- one > "$HOME/version"
leos-source-cached versioned "$tmp/bin/versioned"
[[ $CACHE_VALUE == one ]] || fail 'versioned generator first run'
print -r -- two > "$HOME/version"
leos-source-cached versioned "$tmp/bin/versioned"
[[ $CACHE_VALUE == one ]] || fail 'unchanged launcher did not reuse its cache'
__leos_init_cache versioned "$tmp/bin/versioned"
cache=$REPLY
touch -t 202001010000 "$cache" "$cache.zwc"
leos-source-cached versioned "$tmp/bin/versioned"
[[ $CACHE_VALUE == two ]] || fail 'launcher newer than its cache did not regenerate'
[[ $(wc -l < "$HOME/versioned-calls") -eq 2 ]] || fail 'versioned generator ran an unexpected number of times'

# A generator that succeeds with no output records a private negative marker
# instead of publishing an empty script, and there is nothing to source.
cat > "$tmp/bin/emptyok" <<'GENERATOR'
#!/bin/sh
printf '%s\n' "$0" >> "$HOME/emptyok-calls"
printf '\n\n'
GENERATOR
chmod +x "$tmp/bin/emptyok"
__leos_cache_dir
init_dir=$REPLY
typeset -a before_failed after_failed
before_failed=("$init_dir"/*.failed(N))
CACHE_VALUE=untouched
st=0; leos-source-cached emptyok "$tmp/bin/emptyok" || st=$?
(( st == 1 )) || fail "empty successful generator returned $st, expected 1 (nothing sourced)"
[[ $CACHE_VALUE == untouched ]] || fail 'empty generator changed shell state'
after_failed=("$init_dir"/*.failed(N))
(( $#after_failed == $#before_failed + 1 )) || fail 'empty successful generation was not recorded as .failed'
marker=${after_failed:|before_failed}
zstat -H info -- "$marker"
(( (info[mode] & 8#777) == 8#600 )) || fail 'negative marker is not private'
[[ ! -e ${marker%.failed}.zsh ]] || fail 'empty generator output was published as a cache script'

# A planted marker suppresses the generator (status 3, and 2 from the public
# wrapper) until the launcher is newer than the marker; then it retries, and a
# successful generation clears the marker.
cat > "$tmp/bin/suppressed" <<'GENERATOR'
#!/bin/sh
printf '%s\n' "$0" >> "$HOME/suppressed-calls"
printf 'typeset -g CACHE_VALUE=retried\n'
GENERATOR
chmod +x "$tmp/bin/suppressed"
__leos_init_cache suppressed "$tmp/bin/suppressed"
cache=$REPLY
failed=${cache%.zsh}.failed
rm -f -- "$cache" "$cache.zwc" "$HOME/suppressed-calls"
touch -t 202001010000 "$tmp/bin/suppressed"
# A marker only counts for the identity written on its first line: one left by
# another identity (or none at all) must not suppress this generator.
: > "$failed"
chmod 600 "$failed"
st=0; __leos_init_cache suppressed "$tmp/bin/suppressed" || st=$?
(( st == 0 )) || fail "a .failed without this identity suppressed the generator ($st)"
rm -f -- "$cache" "$cache.zwc" "$HOME/suppressed-calls"
__leos_init_cache_identity suppressed "${${:-$tmp/bin/suppressed}:A}"
print -r -- "$REPLY" > "$failed"
chmod 600 "$failed"
st=0; __leos_init_cache suppressed "$tmp/bin/suppressed" || st=$?
(( st == 3 )) || fail "planted .failed returned $st, expected 3"
CACHE_VALUE=untouched
st=0; leos-source-cached suppressed "$tmp/bin/suppressed" || st=$?
(( st == 2 )) || fail "leos-source-cached with a planted .failed returned $st, expected 2"
[[ $CACHE_VALUE == untouched && ! -e $HOME/suppressed-calls ]] ||
  fail 'a recorded .failed still ran the generator'
touch "$tmp/bin/suppressed"
leos-source-cached suppressed "$tmp/bin/suppressed"
[[ $CACHE_VALUE == retried && -e $HOME/suppressed-calls ]] || fail 'a newer launcher did not retry past .failed'
[[ ! -e $failed && -s $cache ]] || fail 'successful retry left the .failed marker or no cache'

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

# The directory is validated in full once per shell; repeat calls re-check only
# the root and the two profile-owned levels. Count full ancestor walks.
functions -c __leos_cache_safe_path __leos_test_safe_path
integer safe_walks=0
__leos_cache_safe_path() { (( ++safe_walks )); __leos_test_safe_path "$@"; }
__leos_cache_forget
__leos_cache_dir || fail 'cache directory validation'
init_dir=$REPLY
(( safe_walks > 0 )) || fail 'first call did not validate the directory'
safe_walks=0
__leos_cache_dir && [[ $REPLY == $init_dir ]] || fail 'memoized cache directory'
leos-source-cached secure "$bin" fresh
(( safe_walks == 0 )) || fail "memoized directory was re-walked $safe_walks time(s)"
# Any change to a checked level drops the memo: validate again, and repair.
chmod 755 "$init_dir"
__leos_cache_dir || fail 'revalidation after chmod'
(( safe_walks > 0 )) || fail 'a changed directory mode did not trigger full validation'
zstat -H info -- "$init_dir"
(( (info[mode] & 8#777) == 8#700 )) || fail 'revalidation did not repair the directory mode'
chmod 777 "$XDG_CACHE_HOME"
if __leos_cache_dir; then fail 'a root made world-writable after validation stayed trusted'; fi
safe_walks=0
if __leos_cache_dir; then fail 'memoized failure'; fi
(( safe_walks == 0 )) || fail 'a memoized failure was re-walked'
[[ $__leos_cache_unsafe == $XDG_CACHE_HOME ]] || fail "memoized failure lost the unsafe path: $__leos_cache_unsafe"
chmod 700 "$XDG_CACHE_HOME"
if __leos_cache_dir; then fail 'memoized failure was not kept for this shell'; fi
__leos_cache_forget
__leos_cache_dir || fail 'forgetting the memo did not revalidate'
# A different root (or EUID) is a different memo key.
(
  export XDG_CACHE_HOME=$tmp/other-root
  __leos_cache_dir && [[ $REPLY == $tmp/other-root/leos-profiles/init ]] || fail 'memo leaked across cache roots'
)
functions -c __leos_test_safe_path __leos_cache_safe_path

# A cache hit runs no external command at all: no PATH, still a hit.
__leos_init_cache secure "$bin" fresh
cache=$REPLY
(
  path=()
  hash -r
  __leos_init_cache secure "$bin" fresh && [[ $REPLY == $cache ]] || fail 'cache hit needed an external command'
)

# Each entry starts with its full identity. Control characters in any field are
# escaped onto that one line, and an entry whose identity differs (a forged or
# colliding first line) is regenerated rather than used.
__leos_init_cache forge "$bin" $'one\n# leos-id: v1 forged'
cache=$REPLY
lines=("${(@f)$(<$cache)}")
[[ $lines[1] == "# leos-id: v1 forge "*" \$'one\\n# leos-id: v1 forged'" ]] ||
  fail "identity line does not escape a newline: $lines[1]"
[[ $lines[2] == 'typeset -g CACHE_VALUE='* ]] || fail 'identity line must be a single line'
print -rl -- '# leos-id: v1 someone-else' 'typeset -g CACHE_VALUE=forged' > "$cache"
rm -f -- "$cache.zwc"
leos-source-cached forge "$bin" $'one\n# leos-id: v1 forged'
[[ $CACHE_VALUE != forged ]] || fail 'an entry with a different identity was used'
IFS= read -r line < "$cache"
[[ $line == $lines[1] ]] || fail 'a mismatched entry was not regenerated'

# Keys are encoded reversibly into file names: `%` and separators are escaped,
# so `a:b` and `a%3Ab` cannot share an entry name.
__leos_init_cache_name 'a:b' x; first=$REPLY
__leos_init_cache_name 'a%3Ab' x; second=$REPLY
[[ $first == a%3Ab.* && $second == a%253Ab.* ]] || fail "key encoding: $first $second"

# Entries named by the SHA-256 of their identity (earlier versions) are removed
# when the directory is validated; nothing else is touched.
legacy_name=${(l:64::a:)${:-}}
: > "$init_dir/$legacy_name.zsh"
: > "$init_dir/$legacy_name.zsh.zwc"
: > "$init_dir/$legacy_name.failed"
: > "$init_dir/keep-me.zsh"
__leos_cache_forget
__leos_cache_dir || fail 'validation with legacy entries'
legacy=("$init_dir"/$legacy_name*(N))
(( $#legacy == 0 )) || fail "legacy hash-named entries survived: $legacy"
[[ -e $init_dir/keep-me.zsh ]] || fail 'legacy cleanup removed an unrelated entry'
rm -f -- "$init_dir/keep-me.zsh"

# A stamp from today answers __leos_daily_due without validating anything; a
# stale or missing one validates before the job may run.
functions -c __leos_cache_dir_validate __leos_test_validate
integer validations=0
__leos_cache_dir_validate() { (( ++validations )); __leos_test_validate "$@"; }
__leos_cache_forget
rm -f -- "$init_dir/stamp-test"
__leos_daily_due stamp-test || fail 'a missing stamp was not due'
(( validations == 1 )) || fail "a due job validated $validations time(s)"
__leos_cache_forget
validations=0
if __leos_daily_due stamp-test; then fail 'a fresh stamp was due again'; fi
(( validations == 0 )) || fail 'a fresh stamp still validated the directory'
touch -t 202001010000 "$init_dir/stamp-test"
__leos_daily_due stamp-test || fail 'a stale stamp was not due'
(( validations == 1 )) || fail 'a stale stamp did not validate the directory'
functions -c __leos_test_validate __leos_cache_dir_validate
rm -f -- "$init_dir/stamp-test"

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
