#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

git_checkout_at() {
  local directory=$1 repository=$2 commit=$3 origin
  [[ -d $directory/.git ]] || return 1
  origin=$(git -C "$directory" remote get-url origin 2>/dev/null || true)
  github_origins_equivalent "$origin" "$repository" || return 1
  [[ -z $(git -C "$directory" status --porcelain) ]] || return 1
  [[ $(git -C "$directory" rev-parse HEAD 2>/dev/null || true) == "$commit" ]]
}

font_is_installed() {
  local font=${FONT_NAME:-JetBrainsMono} installed_family directory
  if [[ $OS_FAMILY == macos ]]; then
    directory="$HOME/Library/Fonts"
  else
    directory="$HOME/.local/share/fonts"
  fi
  [[ -d $directory ]] || return 1
  # Nerd Fonts renames families whose upstream names are reserved. These
  # aliases match the filenames in the pinned nerd-fonts commit. Keep the
  # check family-specific: another installed Nerd Font must not satisfy the
  # requested family's postcondition.
  case $font in
    AnonymousPro) installed_family=AnonymicePro ;;
    AurulentSansMono) installed_family=AurulentSansM ;;
    BigBlueTerminal) installed_family=BigBlueTerm ;;
    BitstreamVeraSansMono) installed_family=BitstromWera ;;
    CascadiaCode) installed_family=CaskaydiaCove ;;
    DejaVuSansMono) installed_family=DejaVuSansM ;;
    DroidSansMono) installed_family=DroidSansM ;;
    FantasqueSansMono) installed_family=FantasqueSansM ;;
    Go-Mono) installed_family=GoMono ;;
    Hasklig) installed_family=Hasklug ;;
    Hermit) installed_family=Hurmit ;;
    IBMPlexMono) installed_family=BlexMono ;;
    LiberationMono) installed_family=LiterationMono ;;
    MPlus) installed_family='M+' ;;
    NerdFontsSymbolsOnly) installed_family=Symbols ;;
    ShareTechMono) installed_family=ShureTechMono ;;
    SourceCodePro) installed_family=SauceCodePro ;;
    Terminus) installed_family=Terminess ;;
    iA-Writer) installed_family=iMWriting ;;
    *) installed_family=$font ;;
  esac
  find "$directory" -type f -iname "*${installed_family}*NerdFont*" -print -quit | grep -q .
}

verify_bins() {
  local directory
  [[ -x $HOME/.local/bin/rpatool ]] && [[ $(sha256 "$HOME/.local/bin/rpatool") == "$RPATOOL_SHA256" ]]
}

verify_packages() {
  local directory
  selected_packages_installed && apt_compat_links_valid
}

verify_pyenv() {
  local directory
  [[ -x $HOME/.pyenv/bin/pyenv ]] && git_checkout_at "$HOME/.pyenv" "$PYENV_REPOSITORY" "$PYENV_COMMIT"
}

verify_rbenv() {
  local directory
  [[ -x $HOME/.rbenv/bin/rbenv ]] &&
    git_checkout_at "$HOME/.rbenv" "$RBENV_REPOSITORY" "$RBENV_COMMIT" &&
    git_checkout_at "$HOME/.rbenv/plugins/ruby-build" "$RUBY_BUILD_REPOSITORY" "$RUBY_BUILD_COMMIT"
}

verify_bun() {
  local directory
  [[ -x $HOME/.local/bin/bun ]] && "$HOME/.local/bin/bun" --version 2>/dev/null | grep -qx "$BUN_VERSION"
}

verify_yarn() {
  local directory
  [[ -x $HOME/.local/npm/bin/yarn ]] && fnm_exec "$HOME/.local/npm/bin/yarn" --version 2>/dev/null | grep -qx "$YARN_VERSION"
}

verify_pnpm() {
  local directory
  [[ -x $HOME/.local/npm/bin/pnpm ]] && fnm_exec "$HOME/.local/npm/bin/pnpm" --version 2>/dev/null | grep -qx "$PNPM_VERSION"
}

verify_fnm() {
  local directory
  [[ -n $RESOLVED_NODE_VERSION ]] || resolve_node_version || return 1
  node_version_compatible "$RESOLVED_NODE_VERSION" || return 1
  [[ -x $HOME/.local/bin/fnm ]] &&
    "$HOME/.local/bin/fnm" --version 2>/dev/null | grep -qx "fnm $FNM_VERSION" &&
    [[ $("$HOME/.local/bin/fnm" default 2>/dev/null) == "$RESOLVED_NODE_VERSION" ]] &&
    [[ $("$HOME/.local/bin/fnm" exec --using="$RESOLVED_NODE_VERSION" -- node --version 2>/dev/null) == "$RESOLVED_NODE_VERSION" ]]
}

verify_plugins() {
  local directory
  [[ -x $HOME/.local/bin/starship ]] &&
    "$HOME/.local/bin/starship" --version 2>/dev/null | sed -n '1p' | grep -qx "starship $STARSHIP_VERSION" &&
    directory="$TARGET/zsh/plugins" &&
    git_checkout_at "$directory/zsh-autosuggestions" "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$ZSH_AUTOSUGGESTIONS_COMMIT" &&
    git_checkout_at "$directory/zsh-syntax-highlighting" "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" &&
    git_checkout_at "$directory/zsh-completions" "$ZSH_COMPLETIONS_REPOSITORY" "$ZSH_COMPLETIONS_COMMIT" &&
    git_checkout_at "$directory/fzf-tab" "$FZF_TAB_REPOSITORY" "$FZF_TAB_COMMIT"
}

verify_fonts() {
  local directory
  ! font_should_install || font_is_installed
}

verify_zsh_config() {
  local directory
  managed_block_equals "$HOME/.zshrc" loader "$(zshrc_managed_content)" &&
    managed_block_equals "$HOME/.zshenv" environment "$(zshenv_managed_content)"
}

verify_default_shell() {
  local directory
  if [[ $CHANGE_DEFAULT_SHELL == no ]]; then
    return 0
  elif [[ $CHANGE_DEFAULT_SHELL == auto ]]; then
    local current_shell
    current_shell=$(current_login_shell)
    [[ ${current_shell##*/} == zsh ]]
  else
    [[ $(current_login_shell) == "$(command -v zsh)" ]]
  fi
}
