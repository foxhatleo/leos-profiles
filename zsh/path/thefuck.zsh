# thefuck — lazy: `thefuck --alias` spawns Python (~200-400ms), so defer it until first use.
# The wrapper replaces itself with the real alias on the first `fuck` invocation.
if command -v thefuck >/dev/null 2>&1; then
  fuck() { unfunction fuck; eval "$(thefuck --alias)"; fuck "$@"; }
fi
