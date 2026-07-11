# fnm — fast Node version manager with per-directory auto-switch
add-path "$HOME/.local/bin"
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)"
fi

:
