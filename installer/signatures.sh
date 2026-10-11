#!/usr/bin/env bash
# Per-component signature material, dispatched through registry.sh.
# shellcheck disable=SC2034

# artifact_signature <name>: what an artifact contributes to its component's
# signature: where it comes from, never which version is current, so a new
# upstream release does not invalidate the recorded state.
artifact_signature() {
  local record
  artifact_row "$1"
  case $(artifact_source "$1") in
    pinned) record=$(artifact_pinned_asset "$1") ;;
    formula) record="formula|$ARTIFACT_FORMULA" ;;
    release) record="release|$(artifact_release_asset "$1" || printf unsupported)" ;;
  esac
  printf '|%s' "$record"
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
  material+="|$PYENV_REPOSITORY|default-branch"
  printf '%s' "$material"
}

signature_rbenv() {
  local material="" asset
  material+="|$RBENV_REPOSITORY|$RUBY_BUILD_REPOSITORY|default-branch"
  printf '%s' "$material"
}

signature_bun() { artifact_signature bun; }

signature_uv() { artifact_signature uv; }

# npm_tool_signature <yarn|pnpm>: its formula on macOS, the npm prefix elsewhere.
npm_tool_signature() {
  if [[ $OS_FAMILY == macos ]]; then
    printf '|formula|%s' "$1"
  else
    printf '|npm|%s@latest|%s' "$1" "$HOME/.local/npm"
  fi
}

signature_yarn() { npm_tool_signature yarn; }

signature_pnpm() { npm_tool_signature pnpm; }

signature_fnm() {
  artifact_signature fnm
  printf '|%s' "$NODE_POLICY"
}

signature_plugins() {
  printf '|%s' "$TARGET"
  artifact_signature starship
  printf '|%s|%s|%s|%s|default-branch' "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" \
    "$ZSH_COMPLETIONS_REPOSITORY" "$FZF_TAB_REPOSITORY"
}

signature_fonts() {
  local material="" asset
  material+="|$INSTALL_FONTS|${FONT_NAME:-JetBrainsMono}|$NERD_FONTS_RELEASE_URL"
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
