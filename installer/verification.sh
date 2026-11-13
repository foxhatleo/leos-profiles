#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

# git_checkout_at_release <directory> <repository>: a clean checkout of the
# repository, detached (follow_release_checkout leaves it at a release). One
# on a branch is the default-branch layout of 2026-10, which the step moves to
# its release. Which release it is, is not checked: a newer upstream release
# alone does not make the step look undone; a full upgrade moves it forward.
git_checkout_at_release() {
  local directory=$1 repository=$2 origin
  [[ -d $directory/.git ]] || return 1
  origin=$(git -C "$directory" remote get-url origin 2>/dev/null || true)
  github_origins_equivalent "$origin" "$repository" || return 1
  [[ -z $(git -C "$directory" status --porcelain) ]] || return 1
  git -C "$directory" rev-parse --verify --quiet HEAD >/dev/null || return 1
  ! git -C "$directory" symbolic-ref --quiet HEAD >/dev/null 2>&1
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

# rbenv and ruby-build at their releases, and rbenv's global Ruby running,
# unless the last compile failed (install_ruby): a full upgrade retries that.
verify_rbenv() {
  local directory
  [[ -x $HOME/.rbenv/bin/rbenv ]] &&
    git_checkout_at_release "$HOME/.rbenv" "$RBENV_REPOSITORY" &&
    git_checkout_at_release "$HOME/.rbenv/plugins/ruby-build" "$RUBY_BUILD_REPOSITORY" &&
    { ruby_global_version >/dev/null || ruby_compile_failed; }
}

verify_bun() { artifact_verify bun; }

verify_uv() { artifact_verify uv; }

verify_starship() { artifact_verify starship; }

# verify_corepack: Corepack, and its pnpm and Yarn shims answering --version
# on fnm's default Node from what is already downloaded (no network: inspect
# runs this too).
verify_corepack() {
  local prefix tool
  prefix=$(corepack_prefix)
  [[ -x $prefix/bin/corepack ]] || return 1
  for tool in $COREPACK_TOOLS; do
    [[ -x $prefix/bin/$tool && $(readlink "$prefix/bin/$tool" 2>/dev/null || true) == *corepack* ]] || return 1
    corepack_tool_version "$tool" COREPACK_ENABLE_NETWORK=0 >/dev/null || return 1
  done
}

# verify_cpython: ~/.local/bin/python3 is uv's: it resolves into `uv python
# dir` and runs. Which version is not checked; a full upgrade moves it.
verify_cpython() {
  local uv directory resolved
  uv=$(artifact_path uv)
  [[ -x $uv && -x $HOME/.local/bin/python3 ]] || return 1
  directory=$("$uv" python dir 2>/dev/null) || return 1
  [[ -n $directory ]] || return 1
  resolved=$(resolve_config_path "$HOME/.local/bin/python3") || return 1
  [[ $resolved == "${directory%/}"/* ]] || return 1
  python_default_version >/dev/null
}

# fnm with a working default Node. Which version that is, is not checked: a
# full upgrade moves it to the current LTS, and a repair leaves it alone.
verify_fnm() {
  artifact_verify fnm && fnm_default_node >/dev/null
}

verify_plugins() {
  local directory="$TARGET/zsh/plugins"
  git_checkout_at_release "$directory/zsh-autosuggestions" "$ZSH_AUTOSUGGESTIONS_REPOSITORY" &&
    git_checkout_at_release "$directory/zsh-syntax-highlighting" "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" &&
    git_checkout_at_release "$directory/zsh-completions" "$ZSH_COMPLETIONS_REPOSITORY" &&
    git_checkout_at_release "$directory/fzf-tab" "$FZF_TAB_REPOSITORY"
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
