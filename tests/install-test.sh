#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317,SC2329

set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# The zsh-config tests resolve startup files from ZDOTDIR; never let the
# developer's own value point them outside the fixture HOME.
unset ZDOTDIR
# shellcheck source=../install.sh
source "$ROOT/install.sh"

CURRENT_TEST=""
fail() { printf '%s\n' "FAIL [${CURRENT_TEST:-?}]: $*" >&2; exit 1; }
assert_equals() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "expected '$1' to contain '$2'"; }

# A copy of the public checkout, so CLI tests never read or write the
# developer's local/ state.
make_fixture_checkout() {
  mkdir -p "$1"
  cp -R "$ROOT/install.sh" "$ROOT/installer" "$ROOT/zsh" "$ROOT/util" "$1/"
  rm -rf -- "$1/zsh/plugins" "$1/zsh/_private.zsh"
}

# run_cli <checkout> <home> <args...>: the real entrypoint, with this suite's
# interpreter (the system Bash 3.2 on macOS CI) and a fixture HOME.
run_cli() {
  local checkout=$1 home=$2
  shift 2
  mkdir -p "$home"
  env LEOS_PROFILES_INSTALL_LIB_ONLY=0 HOME="$home" XDG_STATE_HOME="$home/.local/state" \
    XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" XDG_DATA_HOME="$home/.local/share" \
    "$BASH" "$checkout/install.sh" "$@"
}

test_dependency_normalisation() {
  SELECTED_STEPS="zsh-config"
  SELECTED_GROUPS="core-utils"
  normalise_dependencies
  order_selected_steps
  assert_equals "$SELECTED_STEPS" "packages,zsh-config"
  assert_contains "$SELECTED_GROUPS" "shell"
}

test_package_group_selection_is_whole_and_executable() {
  SELECTED_STEPS=""
  SELECTED_GROUPS=media
  normalise_dependencies
  assert_equals "$SELECTED_STEPS" packages
  SELECTED_STEPS=""
  SELECTED_GROUPS=""
  validate_options
}

test_default_does_not_include_unreleased_local_bin() {
  [[ $SELECTED_STEPS != *bins* ]] || fail "rpatool bins step must be opt-in"
}

test_option_validation_rejects_bad_csv_and_implicit_keys() {
  SELECTED_STEPS='packages,,plugins'
  if (validate_options) >/dev/null 2>&1; then
    fail "CSV with an empty item was accepted"
  fi
  SELECTED_STEPS=packages
  GPG_MODE=reuse
  GPG_KEY_ID=""
  if (validate_options) >/dev/null 2>&1; then
    fail "GPG reuse without an explicit fingerprint was accepted"
  fi
}

test_state_is_input_specific() {
  local temp first_signature
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  DRY_RUN=0
  mark_done packages
  state_done packages || fail "state was not recorded"
  first_signature=$(awk -F '\t' '$1 == "packages" { print $2 }' "$STATE_FILE")
  [[ $first_signature =~ ^[0-9a-f]{64}$ ]] || fail "state did not record an input signature"
  SELECTED_GROUPS=shell
  ! state_done packages || fail "state leaked across different package selections"
  rm -rf "$temp"
}

test_recorded_state_must_pass_verification() {
  local temp installed=0
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  OS_FAMILY=macos
  DRY_RUN=0
  step_signature() { printf '%064d\n' 1; }
  install_local_bins() { installed=1; }
  verify_step() { (( installed == 1 )); }
  mark_done bins
  run_step bins
  assert_equals "$installed" "1"
  rm -rf "$temp"
}

test_managed_blocks_are_safe_and_reversible() {
  local temp file first second count mode target link malformed before_repeat
  temp=$(mktemp -d)
  file="$temp/.zshrc"
  first=$'echo user\n# >>> leos-profiles loader >>>\necho stale\n# <<< leos-profiles loader <<<\n'
  printf '%s' "$first" > "$file"
  chmod 600 "$file"
  install_managed_block "$file" loader 'echo current'
  second=$(< "$file")
  assert_contains "$second" "echo user"
  assert_contains "$second" "echo current"
  [[ $second != *"echo stale"* ]] || fail "stale managed content remains"
  count=$(grep -c '^# >>> leos-profiles loader >>>$' "$file")
  assert_equals "$count" "1"
  before_repeat=$(sha256 "$file")
  install_managed_block "$file" loader 'echo current'
  assert_equals "$(sha256 "$file")" "$before_repeat"
  assert_equals "$(< "$file.leos-profiles.bak")" "${first%$'\n'}"
  if [[ $(uname -s) == Darwin ]]; then
    mode=$(/usr/bin/stat -f '%Lp' "$file")
  else
    mode=$(stat -c '%a' "$file")
  fi
  assert_equals "$mode" "600"

  target="$temp/real-zshenv"
  link="$temp/.zshenv"
  printf '%s\n' 'echo original' > "$target"
  ln -s "$(basename -- "$target")" "$link"
  install_managed_block "$link" environment 'echo managed'
  [[ -L $link ]] || fail "managed-block update replaced a symbolic link"
  assert_contains "$(< "$target")" "echo managed"

  malformed="$temp/malformed"
  printf '%s\n' '# <<< leos-profiles loader <<<' '# >>> leos-profiles loader >>>' > "$malformed"
  if (install_managed_block "$malformed" loader 'echo unsafe') >/dev/null 2>&1; then
    fail "reversed managed markers were accepted"
  fi
  rm -rf "$temp"
}

test_zsh_config_preserves_runtime_expansions() {
  local temp saved_home saved_target
  temp=$(mktemp -d)
  saved_home=$HOME
  saved_target=$TARGET
  HOME="$temp/home"
  TARGET="$temp/profile with spaces"
  INSTALL_FONTS=no
  mkdir -p "$HOME"
  install_zsh_config
  assert_contains "$(< "$HOME/.zshenv")" "path=(\"\$HOME/.local/bin\" \"\$HOME/.local/npm/bin\" \$path)"
  [[ $(< "$HOME/.zshenv") != *LEOS_PROFILES_HOME* ]] || fail ".zshenv globally overrides the relocatable profile root"
  assert_contains "$(< "$HOME/.zshrc")" 'LEOS_PROFILES_HOME='"$temp/profile\\ with\\ spaces"
  assert_contains "$(< "$HOME/.zshrc")" 'source "$LEOS_PROFILES_HOME/zsh/start.zsh"'
  HOME=$saved_home
  TARGET=$saved_target
  rm -rf "$temp"
}

test_tar_archive_install_creates_extraction_directory() {
  local temp
  temp=$(mktemp -d)
  mkdir -p "$temp/source" "$temp/home"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$temp/source/starship"
  chmod 755 "$temp/source/starship"
  TEST_ARCHIVE="$temp/starship.tar.gz"
  tar -czf "$TEST_ARCHIVE" -C "$temp/source" starship
  HOME="$temp/home"
  DRY_RUN=0
  platform_asset() { printf '%s\t%s\n' 'https://example.invalid/starship.tar.gz' deadbeef; }
  download_verified() { mkdir -p "$(dirname -- "$3")"; cp "$TEST_ARCHIVE" "$3"; }
  install_locked_archive_binary starship tar.gz "$HOME/.local/bin/starship"
  [[ -x $HOME/.local/bin/starship ]] || fail "tar archive binary was not installed"
  rm -rf "$temp"
}

test_platform_assets_are_locked() {
  OS_FAMILY=macos
  local asset expected
  asset=$(platform_asset bun)
  assert_contains "$asset" "bun-darwin"
  if [[ $(machine_arch) == aarch64 ]]; then
    expected=$BUN_DARWIN_AARCH64_SHA256
  else
    expected=$BUN_DARWIN_X64_SHA256
  fi
  assert_contains "$asset" "$expected"
}

test_package_maps_cover_every_supported_os() {
  local family group packages
  for family in macos apt fedora arch; do
    OS_FAMILY=$family
    for group in core-utils shell dev-tools languages python media network system; do
      packages=$(package_list_for_group "$group")
      [[ -n $packages ]] || fail "missing package mapping for $family/$group"
    done
    if [[ $family == macos ]]; then
      assert_equals "$(package_list_for_group heroku)" heroku
    else
      assert_equals "$(package_list_for_group heroku)" ""
    fi
  done
  OS_FAMILY=apt
  assert_contains "$(package_list_for_group dev-tools)" "libssl-dev"
  assert_contains "$(package_list_for_group dev-tools)" "libreadline-dev"
  # libncursesw5-dev was removed on Debian 13 / Ubuntu 24.04+; libncurses-dev is
  # the portable replacement (pulls in libncursesw6).
  assert_contains "$(package_list_for_group dev-tools)" "libncurses-dev"
  [[ $(package_list_for_group dev-tools) != *libncursesw5-dev* ]] || fail "apt dev-tools still pins the removed libncursesw5-dev"
  OS_FAMILY=fedora
  assert_contains "$(package_list_for_group dev-tools)" "openssl-devel"
  OS_FAMILY=macos
  assert_contains "$(package_list_for_group dev-tools)" "openssl@3"
}

# ONB-3: `rbenv install` of Ruby 3 builds openssl, psych (libyaml), readline,
# zlib and fiddle (libffi) extensions. dev-tools must carry each library's
# development package, per family. macOS uses the SDK's libffi and zlib, but
# Homebrew's zlib is listed too.
test_dev_tools_cover_ruby_build_dependencies() {
  local family requirement members
  for family in macos apt fedora arch; do
    OS_FAMILY=$family
    members=" $(package_list_for_group dev-tools) "
    case $family in
      macos) requirement='openssl@3 readline zlib libyaml' ;;
      apt) requirement='libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev build-essential' ;;
      fedora) requirement='openssl-devel readline-devel zlib-devel libyaml-devel libffi-devel gcc make' ;;
      arch) requirement='openssl readline zlib libyaml libffi base-devel' ;;
    esac
    for requirement in $requirement; do
      [[ $members == *" $requirement "* ]] || fail "$family dev-tools lacks ruby-build dependency $requirement"
    done
    # MI-8: GitHub CLI and jq.
    for requirement in jq "$( [[ $family == arch ]] && printf github-cli || printf gh)"; do
      [[ $members == *" $requirement "* ]] || fail "$family dev-tools lacks $requirement"
    done
  done
}

# Version literals live only in lock.sh; restating them here would just make
# every dependency bump edit two files. Check the shape of the locked data.
test_default_font_policy_and_npm_artifacts_are_locked() {
  OS_FAMILY=macos
  INSTALL_FONTS=auto
  FONT_NAME=""
  font_should_install || fail "automatic font policy should install a font on desktop macOS"
  [[ $YARN_URL == *"/yarn-$YARN_VERSION.tgz" && $PNPM_URL == *"/pnpm-$PNPM_VERSION.tgz" ]] ||
    fail "npm tarball URLs do not match their locked versions"
  [[ $YARN_URL == https://registry.npmjs.org/yarn/-/* ]] || fail "Yarn tarball URL is not locked"
  [[ $PNPM_URL == https://registry.npmjs.org/pnpm/-/* ]] || fail "pnpm tarball URL is not locked"
  [[ $YARN_SHA256 =~ ^[0-9a-f]{64}$ && $PNPM_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail "npm tarball digest is invalid"
}

test_macos_package_verification_batches_brew_calls() {
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  HOMEBREW_PREFIX=$(mktemp -d)
  BREW_CALLS_FILE=$(mktemp)
  # `brew list --formula -1` prints the installed formula names, one per line.
  brew() {
    local IFS=' '                        # "$*" and the map are space-separated
    printf '%s\n' "$*" >> "$BREW_CALLS_FILE"
    [[ $1 == list && $2 == --formula ]] || return 1
    local -a listed
    read -r -a listed <<< "$(package_list_for_group core-utils)"
    printf '%s\n' unrelated "${listed[@]}" also-unrelated
  }
  selected_packages_installed || fail "installed package set not recognised"
  [[ $(grep -c . "$BREW_CALLS_FILE") == 1 ]] || fail "brew was spawned more than once for verification"
  rm -rf "$BREW_CALLS_FILE" "$HOMEBREW_PREFIX"
}

# The install path also asks brew once, not once per package, and requests
# only what is missing. A name that is an alias or old name of an installed
# formula (Homebrew's opt/<name> link exists) counts as installed; brew is
# never asked to resolve it, since an alias can point at a newer formula.
test_macos_install_batches_and_resolves_aliases() {
  local out
  OS_FAMILY=macos
  SELECTED_GROUPS=dev-tools
  FULL_UPGRADE=0
  DRY_RUN=1
  HOMEBREW_PREFIX=$(mktemp -d)
  mkdir -p "$HOMEBREW_PREFIX/opt/pkgconf"     # installed under another listed name
  BREW_CALLS_FILE=$(mktemp)
  brew() {
    local IFS=' '
    printf '%s\n' "$*" >> "$BREW_CALLS_FILE"
    [[ $1 == list && $2 == --formula ]] || return 0
    printf '%s\n' bat direnv eza fd fzf gh git jq libyaml openssl@3 readline ripgrep sqlite tcl-tk vim xz zlib pkg-config
  }
  ensure_brew() { :; }
  out=$(install_os_packages 2>&1)
  assert_contains "$out" "+ brew install zoxide"
  [[ $out != *"brew install"*pkgconf* && $out != *"brew install"*sqlite* ]] ||
    fail "an installed formula or alias was requested again: $out"
  [[ $(grep -c '^list' "$BREW_CALLS_FILE") == 1 ]] || fail "brew list ran more than once: $(cat "$BREW_CALLS_FILE")"
  # A full upgrade requests everything without listing first.
  FULL_UPGRADE=1
  : > "$BREW_CALLS_FILE"
  out=$(install_os_packages 2>&1)
  assert_contains "$out" "+ brew install bat direnv"
  ! grep -q '^list' "$BREW_CALLS_FILE" || fail "a full upgrade listed formulae"
  rm -rf "$BREW_CALLS_FILE" "$HOMEBREW_PREFIX"
}

test_compile_zsh_sources_is_best_effort() {
  local temp out
  command -v zsh >/dev/null 2>&1 || return 0
  temp=$(mktemp -d)
  TARGET="$temp/profile"
  mkdir -p "$TARGET/zsh/path"
  chmod 700 "$TARGET/zsh" "$TARGET/zsh/path"
  cp "$ROOT"/zsh/*.zsh "$TARGET/zsh/"
  cp "$ROOT"/zsh/path/*.zsh "$TARGET/zsh/path/"
  DRY_RUN=1
  out=$(compile_zsh_sources)
  assert_contains "$out" "Would compile"
  [[ ! -e $TARGET/zsh/start.zsh.zwc ]] || fail "dry run compiled the profile"
  DRY_RUN=0
  compile_zsh_sources
  [[ -s $TARGET/zsh/start.zsh.zwc && -s $TARGET/zsh/path/brew.zsh.zwc ]] || fail "profile sources were not compiled"
  # A profile without the runtime is skipped, not an error.
  rm -f "$TARGET/zsh/cache.zsh"
  compile_zsh_sources || fail "missing runtime was not skipped"
  rm -rf "$temp"
}

test_font_verifier_accepts_renamed_families() {
  local temp pair font filename
  temp=$(mktemp -d)
  HOME="$temp"
  OS_FAMILY=macos
  mkdir -p "$HOME/Library/Fonts"
  for pair in \
    AnonymousPro:AnonymiceProNerdFont-Regular.ttf \
    AurulentSansMono:AurulentSansMNerdFont-Regular.otf \
    BigBlueTerminal:BigBlueTerm437NerdFont-Regular.ttf \
    BitstreamVeraSansMono:BitstromWeraNerdFont-Regular.ttf \
    CascadiaCode:CaskaydiaCoveNerdFont-Regular.ttf \
    DejaVuSansMono:DejaVuSansMNerdFont-Regular.ttf \
    DroidSansMono:DroidSansMNerdFont-Regular.otf \
    FantasqueSansMono:FantasqueSansMNerdFont-Regular.ttf \
    Go-Mono:GoMonoNerdFont-Regular.ttf \
    Hasklig:HasklugNerdFont-Regular.otf \
    Hermit:HurmitNerdFont-Regular.otf \
    IBMPlexMono:BlexMonoNerdFont-Regular.ttf \
    LiberationMono:LiterationMonoNerdFont-Regular.ttf \
    MPlus:M+1NerdFont-Regular.ttf \
    NerdFontsSymbolsOnly:SymbolsNerdFont-Regular.ttf \
    ShareTechMono:ShureTechMonoNerdFont-Regular.ttf \
    SourceCodePro:SauceCodeProNerdFont-Regular.ttf \
    Terminus:TerminessNerdFont-Regular.ttf \
    iA-Writer:iMWritingDuoNerdFont-Regular.ttf; do
    font=${pair%%:*}
    filename=${pair#*:}
    FONT_NAME=$font
    : > "$HOME/Library/Fonts/$filename"
    font_is_installed || fail "renamed Nerd Font family was not recognised: $font"
    rm -f "$HOME/Library/Fonts/$filename"
  done
  FONT_NAME=CascadiaCode
  : > "$HOME/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"
  if font_is_installed; then
    fail "verifier accepted a different installed Nerd Font family"
  fi
  # Linux follows the upstream installer's XDG_DATA_HOME font directory.
  OS_FAMILY=apt FONT_NAME=JetBrainsMono XDG_DATA_HOME="$temp/xdg-data"
  mkdir -p "$XDG_DATA_HOME/fonts/NerdFonts"
  : > "$XDG_DATA_HOME/fonts/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf"
  font_is_installed || fail "Linux verifier ignored XDG_DATA_HOME"
  rm -rf "$temp"
}

test_nerd_fonts_installer_ignores_xdg_data_home_on_macos() {
  local temp seen
  temp=$(mktemp -d)
  printf '#!/bin/sh\nprintf "%%s" "${XDG_DATA_HOME-unset}" > "$1"\n' > "$temp/fake-install"
  chmod +x "$temp/fake-install"
  export XDG_DATA_HOME="$temp/xdg-data"
  OS_FAMILY=macos nerd_fonts_installer "$temp/fake-install" "$temp/seen"
  seen=$(cat "$temp/seen")
  [[ $seen == unset ]] || fail "macOS Nerd Fonts install saw XDG_DATA_HOME=$seen"
  OS_FAMILY=apt nerd_fonts_installer "$temp/fake-install" "$temp/seen"
  seen=$(cat "$temp/seen")
  [[ $seen == "$temp/xdg-data" ]] || fail "Linux Nerd Fonts install lost XDG_DATA_HOME"
  rm -rf "$temp"
}

test_ssh_public_material_ignores_comments() {
  local temp
  temp=$(mktemp)
  printf '%s\n' 'ssh-ed25519 AAAATEST workstation comment' > "$temp"
  assert_equals "$(ssh_public_material "$temp")" 'ssh-ed25519 AAAATEST'
  rm -f "$temp"
}

test_github_key_checks_fail_closed_on_api_errors() {
  local temp
  temp=$(mktemp -d)
  printf '%s\n' 'ssh-ed25519 AAAATEST comment' > "$temp/key.pub"
  gh() { return 1; }  # simulate network/auth failure
  if (github_ssh_key_present "$temp/key.pub") >/dev/null 2>&1; then
    fail "SSH check treated an API failure as key-present"
  fi
  local error_output
  error_output=$( (github_ssh_key_present "$temp/key.pub") 2>&1 || true )
  [[ $error_output == *'GitHub SSH keys'* ]] \
    || fail "SSH check did not die loudly on an API failure"
  if (github_gpg_key_present ABCDEF1234567890) >/dev/null 2>&1; then
    fail "GPG check treated an API failure as key-present"
  fi
  error_output=$( (github_gpg_key_present ABCDEF1234567890) 2>&1 || true )
  [[ $error_output == *'GitHub GPG keys'* ]] \
    || fail "GPG check did not die loudly on an API failure"
  rm -rf "$temp"
}

test_github_key_checks_still_match_present_keys() {
  local temp
  temp=$(mktemp -d)
  printf '%s\n' 'ssh-ed25519 AAAATEST workstation' > "$temp/key.pub"
  gh() { printf '%s\n' 'ssh-ed25519 AAAATEST other-comment'; }
  github_ssh_key_present "$temp/key.pub" || fail "matching SSH key not detected"
  gh() { printf '%s\n' '1234567890ABCDEF'; }
  github_gpg_key_present ABCDEF1234567890ABCDEF1234567890 \
    && fail "non-suffix GPG key id incorrectly matched"
  github_gpg_key_present AAAA1234567890ABCDEF \
    || fail "suffix-matching GPG key id not detected"
  rm -rf "$temp"
}

test_auto_shell_verifier_accepts_an_existing_zsh() {
  CHANGE_DEFAULT_SHELL=auto
  current_login_shell() { printf '%s\n' /bin/zsh; }
  verify_step default-shell || fail "auto shell policy rejected an existing zsh login shell"
}

test_shell_matchers_agree_on_non_zsh_shells() {
  CHANGE_DEFAULT_SHELL=auto
  # tzsh ends in "zsh" — the old skip matcher (*zsh) accepts it, which is
  # the divergence that hard-failed installs. Both matchers must reject it.
  current_login_shell() { printf '%s\n' /usr/local/bin/tzsh; }
  if verify_step default-shell; then
    fail "verifier accepted a non-zsh login shell (tzsh)"
  fi
  current_login_shell() { printf '%s\n' /bin/zsh; }
  verify_step default-shell || fail "verifier rejected a real zsh login shell"
  # A bare 'zsh' entry has no slash: the old verifier (*/zsh) rejects it
  # while the old skip matcher accepts it — this is the failing case pre-fix.
  current_login_shell() { printf '%s\n' zsh; }
  verify_step default-shell || fail "verifier rejected a bare zsh login shell"
}

test_git_identity_only_fills_missing_fields() {
  local temp
  temp=$(mktemp -d)
  export GIT_CONFIG_GLOBAL="$temp/gitconfig"
  git config --global user.name 'Existing Name'
  GIT_NAME='Replacement Name'
  GIT_EMAIL='new@example.invalid'
  DRY_RUN=0
  ensure_git_identity
  assert_equals "$(git config --global user.name)" 'Existing Name'
  assert_equals "$(git config --global user.email)" 'new@example.invalid'
  rm -rf "$temp"
}

test_profile_round_trip_and_control_character_rejection() {
  local temp mode
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  DRY_RUN=0
  SELECTED_STEPS='packages,bun'
  SELECTED_GROUPS='core-utils,languages'
  SAVED_FULL_UPGRADE=yes
  GIT_NAME='Leo Liang'
  SSH_KEY_PATH='/tmp/id test'
  write_profile
  if [[ $(uname -s) == Darwin ]]; then
    mode=$(/usr/bin/stat -f '%Lp' "$PROFILE_FILE")
  else
    mode=$(stat -c '%a' "$PROFILE_FILE")
  fi
  assert_equals "$mode" 600
  SELECTED_STEPS=fonts
  GIT_NAME=changed
  read_profile
  assert_equals "$SELECTED_STEPS" 'packages,bun'
  assert_equals "$GIT_NAME" 'Leo Liang'
  if (validate_tsv_value git-name $'bad\tname') >/dev/null 2>&1; then
    fail "TSV control character was accepted"
  fi
  printf 'groups\tfonts\n' >> "$PROFILE_FILE"
  if (read_profile) >/dev/null 2>&1; then
    fail "duplicate profile key was accepted"
  fi
  rm -rf "$temp"
}

test_local_migration_and_conflict_detection() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  LOCAL_DIR="$TARGET/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  LEGACY_STATE_FILE="$temp/legacy/install-state.tsv"
  mkdir -p "$TARGET/zsh" "$HOME" "$(dirname "$LEGACY_STATE_FILE")"
  printf '%s\n' legacy > "$TARGET/zsh/_private.zsh"
  printf '%s\n' state > "$LEGACY_STATE_FILE"
  DRY_RUN=0
  migrate_local_state
  [[ -f $LOCAL_DIR/private.zsh && -f $STATE_FILE ]] || fail "legacy local data was not migrated"
  printf '%s\n' old > "$HOME/.lp-no-gnu"
  printf '%s\n' new > "$LOCAL_DIR/flags/no-gnu"
  if (migrate_local_state) >/dev/null 2>&1; then
    fail "conflicting local marker values were accepted"
  fi
  rm -rf "$temp"
}

test_prepare_local_dir_hardens_private_zsh() {
  local temp
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  DRY_RUN=0
  mkdir -p "$LOCAL_DIR"
  printf '%s\n' 'export SECRET=1' > "$LOCAL_DIR/private.zsh"
  printf '%s\n' 'export SECRET=2' > "$LOCAL_DIR/private-interactive.zsh"
  chmod 644 "$LOCAL_DIR/private.zsh" "$LOCAL_DIR/private-interactive.zsh"
  prepare_local_dir
  assert_equals "$(file_mode "$LOCAL_DIR/private.zsh")" "600"
  assert_equals "$(file_mode "$LOCAL_DIR/private-interactive.zsh")" "600"
  # A missing private file must not make the run fail.
  rm -f "$LOCAL_DIR/private.zsh" "$LOCAL_DIR/private-interactive.zsh"
  prepare_local_dir || fail "prepare_local_dir failed without a private.zsh"
  rm -rf "$temp"
}

test_component_registry_rejects_missing_handlers() {
  validate_component_registry
  unset -f verify_bun
  if (validate_component_registry) >/dev/null 2>&1; then fail "registry accepted missing verifier"; fi
}

test_valid_csv_rejects_duplicates() {
  valid_csv "core-utils,shell" "$CANONICAL_GROUPS" || fail "a valid group list was rejected"
  ! valid_csv "core-utils,core-utils" "$CANONICAL_GROUPS" || fail "a duplicated group was accepted"
  ! valid_csv "shell,core-utils,shell" "$CANONICAL_GROUPS" || fail "a repeated group was accepted"
}

# Record the argv each curl call actually receives, one `<arg>` per argument,
# so adjacent option/value pairs can be asserted without parsing source text.
record_curl_argv() {
  CURL_LOG=$1
  curl() {
    if [[ ${1:-} == --help ]]; then printf '%s\n' '     --retry-all-errors  Retry all errors'; return 0; fi
    printf '<%s>' "$@" >> "$CURL_LOG"
    printf '\n' >> "$CURL_LOG"
    local out="" want=0 a
    for a in "$@"; do
      [[ $want == 1 ]] && { out=$a; want=0; }
      [[ $a == --output ]] && want=1
    done
    if [[ -n $out ]]; then
      printf 'fixture-bytes' > "$out"
    else
      printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv22.1.0\tx\tx\tx\tx\tx\tx\tx\tx\tIron\tfalse\n'
    fi
  }
}

test_node_lts_and_download_curl_policy() {
  # Both calls run while apply holds the lock (and inspect must stay quick), so
  # a stalled connection must time out, and neither may downgrade to HTTP.
  local temp argv
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME"
  record_curl_argv "$temp/curl-argv"
  SELECTED_STEPS=fnm
  RESOLVED_NODE_VERSION=""
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  argv=$(cat "$temp/curl-argv")
  assert_contains "$argv" '<--proto><=https><--tlsv1.2>'
  assert_contains "$argv" '<--connect-timeout><15><--max-time><30>'
  assert_contains "$argv" '<https://nodejs.org/dist/index.tab>'

  : > "$temp/curl-argv"
  DRY_RUN=0
  download_verified "https://example.invalid/artifact" \
    "$(printf 'fixture-bytes' | hash_text)" "$temp/out/artifact"
  [[ $(cat "$temp/out/artifact") == fixture-bytes ]] || fail "verified download was not installed"
  argv=$(cat "$temp/curl-argv")
  assert_contains "$argv" '<--fail>'
  assert_contains "$argv" '<--proto><=https><--tlsv1.2>'
  assert_contains "$argv" '<--connect-timeout><15><--speed-limit><1><--speed-time><60>'
  assert_contains "$argv" '<--retry-all-errors>'
  [[ $argv == *'<https://example.invalid/artifact>' ]] || fail "the URL is not curl's final argument: $argv"
  rm -rf "$temp"
}

test_lock_without_pid_gives_removal_guidance() {
  local temp out
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  LOCK_DIR="$LOCAL_DIR/.install.lock"
  DRY_RUN=0
  LOCK_HELD=0
  prepare_local_dir
  # A kill between the mkdir and the pid write leaves exactly this state.
  mkdir "$LOCK_DIR"
  out=$( (acquire_lock) 2>&1 ) && fail "a lock with no pid record was accepted"
  assert_contains "$out" "exited uncleanly"
  assert_contains "$out" "rm -rf --"
  [[ $out != *"Another Leo's Profiles operation is running"* ]] ||
    fail "reported a running operation for an ownerless lock"
  rm -rf "$temp"
}

test_dry_run_still_detects_local_conflicts() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  LOCAL_DIR="$TARGET/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  LEGACY_STATE_FILE="$temp/legacy/install-state.tsv"
  mkdir -p "$LOCAL_DIR/flags" "$HOME" "$(dirname "$LEGACY_STATE_FILE")"
  printf '%s\n' old > "$HOME/.lp-no-gnu"
  printf '%s\n' new > "$LOCAL_DIR/flags/no-gnu"
  DRY_RUN=1
  # The whole point: a green dry-run must not precede an apply that dies here.
  if (migrate_local_state) >/dev/null 2>&1; then
    fail "dry-run accepted a conflicting local marker"
  fi
  # ...and it must not have mutated anything while detecting that.
  [[ -f $HOME/.lp-no-gnu ]] || fail "dry-run removed the legacy marker"
  rm -rf "$temp"
}

test_remove_blocks_strips_only_the_managed_block() {
  local temp mode
  temp=$(mktemp -d)
  HOME="$temp/home"
  DRY_RUN=0
  mkdir -p "$HOME"
  printf '%s\n' 'user line 1' '# >>> leos-profiles loader >>>' 'source /x' '# <<< leos-profiles loader <<<' 'user line 2' > "$HOME/.zshrc"
  chmod 644 "$HOME/.zshrc"
  remove_managed_block "$HOME/.zshrc" loader >/dev/null
  assert_equals "$(< "$HOME/.zshrc")" "$(printf '%s\n%s' 'user line 1' 'user line 2')"
  mode=$(file_mode "$HOME/.zshrc")
  assert_equals "$mode" "644"
  # Idempotent once the block is gone.
  remove_managed_block "$HOME/.zshrc" loader >/dev/null
  assert_equals "$(< "$HOME/.zshrc")" "$(printf '%s\n%s' 'user line 1' 'user line 2')"
  # Blank lines that are not the installer's separator survive removal.
  printf '%s\n' 'top' '' '' '# >>> leos-profiles loader >>>' 'x' '# <<< leos-profiles loader <<<' '' 'tail' > "$HOME/.zshrc"
  remove_managed_block "$HOME/.zshrc" loader >/dev/null
  assert_equals "$(cat "$HOME/.zshrc"; printf .)" "$(printf '%s\n' 'top' '' '' '' 'tail'; printf .)"
  rm -rf "$temp"
}

# Snapshot both managed files with their bytes and modes, so a comparison
# catches content, permission and trailing-newline changes alike.
managed_files_snapshot() {
  local file
  for file in "$HOME/.zshrc" "$HOME/.zshenv"; do
    if [[ -e $file ]]; then
      printf '%s %s %s\n' "$file" "$(file_mode "$file")" "$(sha256 "$file")"
    else
      printf '%s absent\n' "$file"
    fi
  done
}

test_remove_blocks_dry_run_changes_nothing() {
  local temp before out
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  mkdir -p "$HOME"
  printf '%s\n' 'user rc' > "$HOME/.zshrc"
  printf '%s\n' 'user env' > "$HOME/.zshenv"
  DRY_RUN=0
  install_zsh_config
  before=$(managed_files_snapshot)
  DRY_RUN=1
  out=$(remove_managed_blocks)
  assert_contains "$out" "Would remove the leos-profiles loader block"
  assert_contains "$out" "Would remove the leos-profiles environment block"
  assert_equals "$(managed_files_snapshot)" "$before"
  rm -rf "$temp"
}

test_install_then_remove_round_trip_is_byte_identical() {
  local temp content before
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME"
  # Newline-terminated user files, with and without internal blank lines.
  for content in $'user rc\n' $'# user\n\nexport A=1\nalias b=c\n'; do
    printf '%s' "$content" > "$HOME/.zshrc"
    printf '%s' "$content" > "$HOME/.zshenv"
    chmod 640 "$HOME/.zshrc"
    before=$(managed_files_snapshot)
    install_zsh_config
    verify_step zsh-config || fail "installed managed blocks did not verify"
    remove_managed_blocks >/dev/null
    assert_equals "$(managed_files_snapshot)" "$before"
    rm -f "$HOME"/.zsh*.leos-profiles.bak
  done
  rm -rf "$temp"
}

test_remove_blocks_preserves_a_symlinked_zshrc() {
  local temp expected
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME" "$temp/dotfiles"
  printf '%s\n' 'linked rc' > "$temp/dotfiles/zshrc"
  expected=$(sha256 "$temp/dotfiles/zshrc")
  ln -s ../dotfiles/zshrc "$HOME/.zshrc"
  install_zsh_config
  [[ -L $HOME/.zshrc ]] || fail "install replaced the symlinked .zshrc"
  assert_contains "$(< "$temp/dotfiles/zshrc")" "# >>> leos-profiles loader >>>"
  remove_managed_blocks >/dev/null
  [[ -L $HOME/.zshrc && $(readlink "$HOME/.zshrc") == ../dotfiles/zshrc ]] ||
    fail "remove-blocks replaced the symlinked .zshrc"
  assert_equals "$(sha256 "$temp/dotfiles/zshrc")" "$expected"
  rm -rf "$temp"
}

test_remove_blocks_cli_dispatch() {
  # The real entrypoint: argument parsing, the dispatch that skips --yes and the
  # lock, and both files. LIB_ONLY is exported for this suite, so override it.
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME"
  printf '%s\n' 'user rc' > "$HOME/.zshrc"
  printf '%s\n' 'user env' > "$HOME/.zshenv"
  install_zsh_config
  out=$(LEOS_PROFILES_INSTALL_LIB_ONLY=0 HOME="$HOME" "$BASH" "$ROOT/install.sh" remove-blocks --dry-run)
  assert_contains "$out" "Would remove the leos-profiles loader block from $HOME/.zshrc"
  grep -q '^# >>> leos-profiles environment >>>$' "$HOME/.zshenv" || fail "CLI --dry-run removed a block"
  out=$(LEOS_PROFILES_INSTALL_LIB_ONLY=0 HOME="$HOME" "$BASH" "$ROOT/install.sh" remove-blocks)
  assert_contains "$out" "Removed the leos-profiles environment block from $HOME/.zshenv"
  assert_equals "$(cat "$HOME/.zshrc"; printf .)" "$(printf '%s\n.' 'user rc')"
  assert_equals "$(cat "$HOME/.zshenv"; printf .)" "$(printf '%s\n.' 'user env')"
  rm -rf "$temp"
}

test_bootstrap_skips_present_tools_on_linux() {
  local out
  OS_FAMILY=apt
  package_installed() { return 0; }
  # DRY_RUN=1 so that if the host is missing one of these, the test echoes the
  # install command instead of really running sudo apt-get on a non-apt machine.
  DRY_RUN=1
  out=$( (bootstrap_tools) 2>&1 )
  if command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    assert_contains "$out" "already present"
    [[ $out != *"apt-get"* ]] || fail "bootstrap ran the package manager with all tools present"
  else
    # unzip is what install_locked_archive_binary needs for bun and fnm.
    assert_contains "$out" "apt-get"
  fi
}

test_bootstrap_installs_unzip_when_missing() {
  local out
  OS_FAMILY=apt
  package_installed() { return 0; }
  DRY_RUN=1
  # unzip is in no package group, so the bootstrap is the only thing that can
  # provide it — and install_locked_archive_binary needs it for bun and fnm.
  command() {
    if [[ ${2:-} == unzip ]]; then return 1; fi
    builtin command "$@"
  }
  out=$( (bootstrap_tools) 2>&1 )
  assert_contains "$out" "unzip"
  [[ $out != *"already present"* ]] || fail "bootstrap skipped while unzip was missing"
}

test_concurrent_lock_rejection() {
  local temp
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  LOCK_DIR="$LOCAL_DIR/.install.lock"
  DRY_RUN=0
  LOCK_HELD=0
  prepare_local_dir
  mkdir "$LOCK_DIR"
  printf '%s\n' $$ > "$LOCK_DIR/pid"
  if (acquire_lock) >/dev/null 2>&1; then
    fail "concurrent live lock was accepted"
  fi
  rm -rf "$temp"
}

test_equivalent_github_origins() {
  github_origins_equivalent 'git@github.com:Owner/Repo.git' 'https://github.com/owner/repo' || fail "SSH/HTTPS origins were not normalized"
  github_origins_equivalent 'ssh://git@github.com/OWNER/REPO' 'https://github.com/owner/repo.git' || fail "ssh URL origin was not normalized"
  ! github_origins_equivalent 'https://github.com/owner/other' 'https://github.com/owner/repo' || fail "different origins were accepted"
}

test_recommended_and_whole_group_closure() {
  [[ $SELECTED_STEPS == 'packages,pyenv,rbenv,bun,fnm,yarn,pnpm,plugins,fonts,zsh-config,default-shell' ]] || fail "Recommended components changed"
  [[ $SELECTED_GROUPS == 'core-utils,shell,dev-tools,languages,media,network,system' ]] || fail "Recommended package groups changed"
  # MI-4: the Node and Bun tools bring no OS runtimes.
  SELECTED_STEPS=bun,yarn,pnpm
  SELECTED_GROUPS=""
  normalise_dependencies
  assert_equals "$SELECTED_STEPS" bun,yarn,pnpm,packages,fnm
  assert_equals "$SELECTED_GROUPS" ""
  # rpatool needs python3 and nothing else from languages.
  SELECTED_STEPS=bins
  normalise_dependencies
  assert_equals "$SELECTED_GROUPS" python
}

test_heroku_is_an_opt_in_macos_group() {
  local out
  OS_FAMILY=macos
  DRY_RUN=1
  FULL_UPGRADE=0
  ensure_brew() { :; }
  package_installed() { return 1; }
  ensure_sudo() { :; }
  SELECTED_GROUPS=network
  out=$(install_os_packages)
  [[ $out != *heroku* ]] || fail "the network group still taps or installs heroku: $out"
  SELECTED_GROUPS=network,heroku
  out=$(install_os_packages)
  assert_contains "$out" "+ brew tap heroku/brew"
  assert_contains "$out" "heroku"
  SELECTED_STEPS=packages
  REQUESTED_STEPS=packages
  REQUESTED_GROUPS=$SELECTED_GROUPS
  verify_step() { return 1; }
  assert_contains "$(inspect_tsv)" $'action\trepository\tHomebrew heroku/brew tap'
  SELECTED_GROUPS=network
  [[ $(inspect_tsv) != *heroku* ]] || fail "inspect discloses the heroku tap without the heroku group"
}

test_node_lts_is_resolved_once_per_run() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin"
  curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv22.1.0\tx\tx\tx\tx\tx\tx\tx\tx\tIron\tfalse\n'; }
  SELECTED_STEPS=fnm
  RESOLVED_NODE_VERSION=""
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv24.2.0\tx\tx\tx\tx\tx\tx\tx\tx\tKrypton\tfalse\n'; }
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  SELECTED_STEPS=fnm
  RESOLVED_NODE_VERSION=""
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v24.2.0
  rm -rf "$temp"
}

test_node_verifier_checks_the_real_executable() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin"
  printf '%s\n' '#!/bin/sh' \
    'case "$1" in' \
    '  --version) printf "fnm 1.39.0\\n" ;;' \
    '  default) printf "v22.14.0\\n" ;;' \
    '  exec) printf "%s\\n" "${FAKE_NODE_VERSION:-v22.14.0}" ;;' \
    'esac' > "$HOME/.local/bin/fnm"
  chmod +x "$HOME/.local/bin/fnm"
  RESOLVED_NODE_VERSION=v22.14.0
  verify_step fnm || fail "valid default Node executable was rejected"
  export FAKE_NODE_VERSION=v20.0.0
  ! verify_step fnm || fail "wrong actual Node executable version was accepted"
  rm -rf "$temp"
}

test_inspection_schema_and_membership() {
  local output
  OS_FAMILY=macos
  SELECTED_STEPS=bun
  SELECTED_GROUPS=core-utils
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=$SELECTED_GROUPS
  normalise_dependencies
  order_selected_steps
  resolve_node_lts() { RESOLVED_NODE_VERSION=v22.1.0; }
  verify_step() { return 1; }
  output=$(inspect_tsv)
  assert_contains "$output" $'meta\tschema\t1'
  assert_contains "$output" $'group\tcomponent\tbun\tselected'
  assert_contains "$output" $'group\tcomponent\tpackages\timplied'
  assert_contains "$output" $'group\tpackage\tcore-utils\tselected'
  [[ $output != *$'group\tpackage\tlanguages'* ]] || fail "bun implied the languages group"
  assert_contains "$output" $'package\tmacos\tcoreutils'
  assert_contains "$output" $'artifact\tdirect\tbun\t'
}

test_empty_custom_selection_is_inspectable() {
  local output
  OS_FAMILY=macos
  SELECTED_STEPS=""
  SELECTED_GROUPS=""
  REQUESTED_STEPS=""
  REQUESTED_GROUPS=""
  output=$(inspect_tsv)
  assert_contains "$output" $'group\tinternal\tbootstrap\tselected'
  [[ $output != *$'package\tmacos\t'* ]] || fail "empty selection emitted a package"
}

test_runtime_and_signing_invariants() {
  [[ $(grep '^_leos_plugin ' "$ROOT/zsh/interactive.zsh" | tail -n 1) == *zsh-syntax-highlighting* ]] || fail "syntax highlighting is not the last plugin action"
  ! grep -q 'tag\.gpgsign' "$ROOT/install.sh" "$ROOT"/installer/*.sh || fail "installer modifies tag signing"
  ! grep -Eq 'npm (install|update).*(claude|codex)|(@anthropic-ai/claude-code|@openai/codex)' "$ROOT/zsh/commands.zsh" || fail "AI updater contains an npm fallback"
}

test_reconcile_upgrade_policy_and_cleanup() {
  local temp
  temp=$(mktemp -d)
  COMMAND=""
  FULL_UPGRADE=1
  ASSUME_YES=0
  parse_args reconcile --yes
  assert_equals "$FULL_UPGRADE" 0
  COMMAND=""
  parse_args reconcile --yes --full-upgrade
  assert_equals "$FULL_UPGRADE" 1

  LOCAL_DIR="$temp/local"
  LOCK_DIR="$LOCAL_DIR/.install.lock"
  mkdir -p "$LOCK_DIR"
  printf '%s\n' $$ > "$LOCK_DIR/pid"
  LOCK_HELD=1
  TEMP_PATHS=("$temp/injected-failure.tmp")
  : > "${TEMP_PATHS[0]}"
  cleanup
  [[ ! -e ${TEMP_PATHS[0]} && ! -e $LOCK_DIR ]] || fail "cleanup left temporary or lock paths"
  rm -rf "$temp"
}

test_node_lts_returns_nonzero_when_unresolvable() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin"           # no fnm binary present
  curl() { return 1; }                  # network unavailable
  fnm() { return 1; }                   # fnm on PATH but list-remote fails
  RESOLVED_NODE_VERSION=""
  if resolve_node_lts; then fail "resolve_node_lts must return nonzero (not die) when unresolvable"; fi
  [[ -z $RESOLVED_NODE_VERSION ]] || fail "resolve_node_lts set a version despite failing"
  rm -rf "$temp"
}

test_inspect_degrades_when_node_lts_unresolvable() {
  local output
  OS_FAMILY=macos
  SELECTED_STEPS=fnm
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=$SELECTED_GROUPS
  normalise_dependencies
  order_selected_steps
  resolve_node_version() { return 1; } # no network or host runtime discovery
  verify_step() { return 1; }
  output=$(inspect_tsv)
  assert_contains "$output" $'runtime\tnode\tunresolved\tresolve-during-apply'
}

test_packages_full_upgrade_rerun_has_no_false_warning() {
  local temp err
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  FULL_UPGRADE=1
  install_os_packages() { :; }
  verify_step() { return 0; }
  DRY_RUN=0
  mark_done packages                    # a prior run recorded packages complete
  DRY_RUN=1
  err=$(run_step packages 2>&1 >/dev/null)
  [[ $err != *"failed verification"* ]] || fail "packages full-upgrade re-run emitted a false verification warning"
  rm -rf "$temp"
}

test_stale_lock_fails_closed_with_guidance() {
  local temp dead_pid err
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  LOCK_DIR="$LOCAL_DIR/.install.lock"
  DRY_RUN=0
  LOCK_HELD=0
  prepare_local_dir
  sh -c 'exit 0' & dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  mkdir "$LOCK_DIR"
  printf '%s\n' "$dead_pid" > "$LOCK_DIR/pid"
  # A stale (dead-PID) lock must fail closed with cleanup guidance, never be
  # auto-reclaimed (which had an unavoidable TOCTOU race).
  err=$( (acquire_lock) 2>&1 ) && fail "a stale lock was auto-reclaimed instead of failing closed"
  assert_contains "$err" "exited uncleanly"
  assert_contains "$err" "$LOCK_DIR"
  [[ $(sed -n '1p' "$LOCK_DIR/pid") == "$dead_pid" ]] || fail "acquire_lock mutated the stale lock instead of leaving it for the operator"
  rm -rf "$temp"
}

test_sparse_font_checkout_is_blobless_and_scoped() {
  local temp log
  temp=$(mktemp -d)
  log="$temp/git-args"
  : > "$log"
  DRY_RUN=0
  git() {
    local IFS=' '
    printf '%s\n' "$*" >> "$log"
    case "$*" in
      *"rev-parse HEAD"*) printf '%s\n' DEADBEEFCOMMIT ;;
    esac
    return 0
  }
  sparse_checkout_pinned "https://example.invalid/nerd-fonts.git" DEADBEEFCOMMIT "$temp/nf" nerd-fonts \
    install.sh bin patched-fonts/JetBrainsMono || fail "sparse checkout returned nonzero on a healthy path"
  assert_contains "$(cat "$log")" "sparse-checkout set install.sh bin patched-fonts/JetBrainsMono"
  assert_contains "$(cat "$log")" "fetch --depth 1 --filter=blob:none origin DEADBEEFCOMMIT"
  rm -rf "$temp"
}

test_no_os_release_upgrade_tooling() {
  # Full-upgrade / checkup paths must stay in-release. Strip comments first so
  # the intentional mentions in guard comments don't count as usage.
  local file code
  for file in "$ROOT/install.sh" "$ROOT"/installer/*.sh "$ROOT/zsh/path/apt.zsh" "$ROOT/zsh/path/dnf.zsh" "$ROOT/zsh/path/pacman.zsh"; do
    code=$(sed 's/#.*//' "$file")
    if grep -Eq 'do-release-upgrade|dnf[[:space:]]+system-upgrade|apt(-get)?[[:space:]]+(dist-upgrade|full-upgrade)' <<< "$code"; then
      fail "release-upgrade tooling found in $file; a full upgrade must stay in-release"
    fi
  done
}

test_download_verified_rejects_bad_digest() {
  local temp err
  temp=$(mktemp -d)
  DRY_RUN=0
  TEMP_PATHS=()
  curl() {
    [[ ${1:-} == --help ]] && { printf '%s\n' 'no-retry-all-errors-here'; return 0; }
    local out="" want=0 a
    for a in "$@"; do
      [[ $want == 1 ]] && { out=$a; want=0; }
      [[ $a == --output ]] && want=1
    done
    [[ -n $out ]] && printf 'fixture-bytes' > "$out"
    return 0
  }
  err=$( (download_verified "https://example.invalid/artifact" \
    0000000000000000000000000000000000000000000000000000000000000000 "$temp/artifact") 2>&1 ) \
    && fail "download_verified accepted a wrong digest"
  assert_contains "$err" "Digest mismatch"
  [[ ! -e $temp/artifact ]] || fail "download_verified kept the artifact despite a digest mismatch"
  rm -rf "$temp"
}

test_macos_package_verification_detects_missing() {
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  HOMEBREW_PREFIX=$(mktemp -d)
  brew() {
    local first=1 package IFS=' '
    for package in $(package_list_for_group core-utils); do
      [[ $first == 1 ]] && { first=0; continue; }   # pretend the first is NOT installed
      printf '%s\n' "$package"
    done
  }
  ! selected_packages_installed || fail "a missing package was reported as fully installed"
  # Its opt link alone (an alias of an installed formula) is enough.
  mkdir -p "$HOMEBREW_PREFIX/opt/$(package_list_for_group core-utils | cut -d' ' -f1)"
  selected_packages_installed || fail "an opt-linked package was reported missing"
  rm -rf "$HOMEBREW_PREFIX"
}

test_set_default_shell_auto_skips_existing_zsh() {
  CHANGE_DEFAULT_SHELL=auto
  DRY_RUN=1
  OS_FAMILY=apt
  current_login_shell() { printf '%s\n' /bin/zsh; }
  local out
  out=$(set_default_shell)
  assert_contains "$out" "already zsh"
  [[ $out != *chsh* ]] || fail "auto policy ran chsh though the login shell is already zsh"
}

test_set_default_shell_uses_unprivileged_chsh_on_linux() {
  CHANGE_DEFAULT_SHELL=yes
  DRY_RUN=1
  OS_FAMILY=apt
  current_login_shell() { printf '%s\n' /bin/bash; }
  local out
  out=$(set_default_shell 2>&1)
  assert_contains "$out" "chsh -s"
  [[ $out != *"sudo chsh"* ]] || fail "the Linux default-shell path used sudo chsh"
}

test_set_default_shell_uses_sudo_chsh_on_macos() {
  CHANGE_DEFAULT_SHELL=yes
  DRY_RUN=1
  OS_FAMILY=macos
  USER=tester
  current_login_shell() { printf '%s\n' /bin/bash; }
  local out
  out=$(set_default_shell 2>&1)
  assert_contains "$out" "sudo chsh -s"
}

test_known_hosts_matches_metadata_and_dedupes() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp"
  TEMP_PATHS=()
  gh() {
    [[ ${1:-} == api && ${2:-} == --hostname && ${3:-} == github.com && ${4:-} == meta ]] || return 1
    printf '%s\n' 'ssh-ed25519 AAAAGOOD' 'ssh-rsa AAAARSAGOOD'
  }
  ssh-keyscan() { printf '%s\n' 'github.com ssh-ed25519 AAAAGOOD' 'github.com ssh-ed25519 AAAAEVIL'; }
  ensure_github_known_hosts
  local written
  written=$(cat "$HOME/.ssh/known_hosts")
  assert_contains "$written" 'github.com ssh-ed25519 AAAAGOOD'
  [[ $written != *AAAAEVIL* ]] || fail "an unverified host key was written to known_hosts"
  ensure_github_known_hosts                                  # re-run must not duplicate
  [[ $(cat "$HOME/.ssh/known_hosts") == "$written" ]] || fail "re-running duplicated known_hosts entries"
  rm -rf "$temp"
}

# inspect_tsv for a zsh-config-only selection.
inspect_zsh_config_only() {
  SELECTED_STEPS=zsh-config
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=""
  inspect_tsv
}
# The unmarked loader and zshenv snippet written by the pre-installer
# QUICK-INSTALL, exactly as it appended them.
write_legacy_startup_files() {
  printf '%s\n' '# user rc' 'if [[ -o interactive ]]; then' \
    '    source "$HOME/.leos-profiles/zsh/start.zsh"' 'fi' 'alias keep=me' > "$1/.zshrc"
  printf '%s\n' 'export USER_ENV=1' '# leos-profiles zshenv' 'typeset -U path' \
    'path=("$HOME/.local/bin" $path)' 'export PATH' 'export AFTER=1' > "$1/.zshenv"
}

test_legacy_loader_is_reported_migrated_and_verified() {
  local temp output original_rc original_env
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  OS_FAMILY=apt
  DRY_RUN=0
  mkdir -p "$HOME"
  write_legacy_startup_files "$HOME"
  original_rc=$(< "$HOME/.zshrc")
  original_env=$(< "$HOME/.zshenv")
  output=$(report_legacy_loaders)
  assert_contains "$output" $'migration\tlegacy-loader\t'"$HOME/.zshrc"$'\tloader'
  assert_contains "$output" $'migration\tlegacy-environment\t'"$HOME/.zshenv"$'\tenvironment'
  # A legacy loader beside a correct managed block must still fail verification.
  install_managed_block "$HOME/.zshrc" loader "$(zshrc_managed_content)"
  install_managed_block "$HOME/.zshenv" environment "$(zshenv_managed_content)"
  ! verify_zsh_config || fail "verification passed with legacy loaders still present"
  strip_legacy_loader "$HOME/.zshenv" environment >/dev/null
  ! verify_zsh_config || fail "verification passed with a legacy .zshrc loader still present"
  # Dry-run reports and changes nothing.
  local before
  before=$(sha256 "$HOME/.zshrc")
  DRY_RUN=1
  output=$(install_zsh_config)
  assert_contains "$output" "Would remove the legacy unmarked leos-profiles loader from $HOME/.zshrc"
  assert_equals "$(sha256 "$HOME/.zshrc")" "$before"
  DRY_RUN=0
  install_zsh_config >/dev/null
  verify_zsh_config || fail "migrated startup files did not verify"
  [[ -z $(report_legacy_loaders) ]] || fail "a legacy loader is still reported after apply"
  # Exactly one loader remains (the managed one), user lines survive, and the
  # one-time backup holds the files as they were before the installer.
  assert_equals "$(grep -c 'zsh/start.zsh' "$HOME/.zshrc")" "1"
  assert_contains "$(< "$HOME/.zshrc")" "alias keep=me"
  assert_contains "$(< "$HOME/.zshenv")" "export AFTER=1"
  [[ $(< "$HOME/.zshenv") != *'# leos-profiles zshenv'* ]] || fail "legacy zshenv header remains"
  assert_equals "$(< "$HOME/.zshrc.leos-profiles.bak")" "$original_rc"
  assert_equals "$(< "$HOME/.zshenv.leos-profiles.bak")" "$original_env"
  if command -v zsh >/dev/null 2>&1; then
    zsh -n "$HOME/.zshrc" || fail "migrated .zshrc does not parse"
  fi
  rm -rf "$temp"
}

test_legacy_loader_inside_other_code_keeps_it_valid() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME"
  # A hand-edited variant: the loader is the only command in its branch.
  printf '%s\n' 'if [[ -n $SSH_TTY ]]; then' "  source '/opt/profiles/zsh/start.zsh'" 'else' \
    '  [[ -o interactive ]] && . ~/.leos-profiles/zsh/start.zsh  # mine' 'fi' > "$HOME/.zshrc"
  legacy_loader_present "$HOME/.zshrc" loader || fail "variant legacy loaders were not detected"
  strip_legacy_loader "$HOME/.zshrc" loader >/dev/null
  ! grep -q 'zsh/start.zsh' "$HOME/.zshrc" || fail "a legacy loader line survived"
  if command -v zsh >/dev/null 2>&1; then
    zsh -n "$HOME/.zshrc" || fail "stripping left an empty branch"
  fi
  # Unrelated lines that merely mention the path are not loaders.
  printf '%s\n' 'echo see zsh/start.zsh' 'vim ~/.leos-profiles/zsh/start.zsh' > "$HOME/.zshrc"
  ! legacy_loader_present "$HOME/.zshrc" loader || fail "a non-loader line was treated as a loader"
  rm -rf "$temp"
}

test_remove_blocks_also_removes_legacy_loaders() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME"
  write_legacy_startup_files "$HOME"
  remove_managed_blocks >/dev/null
  assert_equals "$(< "$HOME/.zshrc")" "$(printf '%s\n%s' '# user rc' 'alias keep=me')"
  assert_equals "$(< "$HOME/.zshenv")" "$(printf '%s\n%s' 'export USER_ENV=1' 'export AFTER=1')"
  rm -rf "$temp"
}

test_zshenv_block_skips_global_compinit() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME"
  install_zsh_config
  command -v zsh >/dev/null 2>&1 || { rm -rf "$temp"; return 0; }
  # Debian's /etc/zsh/zshrc checks this after .zshenv has run.
  assert_equals "$(HOME="$HOME" zsh -fc 'source ~/.zshenv; print -r -- ${skip_global_compinit-unset}')" "1"
  rm -rf "$temp"
}

test_zsh_config_follows_zdotdir() {
  local temp output
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  OS_FAMILY=apt
  DRY_RUN=0
  mkdir -p "$HOME/.config/zsh"
  # ZDOTDIR exported into the installer's environment: everything lives there.
  ZDOTDIR="$HOME/.config/zsh"
  export ZDOTDIR
  install_zsh_config
  [[ -f $ZDOTDIR/.zshrc && -f $ZDOTDIR/.zshenv ]] || fail "managed blocks were not written to ZDOTDIR"
  [[ ! -e $HOME/.zshrc && ! -e $HOME/.zshenv ]] || fail "managed blocks were written to HOME despite ZDOTDIR"
  verify_zsh_config || fail "ZDOTDIR install did not verify"
  output=$(inspect_zsh_config_only)
  assert_contains "$output" $'file\tzshrc\t'"$ZDOTDIR/.zshrc"
  assert_contains "$output" $'file\tzshenv\t'"$ZDOTDIR/.zshenv"
  remove_managed_blocks >/dev/null
  ! grep -q 'leos-profiles' "$ZDOTDIR/.zshrc" "$ZDOTDIR/.zshenv" || fail "remove-blocks missed ZDOTDIR"
  unset ZDOTDIR
  rm -rf "$temp"
}

test_zsh_config_follows_zdotdir_set_in_zshenv() {
  local temp
  command -v zsh >/dev/null 2>&1 || return 0
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  OS_FAMILY=apt
  DRY_RUN=0
  unset ZDOTDIR
  mkdir -p "$HOME/.config/zsh"
  # The common XDG layout: ~/.zshenv moves the rest of the startup files.
  printf '%s\n' 'export ZDOTDIR="$HOME/.config/zsh"' > "$HOME/.zshenv"
  # A block in ~/.zshrc is never read in this layout and must not verify.
  install_managed_block "$HOME/.zshrc" loader "$(zshrc_managed_content)"
  install_managed_block "$HOME/.zshenv" environment "$(zshenv_managed_content)"
  ! verify_zsh_config || fail "a ~/.zshrc block verified although zsh reads \$ZDOTDIR/.zshrc"
  install_zsh_config
  grep -q '^# >>> leos-profiles loader >>>$' "$HOME/.config/zsh/.zshrc" || fail "loader not in the reported ZDOTDIR"
  grep -q '^# >>> leos-profiles environment >>>$' "$HOME/.zshenv" || fail ".zshenv must stay in HOME when it sets ZDOTDIR"
  [[ ! -e $HOME/.config/zsh/.zshenv ]] || fail "wrote a .zshenv zsh never reads"
  verify_zsh_config || fail "ZDOTDIR-from-zshenv install did not verify"
  rm -rf "$temp"
}

test_macos_login_path_block() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  OS_FAMILY=macos
  DRY_RUN=0
  mkdir -p "$HOME"
  install_zsh_config
  grep -q '^# >>> leos-profiles login-path >>>$' "$HOME/.zprofile" || fail "no login-path block in .zprofile"
  verify_zsh_config || fail "macOS zsh config did not verify"
  assert_contains "$(inspect_zsh_config_only)" $'file\tzprofile\t'"$HOME/.zprofile"
  if command -v zsh >/dev/null 2>&1; then
    # What /etc/zprofile's path_helper leaves behind: local bins demoted.
    assert_equals "$(HOME="$HOME" zsh -fc 'path=(/usr/bin /bin "$HOME/.local/bin"); source ~/.zprofile; print -r -- ${path[1]}:${path[2]}:$#path')" \
      "$HOME/.local/bin:$HOME/.local/npm/bin:4"
  fi
  remove_managed_block "$HOME/.zprofile" login-path >/dev/null
  ! verify_zsh_config || fail "verification passed without the login-path block"
  install_zsh_config
  remove_managed_blocks >/dev/null
  ! grep -q 'leos-profiles' "$HOME/.zprofile" || fail "remove-blocks left the login-path block"
  rm -rf "$temp"
}

test_package_signature_is_ifs_independent() {
  local expected
  OS_FAMILY=apt
  SELECTED_GROUPS=shell,system
  # Newline-joined, as recorded by earlier versions, whatever IFS the caller has.
  expected=$'|shell,system|zsh\nsmartmontools'
  assert_equals "$(signature_packages)" "$expected"
  assert_equals "$(IFS=,; signature_packages)" "$expected"
  assert_equals "$(IFS=$'\n\t'; signature_packages)" "$expected"
  assert_equals "$(IFS=' '; step_signature packages)" "$(step_signature packages)"
}

# ONB-14: an empty package selection crashed Bash 3.2 under set -u when the
# packages step computed its signature.
test_empty_package_selection_signs_and_runs() {
  local temp out
  temp=$(mktemp -d)
  OS_FAMILY=apt
  SELECTED_STEPS=packages
  SELECTED_GROUPS=""
  assert_equals "$(signature_packages)" "||"
  LOCAL_DIR="$temp/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  DRY_RUN=0
  mark_done packages
  state_done packages || fail "an empty package selection was not recorded"
  make_fixture_checkout "$temp/profile"
  out=$(run_cli "$temp/profile" "$temp/home" apply --yes --dry-run --groups packages --package-groups none 2>&1) ||
    fail "apply --groups packages --package-groups none failed: $out"
  assert_contains "$out" "Profile apply complete"
  rm -rf "$temp"
}

test_pkg_install_uses_one_command_per_family() {
  local out
  DRY_RUN=1
  SUDO=sudo
  ensure_brew() { :; }
  OS_FAMILY=macos
  assert_equals "$(pkg_install curl jq)" "+ brew install curl jq "
  OS_FAMILY=apt
  out=$(pkg_install jq)
  assert_contains "$out" "+ sudo apt-get update"
  assert_contains "$out" "+ sudo env DEBIAN_FRONTEND=noninteractive apt-get"
  assert_contains "$out" "install -y jq"
  OS_FAMILY=fedora
  assert_equals "$(pkg_install jq)" "+ sudo dnf install -y jq "
  assert_equals "$(pkg_install)" ""
}

# CQ-7: a root installer (a container) runs privileged commands directly,
# including the /etc/shells edit, and never needs a sudo binary.
test_root_runs_privileged_commands_without_sudo() {
  local temp name
  temp=$(mktemp -d)
  mkdir -p "$temp/bin"
  for name in sudo tee chsh; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/calls"\ncat >/dev/null\n' "$name" "$temp" > "$temp/bin/$name"
    chmod +x "$temp/bin/$name"
  done
  printf '#!/bin/sh\nexit 0\n' > "$temp/bin/zsh"
  chmod +x "$temp/bin/zsh"
  PATH="$temp/bin:$PATH"
  SUDO=""
  DRY_RUN=0
  OS_FAMILY=apt
  CHANGE_DEFAULT_SHELL=yes
  current_login_shell() { printf '%s\n' /bin/bash; }
  set_default_shell </dev/null >/dev/null
  assert_contains "$(cat "$temp/calls")" "tee -a /etc/shells"
  assert_contains "$(cat "$temp/calls")" "chsh -s $temp/bin/zsh"
  [[ $(cat "$temp/calls") != *"sudo "* ]] || fail "a root run used sudo: $(cat "$temp/calls")"
  DRY_RUN=1
  assert_equals "$(run_root apt-get update)" "+ apt-get update "
  rm -rf "$temp"
}

# ONB-12: the login shell is looked up for `id -un`, with USER unset.
test_login_shell_lookup_ignores_unset_user() {
  unset USER
  getent() { [[ $2 == "$(id -un)" ]] && printf 'u:x:1:1::/home/u:/usr/bin/zsh\n'; }
  dscl() { [[ $3 == /Users/"$(id -un)" ]] && printf 'UserShell: /usr/bin/zsh\n'; }
  assert_equals "$(current_login_shell)" /usr/bin/zsh
}

# The per-tool lookup the artifact registry replaced (CQ-8), kept here as the
# reference the registry must reproduce exactly.
legacy_platform_asset() {
  local tool=$1 arch=$2
  case "$tool:$OS_FAMILY:$arch" in
    bun:macos:aarch64) printf '%s\t%s\n' "$BUN_DARWIN_AARCH64_URL" "$BUN_DARWIN_AARCH64_SHA256" ;;
    bun:macos:x64) printf '%s\t%s\n' "$BUN_DARWIN_X64_URL" "$BUN_DARWIN_X64_SHA256" ;;
    bun:*:aarch64) printf '%s\t%s\n' "$BUN_LINUX_AARCH64_URL" "$BUN_LINUX_AARCH64_SHA256" ;;
    bun:*:x64) printf '%s\t%s\n' "$BUN_LINUX_X64_URL" "$BUN_LINUX_X64_SHA256" ;;
    fnm:macos:*) printf '%s\t%s\n' "$FNM_DARWIN_URL" "$FNM_DARWIN_SHA256" ;;
    fnm:*:aarch64) printf '%s\t%s\n' "$FNM_LINUX_AARCH64_URL" "$FNM_LINUX_AARCH64_SHA256" ;;
    fnm:*:x64) printf '%s\t%s\n' "$FNM_LINUX_X64_URL" "$FNM_LINUX_X64_SHA256" ;;
    starship:macos:aarch64) printf '%s\t%s\n' "$STARSHIP_DARWIN_AARCH64_URL" "$STARSHIP_DARWIN_AARCH64_SHA256" ;;
    starship:macos:x64) printf '%s\t%s\n' "$STARSHIP_DARWIN_X64_URL" "$STARSHIP_DARWIN_X64_SHA256" ;;
    starship:*:aarch64) printf '%s\t%s\n' "$STARSHIP_LINUX_AARCH64_URL" "$STARSHIP_LINUX_AARCH64_SHA256" ;;
    starship:*:x64) printf '%s\t%s\n' "$STARSHIP_LINUX_X64_URL" "$STARSHIP_LINUX_X64_SHA256" ;;
    rpatool:*) printf '%s\t%s\n' "$RPATOOL_URL" "$RPATOOL_SHA256" ;;
  esac
}

# Same assets, and byte-identical signatures, for every family and CPU, so
# recorded state stays valid across the refactor.
test_artifact_registry_matches_legacy_lookup() {
  local family machine arch tool expected
  TARGET=/fixture/profile
  NODE_POLICY=preserve-compatible
  RESOLVED_NODE_VERSION=""
  uname() { if [[ ${1:-} == -m ]]; then printf '%s\n' "$FAKE_MACHINE"; else command uname "$@"; fi; }
  for family in macos apt fedora arch; do
    OS_FAMILY=$family
    for machine in arm64 x86_64; do
      FAKE_MACHINE=$machine
      if [[ $machine == arm64 ]]; then arch=aarch64; else arch=x64; fi
      for tool in rpatool bun fnm starship; do
        assert_equals "$(platform_asset "$tool")" "$(legacy_platform_asset "$tool" "$arch")"
      done
      assert_equals "$(signature_bins)" "|$RPATOOL_URL|$RPATOOL_SHA256"
      assert_equals "$(signature_bun)" "|$BUN_VERSION|$(legacy_platform_asset bun "$arch")"
      assert_equals "$(signature_fnm)" "|$FNM_VERSION|$(legacy_platform_asset fnm "$arch")|preserve-compatible|unresolved"
      expected="|$TARGET|$STARSHIP_VERSION|$(legacy_platform_asset starship "$arch")"
      expected+="|$ZSH_AUTOSUGGESTIONS_COMMIT|$ZSH_SYNTAX_HIGHLIGHTING_COMMIT|$ZSH_COMPLETIONS_COMMIT|$FZF_TAB_COMMIT"
      assert_equals "$(signature_plugins)" "$expected"
    done
  done
  FAKE_MACHINE=riscv64
  ! artifact_asset bun >/dev/null || fail "an unsupported CPU resolved a locked asset"
}

# Verification checks the version line (archives) or the digest (files), and
# every executable the registry lists.
test_artifact_verification_checks_version_and_digest() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp"
  OS_FAMILY=apt
  mkdir -p "$HOME/.local/bin"
  fake_tool() { printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$HOME/.local/bin/$1"; chmod +x "$HOME/.local/bin/$1"; }
  fake_tool bun "$BUN_VERSION"
  artifact_verify bun || fail "the locked bun version was rejected"
  verify_step bun || fail "verify_bun disagrees with the registry"
  fake_tool bun 0.0.1
  ! artifact_verify bun || fail "a wrong bun version was accepted"
  fake_tool starship "starship $STARSHIP_VERSION"
  artifact_verify starship || fail "the locked starship version was rejected"
  fake_tool starship "starship ${STARSHIP_VERSION}9"
  ! artifact_verify starship || fail "a longer version string was accepted as the locked one"
  fake_tool fnm "fnm $FNM_VERSION"
  artifact_verify fnm || fail "the locked fnm version was rejected"
  printf 'rpatool body' > "$HOME/.local/bin/rpatool"
  chmod 700 "$HOME/.local/bin/rpatool"
  ! artifact_verify rpatool || fail "rpatool with the wrong digest was accepted"
  artifact_asset() { printf '%s\t%s\n' https://example.invalid/rpatool "$(printf 'rpatool body' | hash_text)"; }
  artifact_verify rpatool || fail "rpatool with the locked digest was rejected"
  rm -rf "$temp"
}

test_inspect_lists_every_selected_registry_artifact() {
  local output name url digest
  OS_FAMILY=macos
  SELECTED_STEPS=bins,bun,plugins
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=""
  verify_step() { return 1; }
  output=$(inspect_tsv)
  for name in rpatool bun starship; do
    IFS=$'\t' read -r url digest <<< "$(platform_asset "$name")"
    assert_contains "$output" $'artifact\tdirect\t'"$name"$'\t'"$url"$'\t'"$digest"
  done
  [[ $output != *$'artifact\tdirect\tfnm\t'* ]] || fail "an unselected artifact was listed"
}

test_retired_flags_are_rejected_everywhere() {
  local out flag
  for flag in --ref --target --plan; do
    COMMAND=""
    out=$( (parse_args "$flag" x) 2>&1 ) && fail "$flag was accepted as the command"
    assert_contains "$out" "retired ref/target CLI"
    COMMAND=""
    out=$( (parse_args apply "$flag" x) 2>&1 ) && fail "apply accepted $flag"
    assert_contains "$out" "retired ref/target CLI"
    COMMAND=""
    out=$( (parse_args reconcile --yes "$flag") 2>&1 ) && fail "reconcile accepted $flag"
    assert_contains "$out" "retired ref/target CLI"
  done
}

# Explicit order: each test runs in its own subshell, so stubs and globals it
# changes (OS_FAMILY, INSTALL_FONTS, HOME, function overrides) cannot leak into
# later tests, and every test starts from install.sh's defaults. An EXIT trap
# runs the installer's own cleanup, removing temporary files a test's code
# under test tracked (ensure_github_known_hosts, download_verified, ...).
TESTS=(
  test_default_does_not_include_unreleased_local_bin
  test_option_validation_rejects_bad_csv_and_implicit_keys
  test_dependency_normalisation
  test_package_group_selection_is_whole_and_executable
  test_state_is_input_specific
  test_recorded_state_must_pass_verification
  test_managed_blocks_are_safe_and_reversible
  test_zsh_config_preserves_runtime_expansions
  test_tar_archive_install_creates_extraction_directory
  test_platform_assets_are_locked
  test_package_maps_cover_every_supported_os
  test_default_font_policy_and_npm_artifacts_are_locked
  test_macos_package_verification_batches_brew_calls
  test_macos_install_batches_and_resolves_aliases
  test_compile_zsh_sources_is_best_effort
  test_font_verifier_accepts_renamed_families
  test_nerd_fonts_installer_ignores_xdg_data_home_on_macos
  test_ssh_public_material_ignores_comments
  test_github_key_checks_fail_closed_on_api_errors
  test_github_key_checks_still_match_present_keys
  test_auto_shell_verifier_accepts_an_existing_zsh
  test_shell_matchers_agree_on_non_zsh_shells
  test_git_identity_only_fills_missing_fields
  test_profile_round_trip_and_control_character_rejection
  test_local_migration_and_conflict_detection
  test_prepare_local_dir_hardens_private_zsh
  test_component_registry_rejects_missing_handlers
  test_valid_csv_rejects_duplicates
  test_node_lts_and_download_curl_policy
  test_lock_without_pid_gives_removal_guidance
  test_dry_run_still_detects_local_conflicts
  test_remove_blocks_strips_only_the_managed_block
  test_remove_blocks_dry_run_changes_nothing
  test_install_then_remove_round_trip_is_byte_identical
  test_remove_blocks_preserves_a_symlinked_zshrc
  test_remove_blocks_cli_dispatch
  test_legacy_loader_is_reported_migrated_and_verified
  test_legacy_loader_inside_other_code_keeps_it_valid
  test_remove_blocks_also_removes_legacy_loaders
  test_zshenv_block_skips_global_compinit
  test_zsh_config_follows_zdotdir
  test_zsh_config_follows_zdotdir_set_in_zshenv
  test_macos_login_path_block
  test_bootstrap_skips_present_tools_on_linux
  test_bootstrap_installs_unzip_when_missing
  test_concurrent_lock_rejection
  test_equivalent_github_origins
  test_recommended_and_whole_group_closure
  test_node_lts_is_resolved_once_per_run
  test_node_verifier_checks_the_real_executable
  test_inspection_schema_and_membership
  test_empty_custom_selection_is_inspectable
  test_runtime_and_signing_invariants
  test_reconcile_upgrade_policy_and_cleanup
  test_node_lts_returns_nonzero_when_unresolvable
  test_inspect_degrades_when_node_lts_unresolvable
  test_packages_full_upgrade_rerun_has_no_false_warning
  test_stale_lock_fails_closed_with_guidance
  test_sparse_font_checkout_is_blobless_and_scoped
  test_no_os_release_upgrade_tooling
  test_download_verified_rejects_bad_digest
  test_macos_package_verification_detects_missing
  test_set_default_shell_auto_skips_existing_zsh
  test_set_default_shell_uses_unprivileged_chsh_on_linux
  test_set_default_shell_uses_sudo_chsh_on_macos
  test_known_hosts_matches_metadata_and_dedupes
  test_package_signature_is_ifs_independent
  test_empty_package_selection_signs_and_runs
  test_pkg_install_uses_one_command_per_family
  test_root_runs_privileged_commands_without_sudo
  test_login_shell_lookup_ignores_unset_user
  test_artifact_registry_matches_legacy_lookup
  test_artifact_verification_checks_version_and_digest
  test_inspect_lists_every_selected_registry_artifact
  test_retired_flags_are_rejected_everywhere
  test_heroku_is_an_opt_in_macos_group
  test_dev_tools_cover_ruby_build_dependencies
)
failed=()
for CURRENT_TEST in "${TESTS[@]}"; do
  # set +e here and set -e inside: a subshell used as an `if` condition would
  # run with errexit disabled, hiding failures the tests rely on errexit for.
  set +e
  (
    set -e
    trap cleanup EXIT
    "$CURRENT_TEST"
  )
  status=$?
  set -e
  if (( status != 0 )); then
    printf 'FAILED: %s (exit %s)\n' "$CURRENT_TEST" "$status" >&2
    failed+=("$CURRENT_TEST")
  fi
done
if (( ${#failed[@]} > 0 )); then
  printf 'install tests: %s of %s failed:\n' "${#failed[@]}" "${#TESTS[@]}" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
printf 'install tests: PASS (%s tests)\n' "${#TESTS[@]}"
