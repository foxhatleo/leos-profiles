# uv and uvx completions — loaded from interactive.zsh, AFTER compinit: each
# generated script ends in `compdef _uv uv` (or `_uvx uvx`) when it is not
# itself the autoloaded completion function, so loading it during the PATH
# phase would silently register nothing.
#
# The installer puts both on PATH as one artifact (Homebrew's uv formula on
# macOS, the latest release in ~/.local/bin on Linux). Their
# generators only change with the binary, so the output is cached like the
# other tools' (see leos-source-cached in cache.zsh).
if whence -p uv >/dev/null; then
  leos-source-cached-warn "uv did not produce a Zsh completion script; skipping its completions. Run leos-refresh-init-cache to retry." \
    uv-completion $commands[uv] generate-shell-completion zsh
fi
if whence -p uvx >/dev/null; then
  leos-source-cached-warn "uvx did not produce a Zsh completion script; skipping its completions. Run leos-refresh-init-cache to retry." \
    uvx-completion $commands[uvx] --generate-shell-completion zsh
fi

:
