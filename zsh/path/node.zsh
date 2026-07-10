# Yarn global bin (best-effort: Yarn Berry has no `yarn global`, so guard the lookup)
if command -v yarn >/dev/null 2>&1 && __yarn_bin=$(yarn global bin 2>/dev/null) && [[ -n $__yarn_bin ]]; then
  add-path "$__yarn_bin"
fi
unset __yarn_bin

:
