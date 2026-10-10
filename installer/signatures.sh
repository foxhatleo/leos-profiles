#!/usr/bin/env bash
# Per-component signature material, dispatched through registry.sh.
# shellcheck disable=SC2034

signature_bins() {
  local material="" asset
  material+="|$RPATOOL_URL|$RPATOOL_SHA256"
  printf '%s' "$material"
}

# join_lines <items...>: the items separated by newlines, with no trailing
# newline. Explicit, so a signature never depends on the caller's IFS, and
# byte-identical to the signatures recorded while the installer ran with
# IFS=$'\n\t' (whose "${array[*]}" joined with a newline).
join_lines() {
  (( $# )) || return 0
  printf '%s' "$1"
  shift
  (( $# )) || return 0
  printf '\n%s' "$@"
}

signature_packages() {
  collect_selected_packages
  printf '|%s|' "$SELECTED_GROUPS"
  # An empty selection (--package-groups none) must not trip `set -u` under
  # Bash 3.2, which treats an empty array as unset (ONB-14).
  join_lines ${SELECTED_PACKAGES[@]+"${SELECTED_PACKAGES[@]}"}
}

signature_pyenv() {
  local material="" asset
  material+="|$PYENV_REPOSITORY|$PYENV_COMMIT"
  printf '%s' "$material"
}

signature_rbenv() {
  local material="" asset
  material+="|$RBENV_REPOSITORY|$RBENV_COMMIT|$RUBY_BUILD_REPOSITORY|$RUBY_BUILD_COMMIT"
  printf '%s' "$material"
}

signature_bun() {
  local material="" asset
  asset=$(platform_asset bun)
  material+="|$BUN_VERSION|$asset"
  printf '%s' "$material"
}

signature_yarn() {
  local material="" asset
  material+="|$YARN_VERSION|$YARN_URL|$YARN_SHA256|$HOME/.local/npm|$NODE_POLICY|${RESOLVED_NODE_VERSION:-unresolved}"
  printf '%s' "$material"
}

signature_pnpm() {
  local material="" asset
  material+="|$PNPM_VERSION|$PNPM_URL|$PNPM_SHA256|$HOME/.local/npm|$NODE_POLICY|${RESOLVED_NODE_VERSION:-unresolved}"
  printf '%s' "$material"
}

signature_fnm() {
  local material="" asset
  asset=$(platform_asset fnm)
  material+="|$FNM_VERSION|$asset|$NODE_POLICY|${RESOLVED_NODE_VERSION:-unresolved}"
  printf '%s' "$material"
}

signature_plugins() {
  local material="" asset
  asset=$(platform_asset starship)
  material+="|$TARGET|$STARSHIP_VERSION|$asset|$ZSH_AUTOSUGGESTIONS_COMMIT|$ZSH_SYNTAX_HIGHLIGHTING_COMMIT|$ZSH_COMPLETIONS_COMMIT|$FZF_TAB_COMMIT"
  printf '%s' "$material"
}

signature_fonts() {
  local material="" asset
  material+="|$INSTALL_FONTS|${FONT_NAME:-JetBrainsMono}|$NERD_FONTS_COMMIT"
  printf '%s' "$material"
}

signature_zsh_config() {
  local material="" asset
  resolve_zsh_dotdirs
  material+="|loader-v3|$TARGET|$OS_FAMILY|$ZSH_RC_DIR|$ZSH_ENV_DIR"
  printf '%s' "$material"
}

signature_default_shell() {
  local material="" asset
  material+="|$CHANGE_DEFAULT_SHELL"
  printf '%s' "$material"
}
