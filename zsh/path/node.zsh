# Yarn (Classic) global bin. Add the default location from disk instead of
# running `yarn global bin`, which spawns a Node process on every interactive
# shell (and Yarn Berry has no global bin at all). A non-default global prefix
# can be added in local/private.zsh.
add-path "$HOME/.yarn/bin"

# Node package-manager completions.
#
# npm ships `npm completion` and pnpm ships `pnpm completion zsh`; both print a
# Zsh completion script on stdout. Yarn has no generator in either line —
# Classic 1.x never had one and Berry 4.x still does not — so yarn keeps using
# the `_yarn` completion bundled with zsh-completions.
#
# Each generator spawns a Node process, far too slow to run on every
# interactive shell, so their output is cached on disk and regenerated only
# when the tool itself changes. The cache is keyed by the resolved binary path
# so fnm's per-shell shim directory does not invalidate it, while an actual
# Node version switch gets its own entry.
#
# Defined here but called from interactive.zsh: `compdef` only exists after
# compinit, and PATH is not complete until every path/ entry has run.
leos-node-completions() {
  emulate -L zsh
  (( $+functions[compdef] )) || return 0

  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/leos-profiles/completions
  local tool bin real cache generated

  for tool in npm pnpm; do
    bin=$(command -v $tool 2>/dev/null) || continue
    real=${bin:A}
    # One cache file per resolved binary; ':A' output is path-safe once its
    # separators are flattened.
    cache=$dir/$tool${real//[^A-Za-z0-9]/_}.zsh

    if [[ ! -s $cache || $real -nt $cache ]]; then
      mkdir -p $dir 2>/dev/null || return 0
      case $tool in
        npm)  generated=$("$bin" completion 2>/dev/null) ;;
        pnpm) generated=$("$bin" completion zsh 2>/dev/null) ;;
      esac
      if [[ -z $generated ]]; then
        puts-err "$tool did not produce a Zsh completion script; skipping its completions."
        # Cache the failure too, so the next shell does not pay for another
        # Node process until the binary itself changes.
        generated="# $tool completion generation failed"
      fi
      print -r -- "$generated" > $cache.$$ 2>/dev/null &&
        mv -f $cache.$$ $cache 2>/dev/null || { rm -f $cache.$$; continue }
    fi

    source $cache
  done
  return 0
}

:
