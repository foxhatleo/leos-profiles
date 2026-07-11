#!/usr/bin/env bash
# Clone the actual locked plugin commits and source the combined Zsh stack.
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

TARGET="$TEMP_ROOT/profile"
HOME="$TEMP_ROOT/home"
DRY_RUN=0
mkdir -p "$TARGET" "$HOME"
cp -R "$ROOT/zsh" "$TARGET/zsh"

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
