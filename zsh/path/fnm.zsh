# fnm — fast Node version manager with per-directory auto-switch
[[ -d $HOME/.local/share/fnm ]] && add-path "$HOME/.local/share/fnm"
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)"
fi
