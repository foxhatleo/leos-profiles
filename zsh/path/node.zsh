# pnpm and Yarn are Corepack's shims in ~/.local/npm/bin (path/bin.zsh puts
# it on PATH). Yarn Classic's global bin, ~/.yarn/bin, is no longer added:
# modern Yarn has no global installs. A directory of your own can be added in
# local/private.zsh.

# bun's own global bin dir, where `bun add -g` puts binaries. __leos_add_path no-ops
# when it does not exist, so this costs nothing until bun installs something.
__leos_add_path "$HOME/.bun/bin"

# Node package-manager completions.
#
# npm ships `npm completion` and pnpm ships `pnpm completion zsh`; both print a
# Zsh completion script on stdout. Yarn has no generator (modern Yarn still
# does not), so yarn keeps using the `_yarn` completion bundled with
# zsh-completions.
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
  # generator, so yarn keeps the `_yarn` bundled with zsh-completions.
  local status_
  for tool in npm pnpm bun; do
    whence -p $tool >/dev/null || continue
    status_=0
    case $tool in
      npm)  leos-source-cached npm-completion  $commands[npm]  completion     || status_=$? ;;
      pnpm) leos-source-cached pnpm-completion $commands[pnpm] completion zsh || status_=$? ;;
      # Bun chooses its output dialect from SHELL, not the actual interpreter.
      # A Zsh launched from Bash/Fish must still receive Zsh code. Bump the key
      # so an older wrong-dialect cache is never reused.
      bun)  SHELL=zsh leos-source-cached bun-completion-zsh $commands[bun] completions || status_=$? ;;
    esac
    # Only status 1 is a fresh failure; 2 means it was already reported on an
    # earlier shell, and repeating it every startup would just be noise.
    (( status_ == 1 )) &&
      __leos_puts_err "$tool did not produce a Zsh completion script; skipping its completions. Run leos-refresh-init-cache to retry."
  done
  return 0
}

:
