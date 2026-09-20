#!/usr/bin/env bash
# Clone the actual locked plugin commits and source the combined Zsh stack.
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail
IFS=$'\n\t'

if [[ ${LEOS_PLUGIN_TEST_ISOLATED:-} != 1 ]]; then
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LEOS_PLUGIN_TEST_ISOLATED=1 bash "$0"
fi
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM
export HOME="$TEMP_ROOT/home" XDG_CACHE_HOME="$TEMP_ROOT/cache"
export XDG_DATA_HOME="$TEMP_ROOT/data" XDG_CONFIG_HOME="$TEMP_ROOT/config"
export GIT_TERMINAL_PROMPT=0
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

TARGET="$TEMP_ROOT/profile"
DRY_RUN=0
mkdir -p "$TARGET/zsh" "$HOME" "$TEMP_ROOT/bin"
cp "$ROOT"/zsh/*.zsh "$ROOT"/zsh/*.toml "$TARGET/zsh/"
cp -R "$ROOT/zsh/path" "$TARGET/zsh/path"
printf '\n__leos_rehash_daily() { :; }\n' >> "$TARGET/zsh/cache.zsh"
# Exercise real locked plugin code, without invoking host initialization tools
# or falling back to an absolute Homebrew installation outside the fixture.
for tool in brew starship pyenv rbenv fnm npm pnpm bun direnv zoxide heroku thefuck; do
  printf '%s\n' '#!/bin/sh' 'printf ":\n"' > "$TEMP_ROOT/bin/$tool"
  chmod +x "$TEMP_ROOT/bin/$tool"
done
export PATH="$TEMP_ROOT/bin:$PATH"

install_plugins

for plugin in zsh-autosuggestions zsh-syntax-highlighting zsh-completions fzf-tab; do
  [[ -d $TARGET/zsh/plugins/$plugin/.git ]]
  [[ -z $(git -C "$TARGET/zsh/plugins/$plugin" status --porcelain) ]]
done

HOME="$HOME" LEOS_PROFILES_HOME="$TARGET" TERM=xterm-256color zsh -dfc '
  setopt err_return pipe_fail
  starship() { [[ $1 == init ]] && print -r -- ":"; }
  source "$LEOS_PROFILES_HOME/zsh/start.zsh"
  (( $+functions[_zsh_highlight] ))
  (( $+functions[_zsh_autosuggest_start] ))
  (( $+functions[compdef] ))
'

printf '%s\n' 'locked plugin integration: PASS'
