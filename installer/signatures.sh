#!/usr/bin/env bash
# Per-component signature material, dispatched through registry.sh.
# shellcheck disable=SC2034

# artifact_signature <name>: what a locked artifact contributes to its
# component's signature: "|<version>|<url><TAB><sha256>", or "|<url>|<sha256>"
# for a versionless single file.
artifact_signature() {
  local asset url sha
  asset=$(platform_asset "$1")
  if [[ -z $(artifact_version "$1") ]]; then
    IFS=$'\t' read -r url sha <<< "$asset"
    printf '|%s|%s' "$url" "$sha"
  else
    printf '|%s|%s' "$(artifact_version "$1")" "$asset"
  fi
}

signature_bins() { artifact_signature rpatool; }

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

signature_bun() { artifact_signature bun; }

signature_uv() { artifact_signature uv; }

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
  artifact_signature fnm
  printf '|%s|%s' "$NODE_POLICY" "${RESOLVED_NODE_VERSION:-unresolved}"
}

signature_plugins() {
  printf '|%s' "$TARGET"
  artifact_signature starship
  printf '|%s|%s|%s|%s' "$ZSH_AUTOSUGGESTIONS_COMMIT" "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" "$ZSH_COMPLETIONS_COMMIT" "$FZF_TAB_COMMIT"
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
