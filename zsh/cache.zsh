# Leo's Profiles — cached tool initialisation and shim upkeep.
# Sourced by start.zsh before any path/ entry runs, so every entry can use it.

# Cached tool initialisation.
#
# Tools like `brew shellenv`, `pyenv init` and `starship init` print a
# deterministic script whose only per-shell parts (`$PATH`, `$RANDOM`, command
# substitutions) are expanded when the script is *sourced*, not when it is
# generated — so the generated text can be cached and re-sourced verbatim.
# Spawning these generators on every interactive shell is the single largest
# avoidable startup cost, so cache them on disk instead.
#
# The cache is keyed by the resolved binary path, so a version manager's
# per-shell shim directory does not thrash it while a genuine version switch
# gets its own entry, and it is invalidated when that binary is newer than the
# cache. Bump <key> when the arguments change, since they are not part of it.
#
# NOT for generators that embed per-process state: `fnm env` mints a unique
# FNM_MULTISHELL_PATH per invocation and must never be cached.

# __leos_init_cache <key> <bin> [args...]
# Sets REPLY to a file holding the stdout of `<bin> [args...]`, regenerating it
# when that binary is newer than the cache.
#
#   0  REPLY is a cache file to source.
#   1  the cache is unwritable; REPLY holds the generated text to eval instead.
#   2  the generator just produced nothing. Worth telling the user about once.
#   3  the generator produced nothing on an earlier shell, remembered in a marker
#      file so a broken or too-old generator is not respawned every time. Stay
#      quiet: whatever needed saying was said when the marker was created.
#
# Freshness is keyed on the mtime of the *resolved launcher*. For tools whose
# init logic lives in a separate file (brew's shellenv.sh, pyenv's
# libexec/pyenv-init), an in-place upgrade that leaves the launcher untouched
# will not invalidate the cache — run `leos-refresh-init-cache` after one.
__leos_init_cache() {
  emulate -L zsh
  local key=$1 bin=$2
  shift 2
  local real=${bin:A}
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init
  # ':A' output is path-safe once its separators are flattened.
  local base=$dir/$key${real//[^A-Za-z0-9]/_}
  local cache=$base.zsh failed=$base.failed
  local generated

  # Happy path: a single stat, no forks, no extra work.
  if [[ -s $cache && ! $real -nt $cache ]]; then
    REPLY=$cache
    return 0
  fi
  if [[ -e $failed && ! $real -nt $failed ]]; then
    return 3
  fi

  generated=$("$bin" "$@" 2>/dev/null)

  # Fall back to handing back the text itself when the cache is unwritable, so
  # a read-only or full cache directory degrades instead of breaking the shell.
  if ! mkdir -p $dir 2>/dev/null; then
    [[ -n $generated ]] || return 2
    REPLY=$generated
    return 1
  fi

  if [[ -z $generated ]]; then
    : > $failed 2>/dev/null
    return 2
  fi

  if ! { print -r -- "$generated" > $cache.$$ 2>/dev/null && mv -f $cache.$$ $cache 2>/dev/null }; then
    rm -f $cache.$$ 2>/dev/null
    REPLY=$generated
    return 1
  fi
  rm -f $failed 2>/dev/null
  # Compile it as well: `source` prefers a newer .zwc, which removes the parse
  # cost on top of the spawn cost (worth real time for large completion dumps).
  zcompile -R $cache 2>/dev/null || true
  REPLY=$cache
  return 0
}

# leos-source-cached <key> <bin> [args...]
# Status describes whether there was anything to source, NOT what the sourced
# script returned:
#   0  something was sourced.
#   1  nothing was available; the caller may fall back. Warn about it.
#   2  nothing was available and that was already reported on an earlier shell.
#
# Deliberately ignores the sourced script's own exit status. Several generators
# legitimately end in a false command — heroku's snippet ends in
# `test -f … && source …`, false on any machine that has not run
# `heroku autocomplete` — and treating that as failure would send callers like
# path/fzf.zsh down a fallback path that double-binds widgets.
#
# Deliberately NOT `emulate -L zsh`: sourced init scripts legitimately set
# options for the whole shell (starship needs PROMPT_SUBST), and `emulate -L`
# would scope those changes to this function and silently break them.
#
# Note this sources inside a function, so a generator emitting a bare top-level
# `local`/`typeset` would scope that name here. Every generator wired up today
# either avoids it or uses `typeset -g`; check any new one before adding it.
leos-source-cached() {
  # `|| status=$?` rather than a bare call: this function has no `emulate -L`,
  # so a caller's ERR_RETURN would otherwise return here before we could branch.
  local __leos_cache_status=0
  __leos_init_cache "$@" || __leos_cache_status=$?
  case $__leos_cache_status in
    0) source $REPLY; return 0 ;;
    1) eval "$REPLY";  return 0 ;;
    2) return 1 ;;
    *) return 2 ;;
  esac
}

# Drop every cached init script, forcing regeneration on the next shell. Needed
# after an upgrade that rewrites a tool's init logic without touching the
# launcher binary the cache is keyed on (see __leos_init_cache).
leos-refresh-init-cache() {
  # No sourcing happens here, so localizing options is safe and makes the globs
  # below behave regardless of the ambient option set.
  emulate -L zsh
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init
  if [[ ! -d $dir ]]; then
    puts "No init cache to clear."
    return 0
  fi
  # (N) is required, not decorative: with the default NOMATCH, a single pattern
  # matching nothing aborts the whole `rm` and silently clears nothing at all.
  local -a stale=($dir/*.zsh(N) $dir/*.zwc(N) $dir/*.failed(N))
  if (( $#stale )); then
    rm -f -- $stale
    puts "Cleared $#stale cached init file(s) in $dir. Restart the shell to regenerate."
  else
    puts "Init cache in $dir is already empty."
  fi
  return 0
}

# __leos_rehash_daily <tool>
# Refresh a version manager's shims in the background, at most once a day.
#
# `<tool> init` is asked to skip its own rehash because that is a synchronous
# ~100ms+ shim rewrite on every single shell. The tools' own `install`
# commands rehash themselves, but `pip install` / `gem install` do not, so
# without this a newly installed console script would never appear. The shims
# directory is already on PATH — rehash only adds files inside it — so doing
# this detached, after the prompt is up, is enough.
__leos_rehash_daily() {
  emulate -L zsh
  setopt extended_glob
  local tool=$1
  local stamp=${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init/$tool-rehash
  [[ -z $stamp(#qN.mh-24) ]] || return 0
  mkdir -p ${stamp:h} 2>/dev/null || return 0
  : > $stamp 2>/dev/null || return 0
  (command $tool rehash &) >/dev/null 2>&1
  return 0
}

:
