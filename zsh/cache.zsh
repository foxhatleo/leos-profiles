# Leo's Profiles — cached tool initialisation, shim upkeep and profile flags.
# Sourced by start.zsh before any path/ entry runs, so every entry can use it.

# __leos_set_flag <name> / __leos_clear_flag <name>
# A flag is an empty file in $LEOS_PROFILES/local/flags that switches a profile
# behaviour (no-gnu, brew-china, ...). local/ and flags/ are kept private (700)
# and each flag file 600, as the installer's prepare_local_dir does. Names are
# plain words, never paths.
__leos_set_flag() {
  emulate -L zsh
  local dir=${LEOS_PROFILES-}/local/flags
  [[ -n ${LEOS_PROFILES-} && -n $1 && -z ${1//[A-Za-z0-9_-]/} ]] || return 2
  command mkdir -p -- "$dir" && chmod 700 "${dir:h}" "$dir" &&
    touch -- "$dir/$1" && chmod 600 "$dir/$1"
}
__leos_clear_flag() {
  emulate -L zsh
  [[ -n ${LEOS_PROFILES-} && -n $1 && -z ${1//[A-Za-z0-9_-]/} ]] || return 2
  rm -f -- "$LEOS_PROFILES/local/flags/$1"
}

# Deterministic tool scripts are cached privately. Homebrew shellenv and fnm
# env are deliberately not cached: their output depends on the invoking shell.
# The identity includes the launcher, arguments, HOME and version-manager roots.
# Launcher mtimes invalidate entries; use leos-refresh-init-cache after upgrades
# that change only a separate implementation file.
#
# Every cache hit runs during shell startup, so the hit path stays fork-free:
# the directory is fully validated once per shell and memoized, entries are
# named in-process, and each entry's first line records its full identity,
# which is compared before the entry is used.

# A user-private group (useradd's USERGROUPS_ENAB default, often paired with
# umask 002) grants nobody else write access. It must be the user's primary
# group, carry the user's name and list no other members. One lookup per shell.
__leos_private_group() {
  emulate -L zsh
  local gid=$1 entry
  local -a fields
  (( gid == GID )) || return 1
  if [[ -z ${__leos_private_gid-} ]]; then
    typeset -g __leos_private_gid=-1
    entry=$(command getent group "$gid" 2>/dev/null) || return 1
    fields=("${(@s.:.)entry}")
    [[ ${fields[1]-} == "$USERNAME" && ${fields[3]-} == "$gid" ]] || return 1
    [[ -z ${fields[4]-} || ${fields[4]} == "$USERNAME" ]] || return 1
    __leos_private_gid=$gid
  fi
  (( __leos_private_gid == gid ))
}

# Validate every existing ancestor. Root-owned sticky temporary directories are
# safe ancestors: other users cannot replace a child owned by this user there.
# Allow root-owned platform aliases such as macOS /var, but reject symlinks
# at the supplied cache root or inside the profile-owned cache tree. The first
# rejected path is kept in __leos_cache_unsafe for the fallback warning.
__leos_cache_safe_path() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat || return 1
  # Lexical normalization can erase a symlink/.. pair before validation even
  # though the kernel follows the symlink first. Refuse these paths outright.
  [[ /$1/ != */../* ]] || { typeset -g __leos_cache_unsafe=$1; return 1; }
  local item origin rejected=
  local -A info
  # Check both chains: lexical parents protect the aliases themselves, while
  # physical parents protect root-owned aliases that point elsewhere.
  for origin in "${1:a}" "${1:A}"; do
    item=$origin
    while true; do
      if [[ -L $item ]]; then
        zstat -L -H info -- "$item" 2>/dev/null || { rejected=$item; break 2; }
        (( info[uid] == 0 )) || { rejected=$item; break 2; }
      fi
      zstat -H info -- "$item" 2>/dev/null || { rejected=$item; break 2; }
      (( info[uid] == EUID || info[uid] == 0 )) || { rejected=$item; break 2; }
      if (( info[mode] & 8#22 )); then
        # Allowed: a root-owned sticky directory, or one owned by this user and
        # writable only through the user's private group (never by others).
        if (( !((info[mode] & 8#1000) && info[uid] == 0 && (info[mode] & 8#170000) == 8#40000) )); then
          (( info[uid] == EUID && !(info[mode] & 8#2) )) &&
            __leos_private_group "$info[gid]" || { rejected=$item; break 2; }
        fi
      fi
      [[ $item != / ]] || break
      item=${item:h}
    done
  done
  [[ -n $rejected ]] || return 0
  typeset -g __leos_cache_unsafe=$rejected
  return 1
}

__leos_cache_safe_file() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat || return 1
  local -A info
  [[ -f $1 && ! -L $1 ]] || return 1
  zstat -H info -- "$1" 2>/dev/null || return 1
  (( info[uid] == EUID && !(info[mode] & 8#22) ))
}

# Full validation; __leos_cache_dir below memoizes its result per shell.
# Create only inside already-validated ancestors, with private permissions.
# REPLY receives the directory. Entries an earlier version named by digest are
# removed from it; unrelated or unsafe storage is untouched.
__leos_cache_dir_validate() {
  emulate -L zsh
  setopt extended_glob
  zmodload -F zsh/stat b:zstat || return 1
  local root=${XDG_CACHE_HOME:-$HOME/.cache} item ancestor insecure=0
  local dir=$root/leos-profiles/init
  local -a missing
  local -A info
  typeset -g __leos_cache_unsafe= __leos_cache_unsafe_fix=
  [[ $root == /* && ! -L $root && /$root/ != */../* ]] || return 1
  ancestor=$root
  while [[ ! -e $ancestor ]]; do
    [[ ! -L $ancestor ]] || return 1
    missing=("$ancestor" $missing)
    ancestor=${ancestor:h}
  done
  __leos_cache_safe_path "$ancestor" || return 1
  # Create the missing levels one at a time, and only when missing: `mkdir -m
  # 700` sets the mode whatever the caller's umask, so there is no umask to
  # save and restore (reading it back costs a fork). A level another shell
  # created first is accepted here and validated with the whole chain below.
  # A level created here gets no ACL either (an inheritable one on its parent
  # would otherwise be copied onto it; see __leos_acl_strip).
  for item in $missing; do
    if command mkdir -m 700 -- "$item" 2>/dev/null; then
      __leos_acl_strip "$item"
    else
      [[ -d $item && ! -L $item ]] || return 1
    fi
  done
  __leos_cache_safe_path "$root" || return 1
  for item in "$root/leos-profiles" "$root/leos-profiles/init"; do
    [[ ! -L $item ]] || return 1
    if [[ ! -d $item ]]; then
      if command mkdir -m 700 -- "$item" 2>/dev/null; then
        __leos_acl_strip "$item"
      else
        [[ -d $item && ! -L $item ]] || return 1
      fi
    fi
    [[ -O $item ]] || return 1
    zstat -H info -- "$item" 2>/dev/null || return 1
    (( !(info[mode] & 8#22) )) || insecure=1
    # Only these two profile-owned directories are repaired. Never chmod
    # the user's HOME, shared XDG root, or an unowned/symlink directory.
    if (( (info[mode] & 8#777) != 8#700 )); then
      chmod 700 "$item" 2>/dev/null || return 1
      __leos_acl_strip "$item"
    fi
    __leos_cache_safe_path "$item" || return 1
  done
  if (( insecure )); then
    # Other accounts could have changed even owner-only files while their
    # containing directory was writable. Discard all executable cache bodies
    # and negative/rehash markers only AFTER both directories are private.
    local -a stale=("$dir"/*.zsh(N) "$dir"/*.zwc(N) "$dir"/*.failed(N) "$dir"/*-rehash(N))
    (( ! $#stale )) || rm -f -- "${stale[@]}" 2>/dev/null || return 1
  fi
  # Earlier versions named entries by the SHA-256 of their identity. Nothing
  # looks those names up any more: remove them (regular files only). Remove
  # this sweep after 2027-04.
  local -a legacy=("$dir"/[0-9a-f](#c64).(zsh|zsh.zwc|failed)(N.))
  (( ! $#legacy )) || rm -f -- "${legacy[@]}" 2>/dev/null
  REPLY=$dir
}

# __leos_acl_strip <path...>
# macOS only: remove every ACL entry (chmod -N) from a directory or file the
# cache creates or repairs. Mode bits do not show ACLs, and an inheritable
# entry on a parent is copied onto each new child (SEC-10). A no-op elsewhere.
__leos_acl_strip() {
  [[ $OSTYPE == darwin* ]] || return 0
  command /bin/chmod -N "$@" 2>/dev/null
}

# __leos_cache_acl_unsafe <ls -le output>
# reply: the header line of each listed file or directory with an ACL entry
# that allows a principal other than this user a right that changes content
# (write, append, add_file, add_subdirectory, delete_child) or the ACL and
# owner themselves (writesecurity, chown). Entry lines look like
# ` 0: group:everyone [inherited] allow add_file,delete_child`.
__leos_cache_acl_unsafe() {
  emulate -L zsh
  setopt extended_glob
  local line header= perm
  local -a words
  reply=()
  for line in "${(@f)1}"; do
    if [[ $line == [[:space:]]##<->:[[:space:]]* ]]; then
      words=(${=line})
      [[ $words[2] != "user:$USERNAME" ]] || continue
      (( ${words[(Ie)allow]} )) || continue
      for perm in ${(s:,:)words[-1]}; do
        case $perm in
          write|append|add_file|add_subdirectory|delete_child|writesecurity|chown)
            [[ -z $header ]] || (( ${reply[(Ie)$header]} )) || reply+=("$header")
            break ;;
        esac
      done
    else
      header=$line
    fi
  done
}

# __leos_stamp_write <stamp>: publish a fresh private stamp file.
__leos_stamp_write() {
  local staging
  staging=$(mktemp "${1:h}/.stamp.XXXXXXXX") || return 1
  __leos_acl_strip "$staging"
  mv -f -- "$staging" "$1" || { rm -f -- "$staging"; return 1; }
}

# __leos_cache_acl_check <root> <dir>
# macOS only (SEC-10), during a full validation: mode bits do not show ACLs,
# and an ACL entry can let another account write where the mode says nobody
# can. Lists (/bin/ls -le, a fork or three) the ACLs of the cache root, the two
# profile-owned directories and the files in those two. A directory with an
# unsafe entry (see above) makes the cache unsafe: this fails and names it in
# __leos_cache_unsafe. Such a file is removed instead; it is regenerated.
#
# At most once a day, like __leos_daily_due, and also again whenever one of
# the three directories changed: the stamp records their ctimes, which an ACL
# change or a new entry (which may have inherited an ACL) updates. Residual
# gap: an account granted write access after a passing check (only the owner
# or root can grant it) could rewrite the stamp before the next shell
# validates, and so hide the ACL for up to a day.
__leos_cache_acl_check() {
  emulate -L zsh
  setopt extended_glob
  [[ $OSTYPE == darwin* && -x /bin/ls ]] || return 0
  zmodload -F zsh/stat b:zstat || return 1
  local root=$1 dir=$2 stamp=$2/acl-checked line item f
  local -a dirs=("$1" "${2:h}" "$2")
  __leos_cache_acl_ctimes $dirs || return 1
  if [[ -n $stamp(#qN.mh-24) ]] && __leos_cache_safe_file "$stamp" &&
      { IFS= read -r line || [[ -n $line ]]; } < "$stamp" 2>/dev/null &&
      [[ $line == "$REPLY" ]]; then
    return 0
  fi
  __leos_cache_acl_unsafe "$(/bin/ls -lde -- $dirs 2>/dev/null)"
  for line in $reply; do
    for item in $dirs; do
      [[ $line == *" $item" ]] || continue
      rm -f -- "$stamp" 2>/dev/null
      typeset -g __leos_cache_unsafe=$item __leos_cache_unsafe_fix='chmod -N'
      return 1
    done
  done
  for item in "${dir:h}" "$dir"; do
    __leos_cache_acl_unsafe "$(/bin/ls -leA -- "$item" 2>/dev/null)"
    for line in $reply; do
      f=$item/${line##* }
      [[ ! -f $f || -L $f ]] || rm -f -- "$f" 2>/dev/null
    done
  done
  # Creating the stamp changes the directory's ctime, so a new stamp stays
  # empty and the next full validation checks again; later checks rewrite it
  # in place, which leaves the directory alone. ctimes have one-second
  # resolution here: a tree changed within the current second is not
  # recorded, so a change right after this check cannot hide behind it.
  if [[ ! -e $stamp && ! -L $stamp ]]; then
    __leos_stamp_write "$stamp"
    return 0
  fi
  __leos_cache_safe_file "$stamp" || return 0
  zmodload -F zsh/datetime p:EPOCHSECONDS 2>/dev/null || return 0
  if __leos_cache_acl_ctimes $dirs && (( REPLY_MAX < EPOCHSECONDS )); then
    print -r -- "$REPLY" > "$stamp" 2>/dev/null
  else
    : > "$stamp" 2>/dev/null
  fi
  return 0
}

# __leos_cache_acl_ctimes <path...>: REPLY gets their ctimes, not following
# links, and REPLY_MAX the latest of them.
__leos_cache_acl_ctimes() {
  emulate -L zsh
  local item sig=
  local -A info
  typeset -g REPLY_MAX=0
  for item in "$@"; do
    zstat -L -H info -- "$item" 2>/dev/null || return 1
    sig+="$info[ctime]:"
    (( info[ctime] <= REPLY_MAX )) || REPLY_MAX=$info[ctime]
  done
  REPLY=$sig
}

# __leos_cache_dir_sig <path...>
# REPLY: owner, mode, inode and device of each path, not following symlinks.
__leos_cache_dir_sig() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat || return 1
  local item sig=
  local -A info
  for item in "$@"; do
    zstat -L -H info -- "$item" 2>/dev/null || return 1
    sig+="$info[uid]:$info[mode]:$info[inode]:$info[device]/"
  done
  REPLY=$sig
}

# The private init-cache directory: REPLY receives it, or the call fails and
# __leos_cache_unsafe names the first rejected path.
#
# Full validation walks every ancestor along two chains and costs several
# milliseconds, and one startup asks for the directory about a dozen times. The
# result is therefore memoized per shell, keyed on the cache root and EUID. A
# repeat call re-checks only the cache root and the two profile-owned levels,
# one lstat each: any change in their owner, mode or identity (a chmod, a
# replacement, a symlink) drops the memo and validates in full again. Further
# ancestors are trusted for the rest of this shell; every new shell validates
# them again. A failed validation is memoized the same way, so the fallback
# path does not re-walk the tree on every call; leos-refresh-init-cache and a
# changed root or EUID start over.
__leos_cache_dir() {
  emulate -L zsh
  local root=${XDG_CACHE_HOME:-$HOME/.cache} dir
  local memo="$EUID:$root"
  if [[ ${__leos_cache_memo_key-} == "$memo" ]]; then
    if [[ -z ${__leos_cache_memo_dir-} ]]; then
      typeset -g __leos_cache_unsafe=${__leos_cache_memo_unsafe-} __leos_cache_unsafe_fix=${__leos_cache_memo_fix-}
      return 1
    fi
    dir=$__leos_cache_memo_dir
    if [[ -d $dir && -O $dir && ! -L $dir ]] &&
        __leos_cache_dir_sig "$root" "${dir:h}" "$dir" &&
        [[ $REPLY == "$__leos_cache_memo_sig" ]]; then
      REPLY=$dir
      return 0
    fi
  fi
  __leos_cache_forget
  if __leos_cache_dir_validate && __leos_cache_acl_check "$root" "$REPLY"; then
    dir=$root/leos-profiles/init
    # Without a signature there is nothing cheap to re-check: do not memoize.
    if __leos_cache_dir_sig "$root" "${dir:h}" "$dir"; then
      typeset -g __leos_cache_memo_key=$memo __leos_cache_memo_dir=$dir __leos_cache_memo_sig=$REPLY
    fi
    REPLY=$dir
    return 0
  fi
  typeset -g __leos_cache_memo_key=$memo __leos_cache_memo_unsafe=${__leos_cache_unsafe-} \
    __leos_cache_memo_fix=${__leos_cache_unsafe_fix-}
  return 1
}

# Drop the memo, so the next __leos_cache_dir validates in full.
__leos_cache_forget() {
  typeset -g __leos_cache_memo_key= __leos_cache_memo_dir= __leos_cache_memo_sig= \
    __leos_cache_memo_unsafe= __leos_cache_memo_fix=
}

__leos_cache_warn_fallback() {
  [[ ${__leos_cache_fallback_warned:-0} == 1 ]] && return 0
  typeset -g __leos_cache_fallback_warned=1
  local hint=
  [[ -n ${__leos_cache_unsafe-} ]] &&
    hint=" Unsafe path: ${(q-)__leos_cache_unsafe}; if it should be private to you, run: ${__leos_cache_unsafe_fix:-chmod go-w} ${(q-)__leos_cache_unsafe}"
  print -u2 -r -- "Leo's Profiles: init cache is unsafe or unavailable at ${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init; using freshly generated initialization for this shell.$hint"
}

# __leos_init_cache_identity <key> <real-launcher> [args...]
# REPLY: the identity line every cache entry (script or .failed marker) starts
# with. It holds the key, the resolved launcher, HOME, both version-manager
# roots and every argument. Each field is quoted with (q+), which renders
# newlines, NULs and other control characters as $'...' escapes and quotes
# spaces, so the line is always a single line and no field can fake a
# boundary or a second header.
__leos_init_cache_identity() {
  emulate -L zsh
  local key=$1 real=$2
  shift 2
  local -a fields=(v1 "$key" "$real" "$HOME" "${PYENV_ROOT:-}" "${RBENV_ROOT:-}"
                   "${__leos_init_filter-}" "$@")
  REPLY="# leos-id: ${(j: :)${(@q+)fields}}"
}

# __leos_init_cache_name <key> <identity-line>
# REPLY: the file stem for an entry, computed without a fork. The key is kept
# readable: every byte outside [A-Za-z0-9_-] becomes %XX (so `%` itself is
# always escaped and distinct keys can never share a stem), truncated to stay
# well inside filename limits. A 32-bit FNV-1a digest of the identity line
# follows, so different launchers, arguments and roots get separate entries
# instead of evicting each other. The digest only spreads entries: what makes
# an entry usable is its identity line, compared in full before every use.
__leos_init_cache_name() {
  emulate -L zsh
  setopt no_multibyte
  local key=$1 id=$2 c enc=
  integer h=2166136261
  if [[ $key == *[^A-Za-z0-9_-]* ]]; then
    for c in ${(s::)key}; do
      if [[ $c == [A-Za-z0-9_-] ]]; then
        enc+=$c
      else
        enc+=%${(l:2::0:)$(( [##16] #c ))}
      fi
    done
  else
    enc=$key
  fi
  for c in ${(s::)id}; do
    (( h = ((h ^ #c) * 16777619) & 16#FFFFFFFF ))
  done
  REPLY=${enc[1,160]}.${(l:8::0:)$(( [##16] h ))}
}

# __leos_init_cache <key> <bin> [args...]
# A caller may name a filter function for the generated text with a prefix
# assignment: `__leos_init_filter=fn leos-source-cached ...`. Bump the key when
# the filter's behaviour changes; its name alone is part of the identity.
# 0: REPLY is a verified script path; 1: REPLY is fresh text to eval;
# 2: fresh empty/failed generation; 3: a previously recorded empty generation.
__leos_init_cache() {
  emulate -L zsh
  local key=$1 bin=$2
  shift 2
  local real=${bin:A} dir cache failed generated stage identity line= rc=0
  local usable=0 untrusted=0 f
  local -A info
  __leos_init_cache_identity "$key" "$real" "$@"
  identity=$REPLY
  if __leos_cache_dir; then
    dir=$REPLY
    __leos_init_cache_name "$key" "$identity"
    cache=$dir/$REPLY.zsh
    failed=$dir/$REPLY.failed
    usable=1
    # Check even stale entries and compiled siblings: never follow an unsafe
    # destination while replacing it, and never let source choose hostile .zwc.
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
          __leos_acl_strip "$f"
        fi
      fi
    done
    if (( usable && untrusted )); then
      # Permission repair cannot establish the provenance of writable code.
      # Throw away the text, compiled sibling and marker as a single entry.
      rm -f -- "$cache" "$cache.zwc" "$failed" 2>/dev/null || usable=0
    fi
    if (( usable )); then
      # `read` from a redirection runs in this shell: the identity check costs
      # no fork. A different identity under the same stem (a digest collision)
      # is simply regenerated over.
      if [[ -s $cache && ! $real -nt $cache ]] &&
          { IFS= read -r line || [[ -n $line ]]; } < "$cache" 2>/dev/null &&
          [[ $line == "$identity" ]]; then
        REPLY=$cache
        return 0
      fi
      line=
      if [[ -f $failed && ! $real -nt $failed ]] &&
          { IFS= read -r line || [[ -n $line ]]; } < "$failed" 2>/dev/null &&
          [[ $line == "$identity" ]]; then
        return 3
      fi
    fi
  fi

  (( usable )) || __leos_cache_warn_fallback
  generated=$("$bin" "$@" 2>/dev/null) || rc=$?
  # Failed generators may print diagnostics or partial code on stdout. Never
  # execute or persist that output, and allow the next shell to retry.
  (( rc == 0 )) || return 2
  # An optional filter function, named in the caller's __leos_init_filter (and
  # part of the identity), edits the output in REPLY before it is used or kept.
  if [[ -n ${__leos_init_filter-} ]]; then
    (( $+functions[$__leos_init_filter] )) || return 2
    REPLY=$generated
    "$__leos_init_filter" || return 2
    generated=$REPLY
  fi
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
  __leos_acl_strip "$stage"
  if [[ -z $generated ]]; then
    # The marker carries the identity too: it only suppresses this generator.
    { print -r -- "$identity" > "$stage" && mv -f -- "$stage" "$failed"; } 2>/dev/null ||
      rm -f -- "$stage"
    return 2
  fi
  if ! print -rl -- "$identity" "$generated" > "$stage"; then
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
      chmod 600 "$compiled_dir/script.zwc" && { __leos_acl_strip "$compiled_dir/script.zwc"; :; } &&
        mv -f -- "$compiled_dir/script.zwc" "$cache.zwc"
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
#
# It also recompiles the profile's own sources (see __leos_zcompile_profile),
# with this shell's Zsh: a .zwc from another Zsh version is ignored.
leos-refresh-init-cache() {
  # No sourcing happens here, so localizing options is safe and makes the globs
  # below behave regardless of the ambient option set.
  emulate -L zsh
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init
  [[ -z ${LEOS_PROFILES_ZSH-} ]] || __leos_zcompile_profile "$LEOS_PROFILES_ZSH" || true
  if [[ ! -d $dir ]]; then
    puts "No init cache to clear."
    return 0
  fi
  # Validate in full: the user may have just fixed (or broken) the permissions
  # this shell memoized.
  __leos_cache_forget
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

# __leos_zcompile_profile <zsh-dir>
# Compile the profile's startup files, and the plugin files they source, to a
# .zwc beside each one, so a shell maps bytecode instead of parsing ~300 KB of
# Zsh on every start (about 7 ms). Zsh reads file.zwc only when it is at least
# as new as file and was made by the same Zsh version, so a pulled or edited
# source is never shadowed by an older compilation; this only refreshes them.
# Run by the installer and by leos-refresh-init-cache, never at startup.
#
# A .zwc is written only into a directory this user owns that nobody else can
# write, through a private temporary directory, and only for regular files
# this user owns. Plugin checkouts get `*.zwc` in .git/info/exclude first, so
# they stay clean for the installer's pinned-checkout verification; a plugin
# whose exclude file cannot be updated is left uncompiled.
__leos_zcompile_profile() {
  emulate -L zsh
  setopt extended_glob
  zmodload -F zsh/stat b:zstat || return 1
  zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm 2>/dev/null || return 1
  local zdir=${1:-} plugin src dir work exclude
  local -a sources plugin_files
  local -A info
  integer compiled=0
  [[ -n $zdir && -d $zdir ]] || return 1
  sources=($zdir/*.zsh(N.) $zdir/path/*.zsh(N.))
  for plugin in fzf-tab zsh-autosuggestions zsh-syntax-highlighting; do
    case $plugin in
      fzf-tab) plugin_files=($zdir/plugins/fzf-tab/fzf-tab(|.plugin).zsh(N.)) ;;
      zsh-autosuggestions) plugin_files=($zdir/plugins/$plugin/$plugin.zsh(N.)) ;;
      zsh-syntax-highlighting)
        plugin_files=($zdir/plugins/$plugin/$plugin.zsh(N.)
                      $zdir/plugins/$plugin/highlighters/*/*-highlighter.zsh(N.)) ;;
    esac
    (( $#plugin_files )) || continue
    if [[ -d $zdir/plugins/$plugin/.git ]]; then
      exclude=$zdir/plugins/$plugin/.git/info/exclude
      if [[ ! -f $exclude ]] || (( ! ${${(f)"$(<$exclude)"}[(Ie)*.zwc]} )); then
        [[ -d ${exclude:h} ]] || zf_mkdir -p -- "${exclude:h}" 2>/dev/null || continue
        print -r -- $'\n*.zwc' >> "$exclude" 2>/dev/null || continue
      fi
    fi
    sources+=($plugin_files)
  done
  for src in $sources; do
    dir=${src:h}
    [[ -O $src && ! -L $src ]] || continue
    zstat -H info -- "$dir" 2>/dev/null || continue
    (( info[uid] == EUID && !(info[mode] & 8#22) )) || continue
    work=$dir/.compile-$$-$RANDOM.zwc   # matches the ignore patterns too
    zf_mkdir -m 700 -- "$work" 2>/dev/null || continue
    if zcompile -R "$work/out.zwc" "$src" 2>/dev/null &&
        zf_mv -f -- "$work/out.zwc" "$src.zwc" 2>/dev/null; then
      (( ++compiled ))
    fi
    zf_rm -rf -- "$work" 2>/dev/null
  done
  REPLY=$compiled
  return 0
}

# __leos_daily_due <name>
# Succeeds at most once a day per name, recording the run in a private stamp
# file inside the cache root. Fails (does nothing) when that root is unsafe.
__leos_daily_due() {
  emulate -L zsh
  setopt extended_glob
  local stamp=${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/init/$1
  # The common case, a stamp from today, needs no directory validation at all:
  # this check can only ever decide NOT to run the job, so whoever wrote the
  # stamp, trusting it cannot make anything run.
  [[ -z $stamp(#qN.mh-24) ]] || return 1
  __leos_cache_dir || return 1
  stamp=$REPLY/$1
  [[ ! -e $stamp && ! -L $stamp ]] || __leos_cache_safe_file "$stamp" || return 1
  [[ -z $stamp(#qN.mh-24) ]] || return 1
  __leos_stamp_write "$stamp"
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
  local tool=$1
  __leos_daily_due "$tool-rehash" || return 0
  # Detach in a subshell to keep job notifications out of interactive startup.
  # Test fixtures disable this side effect rather than racing their cleanup.
  setopt no_bgnice
  (command "$tool" rehash &) >/dev/null 2>&1
  return 0
}

# __leos_fnm_prune <multishell-dir>
# `fnm env` creates one <pid>_<millis> symlink per shell and never removes it
# (Schniz/fnm#1085), so they accumulate by the thousand. Remove links older
# than a day whose shell is gone. A live shell keeps its link however old it
# is; a reused PID only delays removal. Only symlinks with that exact name
# shape inside a directory this user owns are touched.
__leos_fnm_prune() {
  emulate -L zsh
  setopt extended_glob
  local dir=$1 link pid
  [[ -n $dir && -d $dir && ! -L $dir && -O $dir ]] || return 0
  for link in $dir/[0-9]##_[0-9]##(N@mh+24); do
    pid=${${link:t}%%_*}
    kill -0 $pid 2>/dev/null && continue
    rm -f -- "$link"
  done
  return 0
}

# __leos_fnm_prune_daily <multishell-dir>: the above, detached, once a day.
__leos_fnm_prune_daily() {
  emulate -L zsh
  __leos_daily_due fnm-prune || return 0
  setopt no_bgnice
  (__leos_fnm_prune "$1" &) >/dev/null 2>&1
  return 0
}

:
