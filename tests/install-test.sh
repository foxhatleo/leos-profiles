#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317,SC2329

set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# The zsh-config tests resolve startup files from ZDOTDIR; never let the
# developer's own value point them outside the fixture HOME. GNUPGHOME
# likewise: gpg-agent.conf must be the fixture HOME's (~/.gnupg).
unset ZDOTDIR GNUPGHOME
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

# uv's archive holds uv and uvx in a versioned directory: both are installed,
# verified and listed, from the registry alone.
test_uv_artifact_installs_uv_and_uvx() {
  local temp name
  temp=$(mktemp -d)
  mkdir -p "$temp/source/uv-aarch64-apple-darwin" "$temp/home"
  for name in uv uvx; do
    printf '#!/bin/sh\nprintf "%%s %%s (fixture 2026-10-01)\\n" "%s" "%s"\n' "$name" "$UV_VERSION" > "$temp/source/uv-aarch64-apple-darwin/$name"
    chmod 755 "$temp/source/uv-aarch64-apple-darwin/$name"
  done
  TEST_ARCHIVE="$temp/uv.tar.gz"
  tar -czf "$TEST_ARCHIVE" -C "$temp/source" uv-aarch64-apple-darwin
  HOME="$temp/home"
  DRY_RUN=0
  OS_FAMILY=macos
  download_verified() { mkdir -p "$(dirname -- "$3")"; cp "$TEST_ARCHIVE" "$3"; }
  uname() { if [[ ${1:-} == -m ]]; then printf 'arm64\n'; else command uname "$@"; fi; }
  install_uv
  [[ -x $HOME/.local/bin/uv && -x $HOME/.local/bin/uvx ]] || fail "uv and uvx were not both installed"
  verify_step uv || fail "the installed uv did not verify"
  rm "$HOME/.local/bin/uvx"
  ! verify_step uv || fail "uv verified without uvx"
  assert_contains "$(platform_asset uv)" "uv-aarch64-apple-darwin.tar.gz"
  OS_FAMILY=apt
  assert_contains "$(platform_asset uv)" "uv-aarch64-unknown-linux-musl.tar.gz"
  rm -rf "$temp"
}

# BP-11: Starship and uv use the static musl builds on every Linux CPU.
test_linux_artifacts_use_static_musl_builds() {
  local tool machine
  OS_FAMILY=apt
  uname() { if [[ ${1:-} == -m ]]; then printf '%s\n' "$FAKE_MACHINE"; else command uname "$@"; fi; }
  for tool in starship uv; do
    for machine in aarch64 x86_64; do
      FAKE_MACHINE=$machine
      assert_contains "$(platform_asset "$tool")" "$tool-$machine-unknown-linux-musl.tar.gz"$'\t'
    done
  done
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
  # Linux uses the XDG_DATA_HOME font directory the installer writes to.
  OS_FAMILY=apt FONT_NAME=JetBrainsMono XDG_DATA_HOME="$temp/xdg-data"
  mkdir -p "$XDG_DATA_HOME/fonts/NerdFonts"
  : > "$XDG_DATA_HOME/fonts/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf"
  font_is_installed || fail "Linux verifier ignored XDG_DATA_HOME"
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
  [[ $SELECTED_STEPS == 'packages,pyenv,rbenv,bun,fnm,yarn,pnpm,uv,plugins,fonts,zsh-config,default-shell' ]] || fail "Recommended components changed"
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
  SUDO=sudo
  current_login_shell() { printf '%s\n' /bin/bash; }
  local out
  out=$(set_default_shell 2>&1)
  # SEC-8: the root-owned system zsh, not a PATH-resolved Homebrew one.
  [[ -x /bin/zsh ]] || return 0
  assert_contains "$out" "sudo chsh -s /bin/zsh $(id -un)"
  current_login_shell() { printf '%s\n' /bin/zsh; }
  verify_step default-shell || fail "/bin/zsh did not verify as the macOS login shell"
}

# BP-9: without chsh the run continues, the step waits for a manual action,
# and the run ends with exit 3 and the record.
test_missing_chsh_queues_a_manual_action() {
  local temp out status=0
  temp=$(mktemp -d)
  mkdir -p "$temp/bin"
  printf '#!/bin/sh\nexit 0\n' > "$temp/bin/zsh"
  chmod +x "$temp/bin/zsh"
  OS_FAMILY=apt
  CHANGE_DEFAULT_SHELL=yes
  DRY_RUN=0
  LOCAL_DIR="$temp/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  current_login_shell() { printf '%s\n' /bin/bash; }
  command() { if [[ ${1:-} == -v && ${2:-} == chsh ]]; then return 1; fi; builtin command "$@"; }
  PATH="$temp/bin:$PATH"
  out=$( (run_step default-shell; printf 'continued\n'; finish_manual_actions) 2>"$temp/err" ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" "continued"
  assert_contains "$out" $'manual-action\tset-login-shell\t'"$temp/bin/zsh"$'\t'"$(id -un)"
  assert_contains "$(cat "$temp/err")" "chsh -s $temp/bin/zsh"
  ! state_done default-shell || fail "a step awaiting a manual action was recorded complete"
  rm -rf "$temp"
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

# SEC-7: stale github.com keys are dropped (other hosts keep theirs), and a
# symlinked known_hosts is written through, keeping the link.
test_known_hosts_drops_stale_keys_and_keeps_a_symlink() {
  local temp written
  temp=$(mktemp -d)
  HOME="$temp/home"
  TEMP_PATHS=()
  mkdir -p "$HOME/.ssh" "$temp/dotfiles"
  gh() { printf '%s\n' 'ssh-ed25519 AAAAGOOD'; }
  ssh-keyscan() { printf '%s\n' 'github.com ssh-ed25519 AAAAGOOD'; }
  printf '%s\n' 'other.example ssh-rsa AAAAOLD' 'github.com ssh-rsa AAAAOLD' 'github.com ssh-ed25519 AAAAGOOD' \
    > "$temp/dotfiles/known_hosts"
  chmod 644 "$temp/dotfiles/known_hosts"
  ln -s ../../dotfiles/known_hosts "$HOME/.ssh/known_hosts"
  ensure_github_known_hosts
  [[ -L $HOME/.ssh/known_hosts ]] || fail "the known_hosts symlink was replaced by a file"
  written=$(cat "$temp/dotfiles/known_hosts")
  assert_equals "$written" $'other.example ssh-rsa AAAAOLD\ngithub.com ssh-ed25519 AAAAGOOD'
  assert_equals "$(file_mode "$temp/dotfiles/known_hosts")" 644
  [[ -z $(find "$HOME/.ssh" "$temp/dotfiles" -name '*.old' -o -name '.known-hosts.tmp.*' | grep -v '^$' || true) ]] ||
    fail "temporary known_hosts copies were left behind"
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
  # BP-7: no dpkg configuration-file prompt can stop an unattended run.
  assert_contains "$out" "+ sudo env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y jq"
  OS_FAMILY=fedora
  assert_equals "$(pkg_install jq)" "+ sudo dnf install -y jq "
  # BP-8: Arch never installs against a stale database.
  OS_FAMILY=arch
  assert_equals "$(pkg_install jq)" "+ sudo pacman -Syu --needed --noconfirm jq "
  assert_equals "$(pkg_install)" ""
}

test_apt_upgrade_keeps_local_configuration() {
  local out
  OS_FAMILY=apt
  DRY_RUN=1
  SUDO=sudo
  FULL_UPGRADE=1
  SELECTED_GROUPS=shell
  out=$(install_os_packages)
  assert_contains "$out" "apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y"
  assert_contains "$(cat "$ROOT/zsh/path/apt.zsh")" "-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y"
}

# SEC-4: --allowerasing applies only to the ffmpeg swap, never to the whole
# media install; without media there is no RPM Fusion and no swap.
test_fedora_media_swaps_only_ffmpeg() {
  local out
  OS_FAMILY=fedora
  DRY_RUN=1
  SUDO=sudo
  FULL_UPGRADE=0
  package_installed() { return 1; }
  rpm() { [[ $1 == -E ]] && printf '44\n'; return 1; }
  SELECTED_GROUPS=media
  out=$(install_os_packages)
  assert_contains "$out" "+ sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm"
  assert_contains "$out" "+ sudo dnf install -y ImageMagick yt-dlp "
  assert_contains "$out" "+ sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing"
  [[ $(grep -c -- --allowerasing <<< "$out") == 1 ]] || fail "--allowerasing reached another command: $out"
  SELECTED_GROUPS=core-utils
  out=$(install_os_packages)
  [[ $out != *rpmfusion* && $out != *swap* && $out != *allowerasing* ]] || fail "a non-media install touched RPM Fusion: $out"
}

# BP-8: missing packages on Arch sync and upgrade in one transaction, with or
# without the full-upgrade policy; there is never a bare -S.
test_arch_installs_with_a_synced_database() {
  local out
  OS_FAMILY=arch
  DRY_RUN=1
  SUDO=sudo
  package_installed() { return 1; }
  SELECTED_GROUPS=shell
  for FULL_UPGRADE in 0 1; do
    out=$(install_os_packages)
    assert_equals "$out" "+ sudo pacman -Syu --needed --noconfirm zsh "
  done
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
  assert_equals "$(component_handler plugins artifacts)" starship
  assert_equals "$(component_handler zsh-config artifacts)" ""
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

test_version_manager_extension_compile_is_best_effort() {
  local temp err
  temp=$(mktemp -d)
  mkdir -p "$temp/root/src"
  printf '#!/bin/sh\nexit 1\n' > "$temp/root/src/configure"
  chmod +x "$temp/root/src/configure"
  DRY_RUN=0
  err=$(compile_optional_extension "$temp/root" pyenv 2>&1) || fail "a failed optional compile aborted the step"
  assert_contains "$err" "pyenv's optional native extension did not compile"
  rm -rf "$temp"
}

# A fixture Nerd Fonts release: <dir>/Fixture.tar.xz holding two fonts and a
# README, and <dir>/SHA-256.txt listing it with the given digest (default:
# the real one). A fake curl serves files from <dir> by name and logs each URL.
make_font_release() {
  local dir=$1 digest=${2:-}
  mkdir -p "$dir/src"
  : > "$dir/src/FixtureNerdFont-Regular.ttf"
  : > "$dir/src/FixtureNerdFontMono-Bold.otf"
  : > "$dir/src/README.md"
  tar -cJf "$dir/Fixture.tar.xz" -C "$dir/src" . 2>/dev/null || return 1
  [[ -n $digest ]] || digest=$(sha256 "$dir/Fixture.tar.xz")
  printf '%s  %s\n' "$digest" Fixture.tar.xz "$(printf other | hash_text)" Other.zip > "$dir/SHA-256.txt"
  NERD_FONTS_TEST_RELEASE_URL=https://example.invalid/release
  NERD_FONTS_TEST_CHECKSUMS_SHA256=$(sha256 "$dir/SHA-256.txt")
  FONT_RELEASE_DIR=$dir
  curl() {
    [[ ${1:-} == --help ]] && return 0
    local out="" want=0 a url=""
    for a in "$@"; do
      [[ $want == 1 ]] && { out=$a; want=0; continue; }
      [[ $a == --output ]] && want=1
      url=$a
    done
    printf '%s\n' "$url" >> "$FONT_RELEASE_DIR/curl.log"
    cp "$FONT_RELEASE_DIR/${url##*/}" "$out"
  }
}

# ONB-9: a font is one verified release archive, never a repository clone, and
# an unknown name stops before any font download.
test_nerd_font_rejects_unknown_names_before_downloading() {
  local temp err
  temp=$(mktemp -d)
  make_font_release "$temp/release" || { rm -rf "$temp"; return 0; }
  HOME="$temp/home"
  OS_FAMILY=apt
  DRY_RUN=0
  err=$( (install_nerd_font Fixtur) 2>&1 ) && fail "an unknown font name was accepted"
  assert_contains "$err" "Unknown Nerd Font: Fixtur"
  assert_equals "$(cat "$temp/release/curl.log")" "https://example.invalid/release/SHA-256.txt"
  [[ ! -e $HOME/.local/share/fonts ]] || fail "an unknown font created the font directory"
  rm -rf "$temp"
}

test_nerd_font_archive_is_verified_and_installed() {
  local temp fake
  temp=$(mktemp -d)
  make_font_release "$temp/release" || { rm -rf "$temp"; return 0; }
  HOME="$temp/home"
  DRY_RUN=0
  FONT_NAME=Fixture
  INSTALL_FONTS=yes
  fake="$temp/bin"
  mkdir -p "$fake"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/fc-cache.log"\n' "$temp" > "$fake/fc-cache"
  chmod +x "$fake/fc-cache"
  PATH="$fake:$PATH"
  # macOS: ~/Library/Fonts/NerdFonts, whatever XDG_DATA_HOME says; no fc-cache.
  export XDG_DATA_HOME="$temp/xdg"
  OS_FAMILY=macos
  install_fonts
  [[ -f $HOME/Library/Fonts/NerdFonts/FixtureNerdFont-Regular.ttf &&
     -f $HOME/Library/Fonts/NerdFonts/FixtureNerdFontMono-Bold.otf ]] || fail "macOS fonts were not installed"
  [[ ! -e $HOME/Library/Fonts/NerdFonts/README.md ]] || fail "a non-font file was installed"
  [[ ! -e $temp/xdg && ! -e $temp/fc-cache.log ]] || fail "macOS used XDG_DATA_HOME or fc-cache"
  verify_step fonts || fail "installed macOS fonts did not verify"
  # Linux: the XDG font directory, then fc-cache.
  OS_FAMILY=apt
  install_fonts
  [[ -f $XDG_DATA_HOME/fonts/NerdFonts/FixtureNerdFont-Regular.ttf ]] || fail "Linux fonts were not installed"
  assert_equals "$(cat "$temp/fc-cache.log")" "-f $XDG_DATA_HOME/fonts/NerdFonts"
  verify_step fonts || fail "installed Linux fonts did not verify"
  rm -rf "$temp"
}

test_nerd_font_archive_digest_mismatch_fails() {
  local temp err
  temp=$(mktemp -d)
  make_font_release "$temp/release" 0000000000000000000000000000000000000000000000000000000000000000 ||
    { rm -rf "$temp"; return 0; }
  HOME="$temp/home"
  OS_FAMILY=apt
  DRY_RUN=0
  err=$( (install_nerd_font Fixture) 2>&1 ) && fail "a font archive with the wrong digest was installed"
  assert_contains "$err" "Digest mismatch"
  [[ -z $(find "$HOME" -name '*.ttf' 2>/dev/null) ]] || fail "fonts were installed despite the mismatch"
  # A checksum list that is not the pinned one is rejected before it is read.
  NERD_FONTS_TEST_CHECKSUMS_SHA256=$(printf tampered | hash_text)
  err=$( (install_nerd_font Fixture) 2>&1 ) && fail "an unpinned checksum list was trusted"
  assert_contains "$err" "Digest mismatch"
  rm -rf "$temp"
}

# ONB-10: a Node mirror serves the LTS lookup too, and inspect names it.
test_node_lts_lookup_honours_the_dist_mirror() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME"
  record_curl_argv "$temp/curl-argv"
  SELECTED_STEPS=fnm
  RESOLVED_NODE_VERSION=""
  FNM_NODE_DIST_MIRROR=https://mirror.example.invalid/node/
  resolve_node_lts
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  assert_contains "$(cat "$temp/curl-argv")" '<https://mirror.example.invalid/node/index.tab>'
  OS_FAMILY=apt
  REQUESTED_STEPS=fnm
  SELECTED_GROUPS=""
  REQUESTED_GROUPS=""
  verify_step() { return 1; }
  assert_contains "$(inspect_tsv)" $'external\tnode-lts-index\thttps://mirror.example.invalid/node/index.tab'
  rm -rf "$temp"
}

test_sudo_keeps_proxy_variables() {
  DRY_RUN=1
  SUDO=sudo
  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY all_proxy
  assert_equals "$(run_root apt-get update)" "+ sudo apt-get update "
  export HTTPS_PROXY=http://proxy.example.invalid:3128
  local out
  out=$(run_root apt-get update)
  out=${out//\\/}                       # printf %q may escape the commas
  assert_equals "$out" \
    "+ sudo --preserve-env=http_proxy,https_proxy,no_proxy,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,ALL_PROXY,all_proxy apt-get update "
  SUDO=""
  assert_equals "$(run_root apt-get update)" "+ apt-get update "
}

# --brew-mirror applies exactly brew.zsh's mirror variables to the run and
# records (or clears) the runtime flag; reconcile follows the flag.
test_brew_mirror_option_matches_the_runtime_mirror() {
  local temp name value
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  OS_FAMILY=macos
  DRY_RUN=0
  for name in HOMEBREW_BREW_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN; do
    value=$(sed -n "s/^ *export $name=\"\(.*\)\"$/\1/p" "$ROOT/zsh/path/brew.zsh")
    [[ -n $value ]] || fail "brew.zsh no longer exports $name"
    case $name in
      HOMEBREW_BREW_GIT_REMOTE) assert_equals "$BREW_CHINA_GIT_REMOTE" "$value" ;;
      HOMEBREW_BOTTLE_DOMAIN) assert_equals "$BREW_CHINA_BOTTLE_DOMAIN" "$value" ;;
      HOMEBREW_API_DOMAIN) assert_equals "$BREW_CHINA_API_DOMAIN" "$value" ;;
    esac
  done
  unset HOMEBREW_BREW_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN
  BREW_MIRROR=china
  apply_brew_mirror >/dev/null
  [[ -f $LOCAL_DIR/flags/brew-china ]] || fail "--brew-mirror china did not set the runtime flag"
  assert_equals "$(file_mode "$LOCAL_DIR/flags/brew-china")" 600
  assert_equals "${HOMEBREW_BOTTLE_DOMAIN:-}" "$BREW_CHINA_BOTTLE_DOMAIN"
  # Reconcile: no option, the flag decides.
  BREW_MIRROR=""
  assert_equals "$(brew_mirror_effective)" china
  BREW_MIRROR=none
  (apply_brew_mirror >/dev/null)
  [[ ! -e $LOCAL_DIR/flags/brew-china ]] || fail "--brew-mirror none kept the runtime flag"
  BREW_MIRROR=""
  assert_equals "$(brew_mirror_effective)" none
  rm -rf "$temp"
}

# ONB-4: components install first, credentials last, so a registration pause
# (exit 3) no longer holds back the rest of the setup.
test_credentials_run_after_components() {
  local temp out zsh_line ssh_line
  temp=$(mktemp -d)
  make_fixture_checkout "$temp/profile"
  out=$(run_cli "$temp/profile" "$temp/home" apply --yes --dry-run --groups zsh-config --package-groups none \
    --ssh generate --default-shell no 2>&1) || fail "dry-run apply failed: $out"
  zsh_line=$(grep -n 'Running zsh-config' <<< "$out" | cut -d: -f1)
  ssh_line=$(grep -n 'Would prepare the selected SSH key' <<< "$out" | cut -d: -f1)
  [[ -n $zsh_line && -n $ssh_line ]] || fail "missing component or credential output: $out"
  (( zsh_line < ssh_line )) || fail "credentials ran before the components"
  rm -rf "$temp"
}

# A credential pause also reports the manual actions components queued.
test_credential_pause_reports_queued_component_actions() {
  local out status=0
  queue_manual_action set-login-shell /bin/zsh tester "install chsh" 2>/dev/null
  out=$( (credential_manual_action github-login '' https://github.com/login "log in") 2>/dev/null ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" $'manual-action\tset-login-shell\t/bin/zsh\ttester'
  assert_contains "$out" $'manual-action\tgithub-login\t\thttps://github.com/login'
}

# --- Preflight (ONB-1, CI-11): stubs for sudo and the terminal. -------------
# preflight_fixture <tty yes|no> <sudo -n result 0|1>: a plan that needs root,
# a recording sudo, and nothing else selected.
preflight_fixture() {
  PREFLIGHT_TTY=$1
  SUDO_N_STATUS=$2
  SUDO_LOG=$(mktemp)
  track_temp "$SUDO_LOG"
  SUDO=sudo
  DRY_RUN=0
  OS_FAMILY=apt
  SELECTED_STEPS=packages
  SELECTED_GROUPS=shell
  INVOCATION="bash /fixture/install.sh apply --yes"
  stdin_is_terminal() { [[ $PREFLIGHT_TTY == yes ]]; }
  privileged_plan() { printf 'package-manager\tsudo apt-get install of the selected packages\n'; }
  sudo() {
    printf '%s\n' "$*" >> "$SUDO_LOG"
    [[ $1 == -n ]] && return "$SUDO_N_STATUS"
    return 0
  }
}

test_preflight_without_terminal_stops_before_any_change() {
  local out status=0
  preflight_fixture no 1
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" $'manual-action\trun-in-terminal\t\tbash /fixture/install.sh apply --yes'
  assert_contains "$out" "sudo needs a password"
  assert_equals "$(cat "$SUDO_LOG")" "-n true"
}

test_preflight_accepts_passwordless_sudo_without_terminal() {
  preflight_fixture no 0
  preflight >/dev/null 2>&1 || fail "NOPASSWD sudo without a terminal was refused"
  assert_equals "$(cat "$SUDO_LOG")" "-n true"
}

test_preflight_asks_for_sudo_once_on_a_terminal() {
  local out
  preflight_fixture yes 1
  out=$(preflight 2>&1) || fail "preflight on a terminal failed: $out"
  assert_contains "$out" "sudo asks for your password once"
  assert_equals "$(cat "$SUDO_LOG")" $'-n true\n-v'
}

test_preflight_needs_no_sudo_without_root_actions() {
  preflight_fixture no 1
  privileged_plan() { :; }
  preflight >/dev/null 2>&1 || fail "a plan without root actions was refused"
  [[ ! -s $SUDO_LOG ]] || fail "sudo was called without a root action: $(cat "$SUDO_LOG")"
}

test_preflight_refuses_prompts_without_terminal() {
  local out status=0
  preflight_fixture no 0
  privileged_plan() { :; }
  SSH_MODE=generate
  SSH_PASSPHRASE_MODE=prompt
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" "passphrase"
  SSH_MODE=skip
  # Linux chsh asks for the user's password.
  SELECTED_STEPS=default-shell
  CHANGE_DEFAULT_SHELL=yes
  verify_default_shell() { return 1; }
  command() { if [[ ${1:-} == -v && ${2:-} == chsh ]]; then printf '/usr/bin/chsh\n'; return 0; fi; builtin command "$@"; }
  status=0
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" "chsh asks for your password"
  # Dry-run reports the stop instead of exiting, and never calls sudo.
  DRY_RUN=1
  : > "$SUDO_LOG"
  out=$(preflight 2>&1) || fail "dry-run preflight failed: $out"
  assert_contains "$out" "Would stop before any change"
  [[ ! -s $SUDO_LOG ]] || fail "a dry run called sudo"
}

# --- Version-manager conflicts (ONB-5, CI-11) ------------------------------
test_existing_pyenv_is_reported_and_can_be_kept() {
  local temp out status=0
  temp=$(mktemp -d)
  HOME="$temp/home"
  HOMEBREW_PREFIX="$temp/brew"
  mkdir -p "$HOME/.pyenv/bin" "$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/opt/rbenv"
  OS_FAMILY=macos
  SELECTED_STEPS=pyenv,rbenv
  assert_equals "$(version_manager_conflicts pyenv)" "$HOME/.pyenv"$'\tnot-a-git-checkout'
  assert_equals "$(version_manager_conflicts rbenv)" "$HOMEBREW_PREFIX/opt/rbenv"$'\thomebrew-install'
  out=$(report_conflicts)
  assert_contains "$out" $'conflict\tpyenv\t'"$HOME/.pyenv"$'\tnot-a-git-checkout'
  assert_contains "$out" $'conflict\trbenv\t'"$HOMEBREW_PREFIX/opt/rbenv"$'\thomebrew-install'
  # Without the option, preflight stops before any change and names it.
  privileged_plan() { :; }
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "--skip-existing-version-managers"
  # With it, both components are skipped and reported as such.
  SKIP_EXISTING_VERSION_MANAGERS=1
  install_pyenv() { fail "the kept pyenv was replaced"; }
  install_rbenv() { fail "the Homebrew rbenv was shadowed"; }
  out=$(run_step pyenv; run_step rbenv)
  assert_contains "$out" "Skipping pyenv: keeping the existing installation"
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=""
  assert_contains "$(inspect_tsv)" $'postcondition\tpyenv\tskipped'
  # A pinned checkout of another repository is a conflict too.
  rm -rf "$HOME/.pyenv"
  git init -q "$HOME/.pyenv"
  git -C "$HOME/.pyenv" remote add origin https://github.com/example/not-pyenv.git
  assert_equals "$(version_manager_conflicts pyenv)" "$HOME/.pyenv"$'\tunexpected-origin'
  rm -rf "$temp"
}

# --- Disclosure records (ONB-6, ONB-11, MI-3, R5) --------------------------
test_existing_setups_and_shadowed_artifacts_are_disclosed() {
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  HOMEBREW_PREFIX="$temp/brew"
  mkdir -p "$HOME/.oh-my-zsh" "$HOME/.nvm" "$HOME/miniconda3" "$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/opt/powerlevel10k"
  printf '#!/bin/sh\n' > "$HOMEBREW_PREFIX/bin/starship"
  chmod +x "$HOMEBREW_PREFIX/bin/starship"
  unset ZSH NVM_DIR
  OS_FAMILY=macos
  SELECTED_STEPS=plugins
  out=$(report_existing_setups)
  assert_contains "$out" $'existing\toh-my-zsh\t'"$HOME/.oh-my-zsh"$'\t'
  assert_contains "$out" $'existing\tpowerlevel10k\t'"$HOMEBREW_PREFIX/opt/powerlevel10k"$'\t'
  assert_contains "$out" $'existing\tnvm\t'"$HOME/.nvm"$'\t'
  assert_contains "$out" $'existing\tconda\t'"$HOME/miniconda3"$'\t'
  out=$(report_shadowed_artifacts)
  assert_equals "$out" $'shadow\tstarship\t'"$HOMEBREW_PREFIX/bin/starship"$'\t'"$HOME/.local/bin/starship"
  SELECTED_STEPS=pyenv
  [[ -z $(report_shadowed_artifacts) ]] || fail "an unselected artifact was reported as shadowing"
  rm -rf "$temp"
}

test_privileged_and_behaviour_records() {
  local out
  OS_FAMILY=fedora
  SUDO=sudo
  FULL_UPGRADE=0
  SELECTED_STEPS=packages
  SELECTED_GROUPS=media
  bootstrap_missing() { :; }
  selected_packages_installed() { return 1; }
  out=$(privileged_plan)
  assert_contains "$out" $'package-manager\tsudo dnf install of the selected packages'
  assert_contains "$out" $'dnf-swap\tsudo dnf swap -y ffmpeg-free ffmpeg --allowerasing'
  OS_FAMILY=arch
  assert_contains "$(privileged_plan)" $'pacman-sync\tsudo pacman -Syu --needed --noconfirm'
  OS_FAMILY=apt
  SELECTED_GROUPS=dev-tools
  selected_packages_installed() { return 0; }
  [[ -z $(privileged_plan) ]] || fail "installed packages still planned a root action: $(privileged_plan)"
  assert_contains "$(report_behaviour)" $'behaviour\tcompat-symlinks\t'
  OS_FAMILY=macos
  SELECTED_GROUPS=core-utils
  GPG_MODE=generate
  out=$(report_behaviour)
  assert_contains "$out" $'behaviour\tgnu-tools\t'
  assert_contains "$out" $'behaviour\tgit-identity\t'
  # The macOS login-shell change: /etc/shells (when missing) and sudo chsh.
  SELECTED_STEPS=default-shell
  CHANGE_DEFAULT_SHELL=yes
  verify_default_shell() { return 1; }
  preferred_zsh_path() { printf '/fixture/zsh\n'; }
  out=$(privileged_plan)
  assert_contains "$out" $'etc-shells\tsudo append /fixture/zsh to /etc/shells'
  assert_contains "$out" $'login-shell\tsudo chsh -s /fixture/zsh '"$(id -un)"
}

test_unsupported_macs_are_warned_about() {
  local out
  OS_FAMILY=macos
  sw_vers() { printf '%s\n' "$FAKE_MACOS"; }
  sysctl() { printf '%s\n' "$FAKE_ARM64"; }
  FAKE_MACOS=15.4 FAKE_ARM64=1
  ! platform_support_problem >/dev/null || fail "Apple-silicon macOS 15 was reported as unsupported"
  FAKE_MACOS=26.0
  ! platform_support_problem >/dev/null || fail "macOS 26 was reported as unsupported"
  FAKE_MACOS=14.7
  assert_contains "$(platform_support_problem)" "macOS 14.7 is unsupported"
  FAKE_MACOS=15.4 FAKE_ARM64=0
  assert_contains "$(platform_support_problem)" "Intel Mac"
  SELECTED_STEPS=""
  SELECTED_GROUPS=""
  REQUESTED_STEPS=""
  REQUESTED_GROUPS=""
  out=$(inspect_tsv)
  assert_contains "$out" $'warning\tunsupported-platform\tIntel Mac'
  OS_FAMILY=apt
  ! platform_support_problem >/dev/null || fail "Linux was checked against macOS support"
  # A platform the lock has no build for is a warning, not an inspect failure.
  OS_FAMILY=macos
  SELECTED_STEPS=uv
  REQUESTED_STEPS=uv
  uname() { if [[ ${1:-} == -m ]]; then printf 'x86_64\n'; else command uname "$@"; fi; }
  verify_step() { return 1; }
  out=$(inspect_tsv) || fail "inspect failed without a locked uv build"
  assert_contains "$out" $'warning\tno-locked-artifact\tuv has no locked build for macos on x86_64'
}

# --- --node-version (SEC-5) ------------------------------------------------
test_approved_node_version_is_enforced() {
  local out status=0
  SELECTED_STEPS=fnm
  select_existing_node() { return 1; }
  resolve_node_lts() { RESOLVED_NODE_VERSION=$LIVE_LTS; NODE_SELECTION=current-lts; [[ -n $LIVE_LTS ]]; }
  NODE_VERSION_APPROVED=v24.11.1
  LIVE_LTS=v24.11.1
  check_approved_node_version || fail "the approved, current LTS was refused"
  RESOLVED_NODE_VERSION=""
  LIVE_LTS=v24.12.0
  out=$( (check_approved_node_version) 2>&1 ) || status=$?
  assert_equals "$status" 2
  assert_contains "$out" "the current LTS is now v24.12.0"
  # Offline: the approved version is used as the current-lts choice.
  RESOLVED_NODE_VERSION=""
  LIVE_LTS=""
  check_approved_node_version
  assert_equals "$RESOLVED_NODE_VERSION:$NODE_SELECTION" v24.11.1:current-lts
  COMMAND=""
  out=$( (parse_args apply --node-version 24; validate_options) 2>&1 ) && fail "a malformed --node-version was accepted"
  assert_contains "$out" "--node-version must look like"
}

# --- inspect --saved (MI-14) and inventory, remove-blocks anywhere (ONB-13) --
test_inspect_saved_uses_the_saved_selection() {
  local temp out status=0
  temp=$(mktemp -d)
  make_fixture_checkout "$temp/profile"
  out=$(run_cli "$temp/profile" "$temp/home" inspect --saved 2>&1) && fail "inspect --saved worked without a saved profile"
  assert_contains "$out" "No saved install profile"
  mkdir -p "$temp/profile/local"
  printf '%s\t%s\n' schema 2 groups zsh-config package-groups shell full-upgrade yes \
    fonts no font '' default-shell no git-name '' git-email '' ssh skip ssh-key '' \
    ssh-passphrase empty gpg skip gpg-key '' gpg-passphrase empty node-channel current-lts \
    node-policy preserve-compatible ai-cli-update-channel native package-channel system > "$temp/profile/local/install-profile.tsv"
  out=$(run_cli "$temp/profile" "$temp/home" inspect --saved 2>&1) || fail "inspect --saved failed: $out"
  assert_contains "$out" $'policy\tselection\tsaved'
  assert_contains "$out" $'policy\tfull-upgrade\tno'
  assert_contains "$out" $'group\tcomponent\tzsh-config\tselected'
  [[ $out != *$'group\tcomponent\tfnm'* ]] || fail "inspect --saved used the default selection"
  out=$(run_cli "$temp/profile" "$temp/home" inspect --saved --groups fnm 2>&1) || status=$?
  [[ $status -ne 0 ]] || fail "inspect --saved accepted a selection option"
  assert_contains "$out" "takes only --full-upgrade"
  rm -rf "$temp"
}

test_inventory_lists_managed_items() {
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  LOCAL_DIR="$TARGET/local"
  OS_FAMILY=apt
  DRY_RUN=0
  mkdir -p "$HOME/.local/bin" "$LOCAL_DIR/flags"
  install_zsh_config
  : > "$HOME/.local/bin/uv"
  : > "$LOCAL_DIR/flags/no-gnu"
  export GIT_CONFIG_GLOBAL="$temp/gitconfig"
  git config --global user.name Fixture
  out=$(inventory_records)
  assert_contains "$out" $'item\tmanaged-block\tloader\t'"$HOME/.zshrc"$'\tpresent'
  assert_contains "$out" $'item\tmanaged-block\tlogin-path\t'"$HOME/.zprofile"$'\tabsent'
  assert_contains "$out" $'item\tlocal-bin\tuv\t'"$HOME/.local/bin/uv"$'\tpresent'
  assert_contains "$out" $'item\tlocal-bin\tstarship\t'"$HOME/.local/bin/starship"$'\tabsent'
  assert_contains "$out" $'item\tflag\tno-gnu\t'"$LOCAL_DIR/flags/no-gnu"$'\tpresent'
  assert_contains "$out" $'item\tgit-global\tuser.name\t'"$temp/gitconfig"$'\tpresent'
  assert_contains "$out" $'item\tgit-global\tcommit.gpgsign\t'"$temp/gitconfig"$'\tabsent'
  assert_contains "$out" $'item\tfonts\tnerd-fonts\t'
  INVENTORY_FORMAT=human
  assert_contains "$(inventory)" "present  managed-block"
  rm -rf "$temp"
}

# remove-blocks and inventory work on a host detect_os rejects.
test_remove_blocks_and_inventory_need_no_supported_platform() {
  local temp out status=0
  temp=$(mktemp -d)
  make_fixture_checkout "$temp/profile"
  mkdir -p "$temp/bin" "$temp/home"
  printf '#!/bin/sh\n[ "$1" = -s ] && { echo FreeBSD; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$temp/bin/uname"
  chmod +x "$temp/bin/uname"
  printf '%s\n' '# >>> leos-profiles loader >>>' 'x' '# <<< leos-profiles loader <<<' > "$temp/home/.zshrc"
  # detect_os also recognises Linux hosts by their package manager, so the
  # fake host must not see apt-get, dnf or pacman: mirror the system tools
  # without them.
  local dir tool
  for dir in /usr/bin /bin /usr/sbin /sbin; do
    for tool in "$dir"/*; do
      case ${tool##*/} in apt-get|dnf|pacman) continue ;; esac
      [[ -e $temp/bin/${tool##*/} ]] || ln -s "$tool" "$temp/bin/${tool##*/}"
    done
  done
  PATH="$temp/bin"
  out=$(run_cli "$temp/profile" "$temp/home" apply --yes --dry-run 2>&1) || status=$?
  [[ $status -ne 0 ]] || fail "apply ran on an unsupported host"
  assert_contains "$out" "Unsupported platform"
  out=$(run_cli "$temp/profile" "$temp/home" inventory --tsv 2>&1) || fail "inventory failed on an unsupported host: $out"
  assert_contains "$out" $'item\tmanaged-block\tloader\t'"$temp/home/.zshrc"$'\tpresent'
  out=$(run_cli "$temp/profile" "$temp/home" remove-blocks 2>&1) || fail "remove-blocks failed on an unsupported host: $out"
  ! grep -q leos-profiles "$temp/home/.zshrc" || fail "remove-blocks left the block"
  rm -rf "$temp"
}

# --- Success hints (MI-10) -------------------------------------------------
test_success_names_the_terminal_font_and_wsl_action() {
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  OS_FAMILY=apt
  XDG_DATA_HOME="$temp/xdg"
  mkdir -p "$XDG_DATA_HOME/fonts/NerdFonts"
  : > "$XDG_DATA_HOME/fonts/NerdFonts/CaskaydiaCoveNerdFont-Regular.ttf"
  SELECTED_STEPS=plugins,fonts
  INSTALL_FONTS=yes
  FONT_NAME=CascadiaCode
  assert_contains "$(print_terminal_font_hint)" '"CaskaydiaCove Nerd Font"'
  INSTALL_FONTS=no
  assert_contains "$(print_terminal_font_hint)" "LEOS_PLAIN_PROMPT=1"
  # WSL: installing the font queues the Windows-side installation.
  INSTALL_FONTS=yes
  DRY_RUN=0
  install_nerd_font() { :; }
  is_wsl() { return 0; }
  install_fonts 2>/dev/null
  assert_contains "$PENDING_MANUAL_ACTIONS" $'manual-action\tinstall-windows-font\t'"$XDG_DATA_HOME/fonts/NerdFonts"$'\t'"$NERD_FONTS_RELEASE_URL/CascadiaCode.zip"
  rm -rf "$temp"
}

# --- Credentials and signing (ONB-2, MI-1, MI-2, MI-7, SEC-1, SEC-7) -------
test_gpg_expiry_validation() {
  local value
  for value in 2y 1y 6m 3w 10d 0 never 1000d; do
    valid_gpg_expiry "$value" || fail "valid expiry rejected: $value"
  done
  for value in '' 2 2x 0y 02y -1y 2yy 'never ' 99999y 2Y; do
    if valid_gpg_expiry "$value"; then fail "invalid expiry accepted: '$value'"; fi
  done
  GPG_EXPIRY=1y2m
  if (validate_options) >/dev/null 2>&1; then fail "validate_options accepted --gpg-expiry 1y2m"; fi
  local temp out status=0
  temp=$(mktemp -d)
  make_fixture_checkout "$temp/profile"
  out=$(run_cli "$temp/profile" "$temp/home" inspect --gpg generate --gpg-expiry forever 2>&1) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "Invalid --gpg-expiry value"
  rm -rf "$temp"
}

test_preflight_refuses_a_second_gpg_generation() {
  local temp out status=0
  temp=$(mktemp -d)
  preflight_fixture yes 0
  privileged_plan() { :; }
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  mkdir -p "$LOCAL_DIR"
  printf 'gpg\treuse\ngpg-key\t%s\n' 0123456789ABCDEF0123456789ABCDEF01234567 > "$PROFILE_FILE"
  cp "$PROFILE_FILE" "$temp/before"
  gpg() { printf 'fpr:::::::::%s:\n' 0123456789ABCDEF0123456789ABCDEF01234567; }
  GPG_MODE=generate
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "--gpg reuse --gpg-key 0123456789ABCDEF0123456789ABCDEF01234567"
  cmp -s "$PROFILE_FILE" "$temp/before" || fail "the refused run rewrote the saved profile"
  GPG_MODE=reuse
  GPG_KEY_ID=0123456789ABCDEF0123456789ABCDEF01234567
  preflight >/dev/null 2>&1 || fail "reusing the saved key was refused"
  # --ssh agent without an agent stops before any change, too.
  SSH_MODE=agent
  status=0
  out=$(unset SSH_AUTH_SOCK; preflight 2>&1) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "SSH_AUTH_SOCK is not set"
  status=0
  out=$(SSH_AUTH_SOCK="$PROFILE_FILE" preflight 2>&1) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "not a socket"
  rm -rf "$temp"
}

test_profile_reads_optional_credential_keys() {
  local temp
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  DRY_RUN=0
  GPG_EXPIRY=6m
  write_profile
  GPG_EXPIRY=2y
  read_profile
  assert_equals "$GPG_EXPIRY" 6m
  # A profile written before these keys existed still reads, with defaults.
  grep -v '^gpg-expiry' "$PROFILE_FILE" > "$temp/old"
  mv "$temp/old" "$PROFILE_FILE"
  GPG_EXPIRY=2y
  read_profile
  assert_equals "$GPG_EXPIRY" 2y
  rm -rf "$temp"
}

test_signing_options_and_profile_compatibility() {
  local temp
  SELECTED_STEPS=packages
  # Default: skip, or gpg when a GPG key is selected (what --gpg always meant).
  SIGNING_MODE='' GPG_MODE=skip
  validate_options
  assert_equals "$SIGNING_MODE" skip
  SIGNING_MODE='' GPG_MODE=generate
  validate_options
  assert_equals "$SIGNING_MODE" gpg
  SIGNING_MODE=skip GPG_MODE=generate
  validate_options
  assert_equals "$SIGNING_MODE" skip
  # Each signing method needs its key; bad values stop.
  SIGNING_MODE=ssh SSH_MODE=skip
  if (validate_options) >/dev/null 2>&1; then fail "--signing ssh without an SSH key was accepted"; fi
  SIGNING_MODE=gpg GPG_MODE=skip
  if (validate_options) >/dev/null 2>&1; then fail "--signing gpg without a GPG key was accepted"; fi
  SIGNING_MODE=x509
  if (validate_options) >/dev/null 2>&1; then fail "an unknown --signing value was accepted"; fi
  SIGNING_MODE=skip SSH_CONFIG=yes SSH_MODE=skip
  if (validate_options) >/dev/null 2>&1; then fail "--ssh-config yes without an SSH key was accepted"; fi
  SSH_CONFIG=maybe SSH_MODE=reuse SSH_KEY_PATH=/fixture/key
  if (validate_options) >/dev/null 2>&1; then fail "an unknown --ssh-config value was accepted"; fi
  # --ssh agent takes a selector, not a path, and requires one.
  SSH_CONFIG=no SSH_MODE=agent SSH_KEY_PATH=''
  if (validate_options) >/dev/null 2>&1; then fail "--ssh agent without --ssh-key was accepted"; fi
  SSH_KEY_PATH='SHA256:abc laptop'
  SIGNING_MODE=ssh
  validate_options
  # A saved profile from before --signing: a GPG key keeps signing with it.
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  DRY_RUN=0
  SSH_MODE=skip SSH_KEY_PATH='' GPG_MODE=reuse GPG_KEY_ID=0123456789ABCDEF0123456789ABCDEF01234567 SIGNING_MODE=gpg
  write_profile
  grep -v -e '^signing' -e '^ssh-config' -e '^gpg-expiry' "$PROFILE_FILE" > "$temp/old"
  mv "$temp/old" "$PROFILE_FILE"
  SIGNING_MODE=''
  read_profile
  validate_options
  assert_equals "$SIGNING_MODE" gpg
  # Saved choices round-trip.
  SSH_MODE=agent SSH_KEY_PATH=SHA256:abc SSH_CONFIG=yes SIGNING_MODE=ssh GPG_MODE=skip GPG_KEY_ID=''
  write_profile
  SSH_MODE=skip SSH_CONFIG=no SIGNING_MODE=''
  read_profile
  assert_equals "$SSH_MODE|$SSH_KEY_PATH|$SSH_CONFIG|$SIGNING_MODE" 'agent|SHA256:abc|yes|ssh'
  rm -rf "$temp"
}

test_inspect_discloses_signing_agent_and_pinentry() {
  local out
  HOME=$(mktemp -d)
  track_temp "$HOME"
  SELECTED_STEPS=""
  SELECTED_GROUPS=""
  REQUESTED_STEPS=""
  REQUESTED_GROUPS=""
  OS_FAMILY=macos
  HOMEBREW_PREFIX=/fixture/brew
  LOCAL_DIR=/fixture/local
  SSH_MODE=agent SSH_KEY_PATH=SHA256:abc SSH_CONFIG=yes GPG_MODE=skip SIGNING_MODE=ssh
  validate_options
  out=$(inspect_tsv)
  assert_contains "$out" $'group\tcredential\tsigning\tssh'
  assert_contains "$out" $'global\tgit\tuser.signingkey,gpg.format,gpg.ssh.allowedSignersFile,commit.gpgsign'
  assert_contains "$out" $'file\tallowed-signers\t/fixture/local/allowed_signers'
  assert_contains "$out" $'file\tssh-agent-public-key\t/fixture/local/ssh-agent-key.pub'
  assert_contains "$out" $'behaviour\tssh-agent\t'
  assert_contains "$out" $'action\tssh-config\tmanaged Host github.com block: AddKeysToAgent yes, UseKeychain yes\n'
  assert_contains "$out" $'file\tssh-config\t'"$HOME/.ssh/config"
  assert_contains "$out" $'behaviour\tgit-identity\t'
  [[ $out != *$'file\tssh-reference\t'* ]] || fail "an agent selector was reported as a key file"
  [[ $out != *pinentry* ]] || fail "pinentry disclosed without GPG"
  # GPG signing: the pinentry package and gpg-agent.conf.
  SSH_MODE=reuse SSH_KEY_PATH=/fixture/id_ed25519 GPG_MODE=generate SIGNING_MODE=gpg
  out=$(inspect_tsv)
  assert_contains "$out" $'action\tssh-config\tmanaged Host github.com block: AddKeysToAgent yes, UseKeychain yes, IdentityFile /fixture/id_ed25519'
  assert_contains "$out" $'global\tgit\tuser.signingkey,gpg.format,commit.gpgsign'
  assert_contains "$out" $'action\tpinentry\t/fixture/brew/bin/pinentry-mac '
  assert_contains "$out" $'package\tmacos\tpinentry-mac'
  assert_contains "$out" $'file\tgpg-agent-conf\t'"$HOME/.gnupg/gpg-agent.conf"
  # --signing skip with a GPG key: no global signing settings.
  SIGNING_MODE=skip
  out=$(inspect_tsv)
  [[ $out != *$'global\tgit\t'* ]] || fail "--signing skip disclosed global signing settings"
  assert_contains "$out" $'action\tgpg\tverify GitHub email and manual public-key registration; signing settings unchanged'
}

test_remove_blocks_and_inventory_cover_credential_blocks() {
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  LOCAL_DIR="$TARGET/local"
  OS_FAMILY=macos
  DRY_RUN=0
  mkdir -p "$HOME/.ssh" "$HOME/.gnupg" "$LOCAL_DIR"
  printf '%s\n' 'Host *' '  ServerAliveInterval 60' > "$HOME/.ssh/config"
  printf '%s\n' 'default-cache-ttl 600' > "$HOME/.gnupg/gpg-agent.conf"
  cp "$HOME/.ssh/config" "$temp/ssh-config.before"
  cp "$HOME/.gnupg/gpg-agent.conf" "$temp/gpg-agent.before"
  install_managed_block "$HOME/.ssh/config" ssh-config $'Host github.com\n  AddKeysToAgent yes'
  install_managed_block "$HOME/.gnupg/gpg-agent.conf" pinentry 'pinentry-program /fixture/pinentry'
  : > "$LOCAL_DIR/allowed_signers"
  export GIT_CONFIG_GLOBAL="$temp/gitconfig"
  out=$(inventory_records)
  assert_contains "$out" $'item\tmanaged-block\tssh-config\t'"$HOME/.ssh/config"$'\tpresent'
  assert_contains "$out" $'item\tmanaged-block\tpinentry\t'"$HOME/.gnupg/gpg-agent.conf"$'\tpresent'
  assert_contains "$out" $'item\tlocal\tallowed_signers\t'"$LOCAL_DIR/allowed_signers"$'\tpresent'
  assert_contains "$out" $'item\tlocal\tssh-agent-key.pub\t'"$LOCAL_DIR/ssh-agent-key.pub"$'\tabsent'
  assert_contains "$out" $'item\tgit-global\tgpg.ssh.allowedSignersFile\t'
  gpgconf() { printf '%s\n' "$*" >> "$temp/gpgconf-calls"; }
  out=$(DRY_RUN=1 remove_managed_blocks)
  assert_contains "$out" "Would remove the leos-profiles ssh-config block"
  assert_contains "$out" "Would remove the leos-profiles pinentry block"
  [[ ! -e $temp/gpgconf-calls ]] || fail "a dry run restarted gpg-agent"
  remove_managed_blocks >/dev/null
  cmp -s "$HOME/.ssh/config" "$temp/ssh-config.before" || fail "remove-blocks left ~/.ssh/config changed: $(cat "$HOME/.ssh/config")"
  cmp -s "$HOME/.gnupg/gpg-agent.conf" "$temp/gpg-agent.before" || fail "remove-blocks left gpg-agent.conf changed"
  assert_equals "$(cat "$temp/gpgconf-calls")" '--kill gpg-agent'
  rm -rf "$temp"
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
  test_no_os_release_upgrade_tooling
  test_download_verified_rejects_bad_digest
  test_macos_package_verification_detects_missing
  test_set_default_shell_auto_skips_existing_zsh
  test_set_default_shell_uses_unprivileged_chsh_on_linux
  test_set_default_shell_uses_sudo_chsh_on_macos
  test_known_hosts_matches_metadata_and_dedupes
  test_known_hosts_drops_stale_keys_and_keeps_a_symlink
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
  test_uv_artifact_installs_uv_and_uvx
  test_linux_artifacts_use_static_musl_builds
  test_apt_upgrade_keeps_local_configuration
  test_fedora_media_swaps_only_ffmpeg
  test_arch_installs_with_a_synced_database
  test_version_manager_extension_compile_is_best_effort
  test_nerd_font_rejects_unknown_names_before_downloading
  test_nerd_font_archive_is_verified_and_installed
  test_nerd_font_archive_digest_mismatch_fails
  test_node_lts_lookup_honours_the_dist_mirror
  test_sudo_keeps_proxy_variables
  test_brew_mirror_option_matches_the_runtime_mirror
  test_missing_chsh_queues_a_manual_action
  test_credentials_run_after_components
  test_credential_pause_reports_queued_component_actions
  test_preflight_without_terminal_stops_before_any_change
  test_preflight_accepts_passwordless_sudo_without_terminal
  test_preflight_asks_for_sudo_once_on_a_terminal
  test_preflight_needs_no_sudo_without_root_actions
  test_preflight_refuses_prompts_without_terminal
  test_existing_pyenv_is_reported_and_can_be_kept
  test_existing_setups_and_shadowed_artifacts_are_disclosed
  test_privileged_and_behaviour_records
  test_unsupported_macs_are_warned_about
  test_approved_node_version_is_enforced
  test_inspect_saved_uses_the_saved_selection
  test_inventory_lists_managed_items
  test_remove_blocks_and_inventory_need_no_supported_platform
  test_success_names_the_terminal_font_and_wsl_action
  test_gpg_expiry_validation
  test_preflight_refuses_a_second_gpg_generation
  test_profile_reads_optional_credential_keys
  test_signing_options_and_profile_compatibility
  test_inspect_discloses_signing_agent_and_pinentry
  test_remove_blocks_and_inventory_cover_credential_blocks
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
