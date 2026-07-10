# thefuck — lazy: `thefuck --alias` spawns Python (~200-400ms), so defer it until first use.
# The wrapper replaces itself with the real alias on the first `fuck` invocation.
if command -v thefuck >/dev/null 2>&1; then
  fuck() {
    unfunction fuck
    eval "$(thefuck --alias)"
    # Aliases are expanded while a function is parsed, so re-evaluate the
    # invocation after installing the real alias; a direct `fuck "$@"` here
    # makes the first call fail with command not found.
    eval "fuck ${(j: :)${(q)@}}"
  }
fi
