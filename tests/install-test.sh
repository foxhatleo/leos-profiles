#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2329

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
assert_equals() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "expected '$1' to contain '$2'"; }

test_dependency_normalisation() (
  SELECTED_STEPS="zsh-config"
  SELECTED_GROUPS="core-utils"
  normalise_dependencies
  order_selected_steps
  assert_equals "$SELECTED_STEPS" "packages,zsh-config"
  assert_contains "$SELECTED_GROUPS" "shell"
)

test_default_does_not_include_unreleased_local_bin() {
  [[ $SELECTED_STEPS != *bins* ]] || fail "rpatool bins step must be opt-in"
}

test_option_validation_rejects_ambiguous_paths_and_csv() (
  ALLOW_MUTABLE_REF=1
  TARGET=relative-profile
  if (validate_options) >/dev/null 2>&1; then
    fail "relative profile target was accepted"
  fi
  TARGET="$HOME/.leos-profiles"
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
)

test_state_is_input_specific() (
  local temp first_signature
  temp=$(mktemp -d)
  STATE_DIR="$temp/state"
  STATE_FILE="$STATE_DIR/install-state.tsv"
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  PROFILE_REF="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  DRY_RUN=0
  mark_done packages
  state_done packages || fail "state was not recorded"
  first_signature=$(awk -F '\t' '$1 == "packages" { print $2 }' "$STATE_FILE")
  [[ $first_signature =~ ^[0-9a-f]{64}$ ]] || fail "state did not record an input signature"
  PROFILE_REF="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  state_done packages || fail "an unrelated profile ref invalidated package state"
  SELECTED_GROUPS=shell
  ! state_done packages || fail "state leaked across different package selections"
  rm -rf "$temp"
)

test_recorded_state_must_pass_verification() (
  local temp installed=0
  temp=$(mktemp -d)
  STATE_DIR="$temp/state"
  STATE_FILE="$STATE_DIR/install-state.tsv"
  OS_FAMILY=macos
  DRY_RUN=0
  step_signature() { printf '%064d\n' 1; }
  install_local_bins() { installed=1; }
  verify_step() { (( installed == 1 )); }
  mark_done bins
  run_step bins
  assert_equals "$installed" "1"
  rm -rf "$temp"
)

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

test_tar_archive_install_creates_extraction_directory() (
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
)

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
    for group in core-utils shell dev-tools languages media network system; do
      packages=$(package_list_for_group "$group")
      [[ -n $packages ]] || fail "missing package mapping for $family/$group"
    done
  done
  OS_FAMILY=apt
  assert_contains "$(package_list_for_group dev-tools)" "libssl-dev"
  assert_contains "$(package_list_for_group dev-tools)" "libreadline-dev"
  OS_FAMILY=fedora
  assert_contains "$(package_list_for_group dev-tools)" "openssl-devel"
  OS_FAMILY=macos
  assert_contains "$(package_list_for_group dev-tools)" "openssl@3"
}

test_default_font_policy_and_npm_versions_are_locked() {
  OS_FAMILY=macos
  INSTALL_FONTS=auto
  FONT_NAME=""
  font_should_install || fail "automatic font policy should install a font on desktop macOS"
  assert_equals "$YARN_VERSION" "1.22.22"
  assert_equals "$PNPM_VERSION" "11.11.0"
  [[ $YARN_URL == https://registry.npmjs.org/yarn/-/* ]] || fail "Yarn tarball URL is not locked"
  [[ $PNPM_URL == https://registry.npmjs.org/pnpm/-/* ]] || fail "pnpm tarball URL is not locked"
  [[ $YARN_SHA256 =~ ^[0-9a-f]{64}$ && $PNPM_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail "npm tarball digest is invalid"
}

test_ssh_public_material_ignores_comments() {
  local temp
  temp=$(mktemp)
  printf '%s\n' 'ssh-ed25519 AAAATEST workstation comment' > "$temp"
  assert_equals "$(ssh_public_material "$temp")" 'ssh-ed25519 AAAATEST'
  rm -f "$temp"
}

test_auto_shell_verifier_accepts_an_existing_zsh() (
  CHANGE_DEFAULT_SHELL=auto
  current_login_shell() { printf '%s\n' /bin/zsh; }
  verify_step default-shell || fail "auto shell policy rejected an existing zsh login shell"
)

test_git_identity_only_fills_missing_fields() (
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
)

test_default_does_not_include_unreleased_local_bin
test_option_validation_rejects_ambiguous_paths_and_csv
test_dependency_normalisation
test_state_is_input_specific
test_recorded_state_must_pass_verification
test_managed_blocks_are_safe_and_reversible
test_zsh_config_preserves_runtime_expansions
test_tar_archive_install_creates_extraction_directory
test_platform_assets_are_locked
test_package_maps_cover_every_supported_os
test_default_font_policy_and_npm_versions_are_locked
test_ssh_public_material_ignores_comments
test_auto_shell_verifier_accepts_an_existing_zsh
test_git_identity_only_fills_missing_fields
printf '%s\n' 'install tests: PASS'
