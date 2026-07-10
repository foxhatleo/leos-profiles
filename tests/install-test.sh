#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
assert_equals() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "expected '$1' to contain '$2'"; }

test_dependency_normalisation() {
  SELECTED_STEPS="zsh-config"
  SELECTED_GROUPS="core-utils"
  normalise_dependencies
  order_selected_steps
  assert_equals "$SELECTED_STEPS" "packages,zsh-config"
  assert_contains "$SELECTED_GROUPS" "shell"
}

test_default_does_not_include_unreleased_local_bin() {
  [[ $SELECTED_STEPS != *bins* ]] || fail "rpatool bins step must be opt-in"
}

test_state_is_ref_specific() {
  local temp
  temp=$(mktemp -d)
  STATE_DIR="$temp/state"
  STATE_FILE="$STATE_DIR/install-state.tsv"
  PROFILE_REF="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  DRY_RUN=0
  mark_done plugins
  state_done plugins || fail "state was not recorded"
  PROFILE_REF="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ! state_done plugins || fail "state leaked across profile refs"
  rm -rf "$temp"
}

test_managed_blocks_are_replaced_not_duplicated() {
  local temp file first second count
  temp=$(mktemp -d)
  file="$temp/.zshrc"
  first=$'echo user\n# >>> leos-profiles loader >>>\necho stale\n# <<< leos-profiles loader <<<\n'
  printf '%s' "$first" > "$file"
  install_managed_block "$file" loader 'echo current'
  second=$(< "$file")
  assert_contains "$second" "echo user"
  assert_contains "$second" "echo current"
  [[ $second != *"echo stale"* ]] || fail "stale managed content remains"
  count=$(grep -c '^# >>> leos-profiles loader >>>$' "$file")
  assert_equals "$count" "1"
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
  assert_contains "$(< "$HOME/.zshrc")" "source \"\${LEOS_PROFILES_HOME:-\$HOME/.leos-profiles}/zsh/start.zsh\""
  HOME=$saved_home
  TARGET=$saved_target
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
    for group in core-utils shell dev-tools languages media network system; do
      packages=$(package_list_for_group "$group")
      [[ -n $packages ]] || fail "missing package mapping for $family/$group"
    done
  done
}

test_default_does_not_include_unreleased_local_bin
test_dependency_normalisation
test_state_is_ref_specific
test_managed_blocks_are_replaced_not_duplicated
test_zsh_config_preserves_runtime_expansions
test_platform_assets_are_locked
test_package_maps_cover_every_supported_os
printf '%s\n' 'install tests: PASS'
