#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

# git_checkout_follows <directory> <repository>: a clean checkout of the
# repository on a branch. A detached HEAD is a checkout from the pinned
# installs before 2026-10, which follow_default_branch moves onto the branch.
git_checkout_follows() {
  local directory=$1 repository=$2 origin
  [[ -d $directory/.git ]] || return 1
  origin=$(git -C "$directory" remote get-url origin 2>/dev/null || true)
  github_origins_equivalent "$origin" "$repository" || return 1
  [[ -z $(git -C "$directory" status --porcelain) ]] || return 1
  git -C "$directory" symbolic-ref --quiet HEAD >/dev/null 2>&1
}

# The family name a Nerd Font installs under. Nerd Fonts renames families
# whose upstream names are reserved; these aliases match the filenames in the
# Nerd Fonts releases.
nerd_font_family() {
  local font=${FONT_NAME:-JetBrainsMono} installed_family
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
  printf '%s\n' "$installed_family"
}

font_is_installed() {
  local directory installed_family
  if [[ $OS_FAMILY == macos ]]; then
    directory="$HOME/Library/Fonts"
  else
    directory="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
  fi
  [[ -d $directory ]] || return 1
  # Keep the check family-specific: another installed Nerd Font must not
  # satisfy the requested family's postcondition.
  installed_family=$(nerd_font_family)
  find "$directory" -type f -iname "*${installed_family}*NerdFont*" -print -quit | grep -q .
}

verify_bins() { artifact_verify rpatool; }

verify_packages() {
  local directory
  selected_packages_installed && apt_compat_links_valid
}

verify_pyenv() {
  local directory
  [[ -x $HOME/.pyenv/bin/pyenv ]] && git_checkout_follows "$HOME/.pyenv" "$PYENV_REPOSITORY"
}

verify_rbenv() {
  local directory
  [[ -x $HOME/.rbenv/bin/rbenv ]] &&
    git_checkout_follows "$HOME/.rbenv" "$RBENV_REPOSITORY" &&
    git_checkout_follows "$HOME/.rbenv/plugins/ruby-build" "$RUBY_BUILD_REPOSITORY"
}

verify_bun() { artifact_verify bun; }

verify_uv() { artifact_verify uv; }

verify_yarn() { npm_tool_verify yarn; }

verify_pnpm() { npm_tool_verify pnpm; }

# fnm with a working default Node. Which version that is, is not checked: a
# full upgrade moves it to the current LTS, and a repair leaves it alone.
verify_fnm() {
  artifact_verify fnm && fnm_default_node >/dev/null
}

verify_plugins() {
  local directory="$TARGET/zsh/plugins"
  artifact_verify starship &&
    git_checkout_follows "$directory/zsh-autosuggestions" "$ZSH_AUTOSUGGESTIONS_REPOSITORY" &&
    git_checkout_follows "$directory/zsh-syntax-highlighting" "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" &&
    git_checkout_follows "$directory/zsh-completions" "$ZSH_COMPLETIONS_REPOSITORY" &&
    git_checkout_follows "$directory/fzf-tab" "$FZF_TAB_REPOSITORY"
}

verify_fonts() {
  local directory
  ! font_should_install || font_is_installed
}

verify_zsh_config() {
  local directory
  resolve_zsh_dotdirs
  managed_block_equals "$ZSH_RC_DIR/.zshrc" loader "$(zshrc_managed_content)" &&
    managed_block_equals "$ZSH_ENV_DIR/.zshenv" environment "$(zshenv_managed_content)" &&
    { [[ $OS_FAMILY != macos ]] ||
      managed_block_equals "$ZSH_RC_DIR/.zprofile" login-path "$(zprofile_managed_content)"; } &&
    ! legacy_loader_present "$ZSH_RC_DIR/.zshrc" loader &&
    ! legacy_loader_present "$ZSH_ENV_DIR/.zshenv" environment
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
    [[ $(current_login_shell) == "$(preferred_zsh_path)" ]]
  fi
}
