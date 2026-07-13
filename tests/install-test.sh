#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317,SC2329

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

test_package_group_selection_is_whole_and_executable() (
  SELECTED_STEPS=""
  SELECTED_GROUPS=media
  normalise_dependencies
  assert_equals "$SELECTED_STEPS" packages
  SELECTED_STEPS=""
  SELECTED_GROUPS=""
  validate_options
)

test_default_does_not_include_unreleased_local_bin() {
  [[ $SELECTED_STEPS != *bins* ]] || fail "rpatool bins step must be opt-in"
}

test_option_validation_rejects_bad_csv_and_implicit_keys() (
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
)

test_recorded_state_must_pass_verification() (
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
  # libncursesw5-dev was removed on Debian 13 / Ubuntu 24.04+; libncurses-dev is
  # the portable replacement (pulls in libncursesw6).
  assert_contains "$(package_list_for_group dev-tools)" "libncurses-dev"
  [[ $(package_list_for_group dev-tools) != *libncursesw5-dev* ]] || fail "apt dev-tools still pins the removed libncursesw5-dev"
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

test_macos_package_verification_batches_brew_calls() (
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  BREW_CALLS_FILE=$(mktemp)
  brew() {
    printf '%s\n' "call" >> "$BREW_CALLS_FILE"
    local package
    # $1=list $2=--versions; shift them explicitly because Bash 3.2 joins
    # "${@:3}" when the caller uses this test suite's newline-only IFS.
    shift 2
    for package in "$@"; do printf '%s 1.0\n' "$package"; done
  }
  selected_packages_installed || fail "installed package set not recognised"
  [[ $(grep -c call "$BREW_CALLS_FILE") == 1 ]] || fail "brew was spawned more than once for verification"
  rm -f "$BREW_CALLS_FILE"
)

test_font_verifier_accepts_renamed_families() (
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
  rm -rf "$temp"
)

test_ssh_public_material_ignores_comments() {
  local temp
  temp=$(mktemp)
  printf '%s\n' 'ssh-ed25519 AAAATEST workstation comment' > "$temp"
  assert_equals "$(ssh_public_material "$temp")" 'ssh-ed25519 AAAATEST'
  rm -f "$temp"
}

test_github_key_checks_fail_closed_on_api_errors() (
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
)

test_github_key_checks_still_match_present_keys() (
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
)

test_auto_shell_verifier_accepts_an_existing_zsh() (
  CHANGE_DEFAULT_SHELL=auto
  current_login_shell() { printf '%s\n' /bin/zsh; }
  verify_step default-shell || fail "auto shell policy rejected an existing zsh login shell"
)

test_shell_matchers_agree_on_non_zsh_shells() (
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

test_profile_round_trip_and_control_character_rejection() (
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
)

test_local_migration_and_conflict_detection() (
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
)

test_concurrent_lock_rejection() (
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
)

test_equivalent_github_origins() {
  github_origins_equivalent 'git@github.com:Owner/Repo.git' 'https://github.com/owner/repo' || fail "SSH/HTTPS origins were not normalized"
  github_origins_equivalent 'ssh://git@github.com/OWNER/REPO' 'https://github.com/owner/repo.git' || fail "ssh URL origin was not normalized"
  ! github_origins_equivalent 'https://github.com/owner/other' 'https://github.com/owner/repo' || fail "different origins were accepted"
}

test_recommended_and_whole_group_closure() (
  [[ $SELECTED_STEPS == 'packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell' ]] || fail "Recommended components changed"
  [[ $SELECTED_GROUPS == 'core-utils,shell,dev-tools,languages,media,network,system' ]] || fail "Recommended package groups changed"
  SELECTED_STEPS=bun
  SELECTED_GROUPS=core-utils
  normalise_dependencies
  assert_contains "$SELECTED_STEPS" packages
  assert_contains "$SELECTED_GROUPS" languages
)

test_node_lts_is_resolved_once_per_run() (
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin"
  curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv22.1.0\tx\tx\tx\tx\tx\tx\tx\tx\tIron\tfalse\n'; }
  RESOLVED_NODE_VERSION=""
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv24.2.0\tx\tx\tx\tx\tx\tx\tx\tx\tKrypton\tfalse\n'; }
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  RESOLVED_NODE_VERSION=""
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v24.2.0
  rm -rf "$temp"
)

test_node_verifier_checks_the_real_executable() (
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin"
  printf '%s\n' '#!/bin/sh' \
    'case "$1" in' \
    '  --version) printf "fnm 1.39.0\\n" ;;' \
    '  default) printf "v22.1.0\\n" ;;' \
    '  exec) printf "%s\\n" "${FAKE_NODE_VERSION:-v22.1.0}" ;;' \
    'esac' > "$HOME/.local/bin/fnm"
  chmod +x "$HOME/.local/bin/fnm"
  RESOLVED_NODE_VERSION=v22.1.0
  verify_step fnm || fail "valid default Node executable was rejected"
  export FAKE_NODE_VERSION=v20.0.0
  ! verify_step fnm || fail "wrong actual Node executable version was accepted"
  rm -rf "$temp"
)

test_inspection_schema_and_membership() (
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
  assert_contains "$output" $'group\tpackage\tlanguages\timplied'
  assert_contains "$output" $'package\tmacos\tnode'
  assert_contains "$output" $'artifact\tdirect\tbun\t'
)

test_empty_custom_selection_is_inspectable() (
  local output
  OS_FAMILY=macos
  SELECTED_STEPS=""
  SELECTED_GROUPS=""
  REQUESTED_STEPS=""
  REQUESTED_GROUPS=""
  output=$(inspect_tsv)
  assert_contains "$output" $'group\tinternal\tbootstrap\tselected'
  [[ $output != *$'package\tmacos\t'* ]] || fail "empty selection emitted a package"
)

test_runtime_and_signing_invariants() {
  [[ $(grep '^_leos_plugin ' "$ROOT/zsh/interactive.zsh" | tail -n 1) == *zsh-syntax-highlighting* ]] || fail "syntax highlighting is not the last plugin action"
  ! grep -q 'tag\.gpgsign' "$ROOT/install.sh" || fail "installer modifies tag signing"
  ! grep -Eq 'npm (install|update).*(claude|codex)|(@anthropic-ai/claude-code|@openai/codex)' "$ROOT/zsh/commands.zsh" || fail "AI updater contains an npm fallback"
}

test_reconcile_upgrade_policy_and_cleanup() (
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
)

test_node_lts_returns_nonzero_when_unresolvable() (
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
)

test_inspect_degrades_when_node_lts_unresolvable() (
  local output
  OS_FAMILY=macos
  SELECTED_STEPS=fnm
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=$SELECTED_GROUPS
  normalise_dependencies
  order_selected_steps
  resolve_node_lts() { return 1; }      # graceful failure must be reachable now
  verify_step() { return 1; }
  output=$(inspect_tsv)
  assert_contains "$output" $'moving\tnode-lts\tresolve-during-apply'
)

test_packages_full_upgrade_rerun_has_no_false_warning() (
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
)

test_stale_lock_fails_closed_with_guidance() (
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
)

test_sparse_font_checkout_is_blobless_and_scoped() (
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
)

test_no_os_release_upgrade_tooling() {
  # Full-upgrade / checkup paths must stay in-release. Strip comments first so
  # the intentional mentions in guard comments don't count as usage.
  local file code
  for file in "$ROOT/install.sh" "$ROOT/zsh/path/apt.zsh" "$ROOT/zsh/path/dnf.zsh" "$ROOT/zsh/path/pacman.zsh"; do
    code=$(sed 's/#.*//' "$file")
    if grep -Eq 'do-release-upgrade|dnf[[:space:]]+system-upgrade|apt(-get)?[[:space:]]+(dist-upgrade|full-upgrade)' <<< "$code"; then
      fail "release-upgrade tooling found in $file; a full upgrade must stay in-release"
    fi
  done
}

test_download_verified_rejects_bad_digest() (
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
)

test_macos_package_verification_detects_missing() (
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  brew() {
    shift 2                              # drop 'list --versions'
    local first=1 package
    for package in "$@"; do
      [[ $first == 1 ]] && { first=0; continue; }   # pretend the first is NOT installed
      printf '%s 1.0\n' "$package"
    done
  }
  ! selected_packages_installed || fail "a missing package was reported as fully installed"
)

test_set_default_shell_auto_skips_existing_zsh() (
  CHANGE_DEFAULT_SHELL=auto
  DRY_RUN=1
  OS_FAMILY=apt
  current_login_shell() { printf '%s\n' /bin/zsh; }
  local out
  out=$(set_default_shell)
  assert_contains "$out" "already zsh"
  [[ $out != *chsh* ]] || fail "auto policy ran chsh though the login shell is already zsh"
)

test_set_default_shell_uses_unprivileged_chsh_on_linux() (
  CHANGE_DEFAULT_SHELL=yes
  DRY_RUN=1
  OS_FAMILY=apt
  current_login_shell() { printf '%s\n' /bin/bash; }
  local out
  out=$(set_default_shell 2>&1)
  assert_contains "$out" "chsh -s"
  [[ $out != *"sudo chsh"* ]] || fail "the Linux default-shell path used sudo chsh"
)

test_set_default_shell_uses_sudo_chsh_on_macos() (
  CHANGE_DEFAULT_SHELL=yes
  DRY_RUN=1
  OS_FAMILY=macos
  USER=tester
  current_login_shell() { printf '%s\n' /bin/bash; }
  local out
  out=$(set_default_shell 2>&1)
  assert_contains "$out" "sudo chsh -s"
)

test_known_hosts_matches_metadata_and_dedupes() (
  local temp
  temp=$(mktemp -d)
  HOME="$temp"
  TEMP_PATHS=()
  gh() {
    [[ ${1:-} == api && ${2:-} == meta ]] || return 1
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
)

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
test_default_font_policy_and_npm_versions_are_locked
test_macos_package_verification_batches_brew_calls
test_font_verifier_accepts_renamed_families
test_ssh_public_material_ignores_comments
test_github_key_checks_fail_closed_on_api_errors
test_github_key_checks_still_match_present_keys
test_auto_shell_verifier_accepts_an_existing_zsh
test_shell_matchers_agree_on_non_zsh_shells
test_git_identity_only_fills_missing_fields
test_profile_round_trip_and_control_character_rejection
test_local_migration_and_conflict_detection
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
printf '%s\n' 'install tests: PASS'
