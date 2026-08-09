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
# interactive shell, so their output is cached on disk by start.zsh's shared
# init cache and regenerated only when the tool itself changes.
#
# Defined here but called from interactive.zsh: `compdef` only exists after
# compinit, and PATH is not complete until every path/ entry has run.
leos-node-completions() {
  # No `emulate -L zsh`: these scripts call `compdef` and may set options, and
  # localizing those would defeat the point. See leos-source-cached.
  (( $+functions[compdef] )) || return 0

  local tool
  # bun ships a full compsys script on stdout, like npm and pnpm. Yarn has no
  # generator in either line — Classic 1.x never had one and Berry 4.x still
  # does not — so yarn keeps the `_yarn` bundled with zsh-completions.
  for tool in npm pnpm bun; do
    (( $+commands[$tool] )) || continue
    case $tool in
      npm)  leos-source-cached npm-completion  $commands[npm]  completion ;;
      pnpm) leos-source-cached pnpm-completion $commands[pnpm] completion zsh ;;
      bun)  leos-source-cached bun-completion  $commands[bun]  completions ;;
    esac || puts-err "$tool did not produce a Zsh completion script; skipping its completions."
  done
  return 0
}

:
