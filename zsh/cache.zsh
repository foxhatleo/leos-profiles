# Leo's Profiles — cached tool initialisation and shim upkeep.
# Sourced by start.zsh before any path/ entry runs, so every entry can use it.

# Deterministic tool scripts are cached privately. Homebrew shellenv and fnm
# env are deliberately not cached: their output depends on the invoking shell.
# The identity includes the launcher, arguments, HOME and version-manager roots.
# Launcher mtimes invalidate entries; use leos-refresh-init-cache after upgrades
# that change only a separate implementation file.

# Validate every existing ancestor. Root-owned sticky temporary directories are
# safe ancestors: other users cannot replace a child owned by this user there.
# Allow root-owned platform aliases such as macOS /var, but reject symlinks
# at the supplied cache root or inside the profile-owned cache tree.
__leos_cache_safe_path() {
  emulate -L zsh
  zmodload zsh/stat || return 1
  # Lexical normalization can erase a symlink/.. pair before validation even
  # though the kernel follows the symlink first. Refuse these paths outright.
  [[ /$1/ != */../* ]] || return 1
  local item origin
  local -A info
  # Check both chains: lexical parents protect the aliases themselves, while
  # physical parents protect root-owned aliases that point elsewhere.
  for origin in "${1:a}" "${1:A}"; do
    item=$origin
    while true; do
      if [[ -L $item ]]; then
        zstat -L -H info -- "$item" 2>/dev/null || return 1
        (( info[uid] == 0 )) || return 1
      fi
      zstat -H info -- "$item" 2>/dev/null || return 1
      (( info[uid] == EUID || info[uid] == 0 )) || return 1
      if (( info[mode] & 8#22 )); then
        (( (info[mode] & 8#1000) && info[uid] == 0 && (info[mode] & 8#170000) == 8#40000 )) || return 1
      fi
      [[ $item != / ]] || break
      item=${item:h}
    done
  done
}

__leos_cache_safe_file() {
  emulate -L zsh
  zmodload zsh/stat || return 1
  local -A info
  [[ -f $1 && ! -L $1 ]] || return 1
  zstat -H info -- "$1" 2>/dev/null || return 1
  (( info[uid] == EUID && !(info[mode] & 8#22) ))
}

# Create only inside already-validated ancestors, with private permissions.
# REPLY receives the directory. Owned legacy cache directories are migrated
# after their parents are validated; unrelated or unsafe storage is untouched.
__leos_cache_dir() {
  emulate -L zsh
  setopt localoptions localtraps
  local root=${XDG_CACHE_HOME:-$HOME/.cache} item ancestor insecure=0
  local -A info
  [[ $root == /* && ! -L $root && /$root/ != */../* ]] || return 1
  ancestor=$root
  while [[ ! -e $ancestor ]]; do
    [[ ! -L $ancestor ]] || return 1
    ancestor=${ancestor:h}
  done
  __leos_cache_safe_path "$ancestor" || return 1
  local old_umask=$(umask)
  umask 077
  {
    mkdir -p -- "$root" 2>/dev/null || return 1
    __leos_cache_safe_path "$root" || return 1
    for item in "$root/leos-profiles" "$root/leos-profiles/init"; do
      [[ ! -L $item ]] || return 1
      [[ -d $item ]] || mkdir -- "$item" 2>/dev/null || return 1
      [[ -O $item ]] || return 1
      zstat -H info -- "$item" 2>/dev/null || return 1
      (( !(info[mode] & 8#22) )) || insecure=1
      # Only these two profile-owned directories are repaired. Never chmod
      # the user's HOME, shared XDG root, or an unowned/symlink directory.
      if (( (info[mode] & 8#777) != 8#700 )); then
        chmod 700 "$item" 2>/dev/null || return 1
      fi
      __leos_cache_safe_path "$item" || return 1
    done
    if (( insecure )); then
      # Other accounts could have changed even owner-only files while their
      # containing directory was writable. Discard all executable cache bodies
      # and negative/rehash markers only AFTER both directories are private.
      local -a stale=("$item"/*.zsh(N) "$item"/*.zwc(N) "$item"/*.failed(N) "$item"/*-rehash(N))
      (( ! $#stale )) || rm -f -- "${stale[@]}" 2>/dev/null || return 1
    fi
    REPLY=$item
  } always {
    umask "$old_umask"
  }
}

__leos_cache_warn_fallback() {
  [[ ${__leos_cache_fallback_warned:-0} == 1 ]] && return 0
  typeset -g __leos_cache_fallback_warned=1
  print -u2 -r -- "Leo's Profiles: init cache is unsafe or unavailable at ${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init; using freshly generated initialization for this shell."
}

# __leos_init_cache <key> <bin> [args...]
# 0: REPLY is a verified script path; 1: REPLY is fresh text to eval;
# 2: fresh empty/failed generation; 3: a previously recorded empty generation.
__leos_init_cache() {
  emulate -L zsh
  local key=$1 bin=$2
  shift 2
  local real=${bin:A} dir digest cache failed generated stage rc=0
  local usable=0 untrusted=0
  local -A info
  if __leos_cache_dir; then
    dir=$REPLY
    # NUL separators preserve boundaries, unlike flattened path names or joined
    # arguments. SHA-256 also keeps filenames within filesystem length limits.
    if (( $+commands[sha256sum] )); then
      digest=$(printf '%s\0' "$key" "$real" "$HOME" "${PYENV_ROOT:-}" "${RBENV_ROOT:-}" "$@" | command sha256sum) || digest=
    elif (( $+commands[shasum] )); then
      digest=$(printf '%s\0' "$key" "$real" "$HOME" "${PYENV_ROOT:-}" "${RBENV_ROOT:-}" "$@" | command shasum -a 256) || digest=
    fi
    digest=${digest%% *}
    if [[ ${#digest} == 64 && $digest != *[^0-9a-f]* ]]; then
      cache=$dir/$digest.zsh
      failed=$dir/$digest.failed
      usable=1
      # Check even stale entries and compiled siblings: never follow an unsafe
      # destination while replacing it, and never let source choose hostile .zwc.
      local f
      for f in "$cache" "$cache.zwc" "$failed"; do
        if [[ -e $f || -L $f ]]; then
          if [[ ! -f $f || -L $f || ! -O $f ]]; then
            usable=0
            continue
          fi
          zstat -H info -- "$f" 2>/dev/null || { usable=0; continue; }
          (( !(info[mode] & 8#22) )) || untrusted=1
          if (( (info[mode] & 8#777) != 8#600 )); then
            chmod 600 "$f" 2>/dev/null || usable=0
          fi
        fi
      done
      if (( usable && untrusted )); then
        # Permission repair cannot establish the provenance of writable code.
        # Throw away the text, compiled sibling and marker as a single entry.
        rm -f -- "$cache" "$cache.zwc" "$failed" 2>/dev/null || usable=0
      fi
      if (( usable )); then
        if [[ -s $cache && ! $real -nt $cache ]]; then
          REPLY=$cache
          return 0
        fi
        [[ ! -e $failed || $real -nt $failed ]] || return 3
      fi
    fi
  fi

  (( usable )) || __leos_cache_warn_fallback
  generated=$("$bin" "$@" 2>/dev/null) || rc=$?
  # Failed generators may print diagnostics or partial code on stdout. Never
  # execute or persist that output, and allow the next shell to retry.
  (( rc == 0 )) || return 2
  if (( ! usable )); then
    [[ -n $generated ]] || return 2
    REPLY=$generated
    return 1
  fi

  # mktemp creates the staging file with mode 600 even under a permissive umask.
  stage=$(mktemp "$dir/.init.XXXXXXXX" 2>/dev/null) || {
    __leos_cache_warn_fallback
    [[ -n $generated ]] || return 2
    REPLY=$generated; return 1
  }
  if [[ -z $generated ]]; then
    mv -f -- "$stage" "$failed" 2>/dev/null || rm -f -- "$stage"
    return 2
  fi
  if ! print -r -- "$generated" > "$stage"; then
    __leos_cache_warn_fallback
    rm -f -- "$stage"
    REPLY=$generated; return 1
  fi
  # Publish complete files only. Remove a previous compiled script before the
  # new text becomes visible, so source cannot select an older compiled body.
  if ! { rm -f -- "$cache.zwc" && mv -f -- "$stage" "$cache"; } 2>/dev/null; then
    __leos_cache_warn_fallback
    rm -f -- "$stage"
    REPLY=$generated; return 1
  fi
  rm -f -- "$failed" 2>/dev/null
  # Compilation is optional. Its private temporary directory also protects the
  # compiler's output before chmod, irrespective of the caller's umask.
  local compiled_dir
  compiled_dir=$(mktemp -d "$dir/.compile.XXXXXXXX")
  if [[ -n $compiled_dir ]]; then
    if zcompile -R "$compiled_dir/script.zwc" "$cache" 2>/dev/null; then
      chmod 600 "$compiled_dir/script.zwc" && mv -f -- "$compiled_dir/script.zwc" "$cache.zwc"
    fi
    rm -rf -- "$compiled_dir"
  fi
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
  # `|| true` is what actually makes the "ignore the script's own status" promise
  # hold: without it, a cached script ending in a false command returns non-zero
  # from `source`, and under a caller's ERR_RETURN that returns from this function
  # before the `return 0` below is ever reached.
  case $__leos_cache_status in
    0) source "$REPLY" || true; return 0 ;;
    1) eval "$REPLY"  || true; return 0 ;;
    2) return 1 ;;
    *) return 2 ;;
  esac
}

# leos-source-cached-warn <message> <key> <bin> [args...]
# The form every startup file should use. As leos-source-cached, but:
#   - reports <message> the FIRST time the generator yields nothing, and stays
#     quiet afterwards (repeating it on every shell would just be noise);
#   - always returns 0, so a bare call cannot abort the calling file under
#     ERR_RETURN. Note `(( guard )) && leos-source-cached …` is NOT safe: a
#     failing command on the right of && does trip ERR_RETURN.
leos-source-cached-warn() {
  local __leos_warn_msg=$1
  shift
  local __leos_warn_status=0
  leos-source-cached "$@" || __leos_warn_status=$?
  (( __leos_warn_status == 1 )) && puts-err "$__leos_warn_msg"
  return 0
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
  if ! __leos_cache_dir; then
    puts-err "Refusing to clear an unsafe init cache: $dir"
    return 1
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
  __leos_cache_dir || return 0
  local stamp=$REPLY/$tool-rehash
  [[ ! -e $stamp && ! -L $stamp ]] || __leos_cache_safe_file "$stamp" || return 0
  [[ -z $stamp(#qN.mh-24) ]] || return 0
  local staging
  staging=$(mktemp "${stamp:h}/.rehash.XXXXXXXX") || return 0
  mv -f -- "$staging" "$stamp" || { rm -f -- "$staging"; return 0; }
  # Detach in a subshell to keep job notifications out of interactive startup.
  # Test fixtures disable this side effect rather than racing their cleanup.
  setopt no_bgnice
  (command "$tool" rehash &) >/dev/null 2>&1
  return 0
}

:
