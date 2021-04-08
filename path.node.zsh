# https://github.com/sindresorhus/guides/blob/main/npm-global-without-sudo.md

NPM_PACKAGES="${HOME}/.npm-packages"

export PATH="$NPM_PACKAGES/bin:$PATH"

# Preserve MANPATH if you already defined it somewhere in your config.
# Otherwise, fall back to `manpath` so we can inherit from `/etc/manpath`.
export MANPATH="$NPM_PACKAGES/share/man:${MANPATH-$(manpath)}"
