#!/usr/bin/env bash
# Per-component signature material, dispatched through registry.sh.
# shellcheck disable=SC2034

signature_bins() {
  local material="" asset
  material+="|$RPATOOL_URL|$RPATOOL_SHA256"
  printf '%s' "$material"
}

signature_packages() {
  local material="" asset
  collect_selected_packages
  material+="|$SELECTED_GROUPS|${SELECTED_PACKAGES[*]}"
  printf '%s' "$material"
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
  material+="|loader-v2|$TARGET"
  printf '%s' "$material"
}

signature_default_shell() {
  local material="" asset
  material+="|$CHANGE_DEFAULT_SHELL"
  printf '%s' "$material"
}
