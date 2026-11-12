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

# Git sources record `release` (since 2026-11; `default-branch` before, so
# existing checkouts re-run once and move to their release). Never the
# minimum release age or the tag: a new upstream release must not make a step
# look undone.
signature_rbenv() {
  local material="" asset
  # ruby-latest-stable since schema 4 (2026-11): the step now also compiles
  # the newest stable Ruby, so rbenv steps recorded before re-run once.
  material+="|$RBENV_REPOSITORY|$RUBY_BUILD_REPOSITORY|release|ruby-latest-stable"
  printf '%s' "$material"
}

signature_bun() { artifact_signature bun; }

signature_uv() { artifact_signature uv; }

# Corepack: the npm package and prefix, and the package managers it installs
# outside projects (their versions are not part of it).
signature_corepack() {
  printf '|npm|corepack@latest|%s|%s' "$(corepack_prefix)" "$COREPACK_DEFAULTS"
}

# uv's CPython, as python3 in ~/.local/bin; the line it picks is not part of it.
signature_cpython() {
  printf '|uv-python|latest-stable|%s' "$HOME/.local/bin"
}

signature_starship() { artifact_signature starship; }

signature_fnm() {
  artifact_signature fnm
  printf '|%s' "$NODE_POLICY"
}

# Starship was part of plugins until schema 4 (now its own component), so
# plugins steps recorded before re-run once.
signature_plugins() {
  printf '|%s' "$TARGET"
  printf '|%s|%s|%s|%s|release' "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" \
    "$ZSH_COMPLETIONS_REPOSITORY" "$FZF_TAB_REPOSITORY"
}

# The URL text is the old "latest release" one on purpose: the run downloads
# from the tag it picks, but recording that tag (or a new URL) would make
# every existing install look undone.
signature_fonts() {
  local material="" asset
  material+="|$INSTALL_FONTS|${FONT_NAME:-JetBrainsMono}|$NERD_FONTS_SIGNATURE_URL"
  printf '%s' "$material"
}

signature_zsh_config() {
  local material="" asset
  resolve_zsh_dotdirs
  material+="|loader-v5|$TARGET|$OS_FAMILY|$ZSH_RC_DIR|$ZSH_ENV_DIR"
  printf '%s' "$material"
}

signature_default_shell() {
  local material="" asset
  material+="|$CHANGE_DEFAULT_SHELL"
  printf '%s' "$material"
}
