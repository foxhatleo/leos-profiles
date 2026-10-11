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
  download_verified() {
    assert_equals "$1:$2" "https://example.invalid/starship.tar.gz:deadbeef"
    mkdir -p "$(dirname -- "$3")"; cp "$TEST_ARCHIVE" "$3"
  }
  install_archive_binary starship tar.gz https://example.invalid/starship.tar.gz deadbeef "$HOME/.local/bin/starship"
  [[ -x $HOME/.local/bin/starship ]] || fail "tar archive binary was not installed"
  rm -rf "$temp"
}

# uv's archive holds uv and uvx in a versioned directory: both are installed,
# verified and listed, from the registry alone.
test_uv_artifact_installs_uv_and_uvx() {
  local temp name
  temp=$(mktemp -d)
  mkdir -p "$temp/source/uv-aarch64-unknown-linux-musl" "$temp/home"
  for name in uv uvx; do
    printf '#!/bin/sh\nprintf "%%s %%s (fixture 2026-10-01)\\n" "%s" "0.9.1"\n' "$name" > "$temp/source/uv-aarch64-unknown-linux-musl/$name"
    chmod 755 "$temp/source/uv-aarch64-unknown-linux-musl/$name"
  done
  TEST_ARCHIVE="$temp/uv.tar.gz"
  tar -czf "$TEST_ARCHIVE" -C "$temp/source" uv-aarch64-unknown-linux-musl
  HOME="$temp/home"
  DRY_RUN=0
  OS_FAMILY=apt
  github_latest_asset() {
    assert_equals "$1 $2" "astral-sh/uv uv-aarch64-unknown-linux-musl.tar.gz"
    printf '0.9.1\thttps://github.com/astral-sh/uv/releases/download/0.9.1/%s\t%s\n' "$2" "$(printf x | hash_text)"
  }
  download_verified() { mkdir -p "$(dirname -- "$3")"; cp "$TEST_ARCHIVE" "$3"; }
  uname() { if [[ ${1:-} == -m ]]; then printf 'arm64\n'; else command uname "$@"; fi; }
  install_uv >/dev/null
  [[ -x $HOME/.local/bin/uv && -x $HOME/.local/bin/uvx ]] || fail "uv and uvx were not both installed"
  verify_step uv || fail "the installed uv did not verify"
  rm "$HOME/.local/bin/uvx"
  ! verify_step uv || fail "uv verified without uvx"
  assert_equals "$(artifact_release_asset uv)" $'astral-sh/uv\tuv-aarch64-unknown-linux-musl.tar.gz'
  OS_FAMILY=macos
  assert_equals "$(artifact_source uv)" formula
  assert_equals "$(artifact_path uv)" "$(brew_prefix)/bin/uv"
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
      assert_contains "$(artifact_release_asset "$tool")" $'\t'"$tool-$machine-unknown-linux-musl.tar.gz"
    done
  done
}

# Each artifact's source by platform: Homebrew's formula on macOS, the latest
# GitHub release on Linux (an asset per CPU, none for others), and the one
# pinned file everywhere. Only the pinned sources name a digest.
test_artifact_sources_follow_the_platform() {
  local name family
  uname() { if [[ ${1:-} == -m ]]; then printf '%s\n' "$FAKE_MACHINE"; else command uname "$@"; fi; }
  FAKE_MACHINE=x86_64
  for family in macos apt fedora arch; do
    OS_FAMILY=$family
    assert_equals "$(artifact_source rpatool)" pinned
    assert_equals "$(artifact_pinned_asset rpatool)" "$RPATOOL_URL"$'\t'"$RPATOOL_SHA256"
    for name in bun fnm starship uv; do
      if [[ $family == macos ]]; then
        assert_equals "$(artifact_source "$name")" formula
      else
        assert_equals "$(artifact_source "$name")" release
      fi
    done
  done
  OS_FAMILY=apt
  assert_equals "$(artifact_release_asset bun)" $'oven-sh/bun\tbun-linux-x64.zip'
  assert_equals "$(artifact_release_asset fnm)" $'Schniz/fnm\tfnm-linux.zip'
  FAKE_MACHINE=aarch64
  assert_equals "$(artifact_release_asset bun)" $'oven-sh/bun\tbun-linux-aarch64.zip'
  assert_equals "$(artifact_release_asset fnm)" $'Schniz/fnm\tfnm-arm64.zip'
  FAKE_MACHINE=riscv64
  ! artifact_release_asset bun >/dev/null || fail "an unsupported CPU resolved a release asset"
  [[ $RPATOOL_URL == https://raw.githubusercontent.com/Shizmob/rpatool/*/rpatool && $RPATOOL_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
    fail "rpatool is not pinned to a commit and digest"
  [[ $HOMEBREW_INSTALL_URL == https://raw.githubusercontent.com/Homebrew/install/*/install.sh && $HOMEBREW_INSTALL_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
    fail "Homebrew's installer is not pinned to a commit and digest"
  assert_equals "$(component_handler plugins artifacts)" starship
  assert_equals "$(component_handler zsh-config artifacts)" ""
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

test_default_font_policy_and_npm_tool_sources() {
  OS_FAMILY=macos
  INSTALL_FONTS=auto
  FONT_NAME=""
  font_should_install || fail "automatic font policy should install a font on desktop macOS"
  assert_equals "$(inspect_npm_tool yarn)" $'artifact\tformula\tyarn\tyarn\tlatest'
  OS_FAMILY=apt
  assert_equals "$(inspect_npm_tool pnpm)" $'artifact\tnpm\tpnpm\tregistry.npmjs.org/pnpm\tlatest'
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
  resolve_node_version
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
    # unzip is what install_archive_binary needs for bun and fnm on Linux.
    assert_contains "$out" "apt-get"
  fi
}

test_bootstrap_installs_unzip_when_missing() {
  local out
  OS_FAMILY=apt
  package_installed() { return 0; }
  DRY_RUN=1
  # unzip is in no package group, so the bootstrap is the only thing that can
  # provide it — and install_archive_binary needs it for bun and fnm on Linux.
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

# fixture_git <args...>: git with a fixture identity and none of the
# developer's configuration (signing, hooks, default branch).
fixture_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid command git "$@"
}

# fixture_commit <checkout> <message>: commit a change and print its hash.
fixture_commit() {
  printf '%s\n' "$2" >> "$1/history"
  fixture_git -C "$1" add history
  fixture_git -C "$1" commit -q -m "$2"
  fixture_git -C "$1" rev-parse HEAD
}

# Git sources follow their default branch: a missing checkout is cloned, a
# checkout detached at a pinned commit (installs before 2026-10) moves onto
# the branch, and an existing branch fast-forwards. Local bare repositories
# stand in for GitHub; the origin check compares their paths.
test_follow_default_branch_moves_detached_checkouts_onto_the_branch() {
  local temp upstream work first third head out
  temp=$(mktemp -d)
  upstream="$temp/upstream.git"
  work="$temp/work"
  git() { fixture_git "$@"; }
  github_origins_equivalent() { [[ $1 == "$2" ]]; }
  DRY_RUN=0
  fixture_git init -q --bare -b trunk "$upstream"
  fixture_git init -q -b trunk "$work"
  first=$(fixture_commit "$work" first)
  fixture_commit "$work" second >/dev/null
  fixture_git -C "$work" push -q "$upstream" trunk
  # A missing checkout is cloned onto the default branch.
  follow_default_branch "$upstream" "$temp/plugins/tool" tool >/dev/null
  assert_equals "$(git -C "$temp/plugins/tool" symbolic-ref --short HEAD)" trunk
  git_checkout_follows "$temp/plugins/tool" "$upstream" || fail "a fresh clone did not follow its default branch"
  # A pinned (detached) checkout is reported, then moved onto the branch.
  git -C "$temp/plugins/tool" checkout -q --detach "$first"
  ! git_checkout_follows "$temp/plugins/tool" "$upstream" || fail "a detached checkout was accepted"
  third=$(fixture_commit "$work" third)
  fixture_git -C "$work" push -q "$upstream" trunk
  out=$(follow_default_branch "$upstream" "$temp/plugins/tool" tool)
  assert_contains "$out" "checkout --quiet -B trunk origin/trunk"
  assert_equals "$(git -C "$temp/plugins/tool" symbolic-ref --short HEAD)" trunk
  assert_equals "$(git -C "$temp/plugins/tool" rev-parse HEAD)" "$third"
  git_checkout_follows "$temp/plugins/tool" "$upstream" || fail "the moved checkout did not follow its default branch"
  # On the branch: a new upstream commit fast-forwards it.
  head=$(fixture_commit "$work" fourth)
  fixture_git -C "$work" push -q "$upstream" trunk
  out=$(follow_default_branch "$upstream" "$temp/plugins/tool" tool)
  assert_contains "$out" "merge --quiet --ff-only origin/trunk"
  assert_equals "$(git -C "$temp/plugins/tool" rev-parse HEAD)" "$head"
  # A dry run fetches nothing.
  fixture_commit "$work" fifth >/dev/null
  fixture_git -C "$work" push -q "$upstream" trunk
  DRY_RUN=1
  out=$(follow_default_branch "$upstream" "$temp/plugins/tool" tool)
  assert_contains "$out" "Would fast-forward tool"
  assert_equals "$(git -C "$temp/plugins/tool" rev-parse HEAD)" "$head"
  DRY_RUN=0
  # Local work is never overwritten: uncommitted changes, or commits that
  # are not on the default branch, stop the step.
  printf 'local\n' >> "$temp/plugins/tool/history"
  out=$( (follow_default_branch "$upstream" "$temp/plugins/tool" tool) 2>&1 ) && fail "a dirty checkout was updated"
  assert_contains "$out" "tool checkout has local changes"
  git -C "$temp/plugins/tool" checkout -q -- history
  fixture_commit "$temp/plugins/tool" local >/dev/null
  out=$( (follow_default_branch "$upstream" "$temp/plugins/tool" tool) 2>&1 ) && fail "a diverged checkout was updated"
  assert_contains "$out" "tool has commits that are not on origin/trunk"
  # Anything else at the destination is refused.
  mkdir -p "$temp/plugins/plain"
  out=$( (follow_default_branch "$upstream" "$temp/plugins/plain" plain) 2>&1 ) && fail "a non-Git directory was taken over"
  assert_contains "$out" "plain exists but is not a Git checkout"
  rm -rf "$temp"
}

# git_checkout_follows: a clean checkout of the expected repository, on a
# branch. verify_pyenv uses it, so a pinned checkout is repaired by the step.
test_git_checkout_follows_rejects_detached_and_foreign_checkouts() {
  local temp first
  temp=$(mktemp -d)
  HOME="$temp/home"
  git() { fixture_git "$@"; }
  mkdir -p "$HOME"
  ! git_checkout_follows "$HOME/.pyenv" "$PYENV_REPOSITORY" || fail "a missing checkout was accepted"
  fixture_git init -q -b master "$HOME/.pyenv"
  mkdir -p "$HOME/.pyenv/bin"
  printf '#!/bin/sh\n' > "$HOME/.pyenv/bin/pyenv"
  chmod +x "$HOME/.pyenv/bin/pyenv"
  fixture_git -C "$HOME/.pyenv" add bin/pyenv
  fixture_git -C "$HOME/.pyenv" commit -q -m first
  first=$(fixture_commit "$HOME/.pyenv" second)
  ! git_checkout_follows "$HOME/.pyenv" "$PYENV_REPOSITORY" || fail "a checkout without an origin was accepted"
  git -C "$HOME/.pyenv" remote add origin git@github.com:PyEnv/pyenv.git
  git_checkout_follows "$HOME/.pyenv" "$PYENV_REPOSITORY" || fail "an equivalent origin on a branch was rejected"
  verify_pyenv || fail "verify_pyenv rejected a checkout on its branch"
  git -C "$HOME/.pyenv" checkout -q --detach "$first"
  ! git_checkout_follows "$HOME/.pyenv" "$PYENV_REPOSITORY" || fail "a detached HEAD was accepted"
  ! verify_pyenv || fail "verify_pyenv accepted a pinned (detached) checkout"
  OS_FAMILY=apt
  SELECTED_STEPS=pyenv
  TARGET="$temp/profile"
  assert_equals "$(report_tool_migrations)" $'migration\tgit-checkout\t'"$HOME/.pyenv"$'\tpyenv moves from a pinned commit to origin\'s default branch'
  git -C "$HOME/.pyenv" checkout -q master
  printf 'local\n' >> "$HOME/.pyenv/history"
  ! git_checkout_follows "$HOME/.pyenv" "$PYENV_REPOSITORY" || fail "a checkout with local changes was accepted"
  git -C "$HOME/.pyenv" checkout -q -- history
  git -C "$HOME/.pyenv" remote set-url origin https://github.com/example/not-pyenv.git
  ! git_checkout_follows "$HOME/.pyenv" "$PYENV_REPOSITORY" || fail "a checkout of another repository was accepted"
  rm -rf "$temp"
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
  resolve_node_version
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv25.0.0\tx\tx\tx\tx\tx\tx\tx\tx\t-\tfalse\nv24.2.0\tx\tx\tx\tx\tx\tx\tx\tx\tKrypton\tfalse\n'; }
  resolve_node_version
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  SELECTED_STEPS=fnm
  RESOLVED_NODE_VERSION=""
  # The newest LTS line, never a newer Current release.
  resolve_node_version
  assert_equals "$RESOLVED_NODE_VERSION:$NODE_SELECTION" v24.2.0:current-lts
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
    '  exec) [ "$2" = --using=default ] && printf "%s\\n" "${FAKE_NODE_VERSION:-v22.14.0}" ;;' \
    'esac' > "$HOME/.local/bin/fnm"
  chmod +x "$HOME/.local/bin/fnm"
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
  verify_step() { return 1; }
  output=$(inspect_tsv)
  assert_contains "$output" $'meta\tschema\t1'
  assert_contains "$output" $'group\tcomponent\tbun\tselected'
  assert_contains "$output" $'group\tcomponent\tpackages\timplied'
  assert_contains "$output" $'group\tpackage\tcore-utils\tselected'
  [[ $output != *$'group\tpackage\tlanguages'* ]] || fail "bun implied the languages group"
  assert_contains "$output" $'package\tmacos\tcoreutils'
  assert_contains "$output" $'artifact\tformula\tbun\tbun\tlatest'
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
  if resolve_node_version; then fail "resolve_node_version must return nonzero (not die) when unresolvable"; fi
  [[ -z $RESOLVED_NODE_VERSION ]] || fail "resolve_node_version set a version despite failing"
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

# A full upgrade re-runs every step that follows upstream even when it is
# recorded and verifies, so tools and checkouts move forward; the pinned file
# (bins), fonts and configuration stay as they are. A repair re-runs none.
test_full_upgrade_reruns_steps_that_follow_upstream() {
  local temp step out
  temp=$(mktemp -d)
  RUN_LOG="$temp/runs"
  : > "$RUN_LOG"
  DRY_RUN=1
  state_done() { return 0; }
  verify_step() { return 0; }
  component_handler() { printf 'record_step_run\n'; }
  record_step_run() { printf '%s\n' "$step" >> "$RUN_LOG"; }
  local -a steps=()
  csv_split steps "$CANONICAL_STEPS"
  FULL_UPGRADE=1
  for step in "${steps[@]}"; do
    out=$(run_step "$step" 2>&1)
    if step_follows_upstream "$step"; then
      assert_contains "$out" "Re-running $step (a full upgrade brings it up to date)"
    else
      assert_contains "$out" "Skipping $step (recorded complete and verified)"
    fi
  done
  assert_equals "$(paste -sd, - < "$RUN_LOG")" packages,pyenv,rbenv,bun,fnm,yarn,pnpm,uv,plugins
  : > "$RUN_LOG"
  FULL_UPGRADE=0
  for step in "${steps[@]}"; do run_step "$step" >/dev/null 2>&1; done
  [[ ! -s $RUN_LOG ]] || fail "a repair re-ran verified steps: $(paste -sd, - < "$RUN_LOG")"
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

# Signatures name where each component comes from, never a version: a new
# upstream release, or a new Node LTS, leaves recorded state valid, while a
# change of source (formula, release asset, pinned file) invalidates it.
test_artifact_signatures_name_the_source_not_a_version() {
  local family
  TARGET=/fixture/profile
  NODE_POLICY=current-lts
  uname() { if [[ ${1:-} == -m ]]; then printf '%s\n' "$FAKE_MACHINE"; else command uname "$@"; fi; }
  FAKE_MACHINE=arm64
  for family in macos apt fedora arch; do
    OS_FAMILY=$family
    assert_equals "$(signature_bins)" "|$RPATOOL_URL"$'\t'"$RPATOOL_SHA256"
  done
  OS_FAMILY=macos
  assert_equals "$(signature_bun)" '|formula|bun'
  assert_equals "$(signature_uv)" '|formula|uv'
  RESOLVED_NODE_VERSION=""
  assert_equals "$(signature_fnm)" '|formula|fnm|current-lts'
  RESOLVED_NODE_VERSION=v24.2.0
  assert_equals "$(signature_fnm)" '|formula|fnm|current-lts'
  assert_equals "$(signature_plugins)" "|$TARGET|formula|starship|$ZSH_AUTOSUGGESTIONS_REPOSITORY|$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY|$ZSH_COMPLETIONS_REPOSITORY|$FZF_TAB_REPOSITORY|default-branch"
  assert_equals "$(signature_pyenv)" "|$PYENV_REPOSITORY|default-branch"
  assert_equals "$(signature_rbenv)" "|$RBENV_REPOSITORY|$RUBY_BUILD_REPOSITORY|default-branch"
  OS_FAMILY=apt
  assert_equals "$(signature_bun)" $'|release|oven-sh/bun\tbun-linux-aarch64.zip'
  assert_equals "$(signature_fnm)" $'|release|Schniz/fnm\tfnm-arm64.zip|current-lts'
  FAKE_MACHINE=x86_64
  assert_equals "$(signature_uv)" $'|release|astral-sh/uv\tuv-x86_64-unknown-linux-musl.tar.gz'
  FAKE_MACHINE=riscv64
  assert_equals "$(signature_bun)" '|release|unsupported'
  # The step signature hashes that material, so it holds across versions too.
  FAKE_MACHINE=arm64
  RESOLVED_NODE_VERSION=v22.1.0
  local first
  first=$(step_signature fnm)
  RESOLVED_NODE_VERSION=v24.2.0
  assert_equals "$(step_signature fnm)" "$first"
  OS_FAMILY=macos
  [[ $(step_signature fnm) != "$first" ]] || fail "a change of source kept the fnm signature"
}

# Verification checks every executable the registry lists, and the version
# line (release artifacts, any version) or the digest (pinned files).
test_artifact_verification_checks_version_and_digest() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp"
  OS_FAMILY=apt
  mkdir -p "$HOME/.local/bin"
  fake_tool() { printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$HOME/.local/bin/$1"; chmod +x "$HOME/.local/bin/$1"; }
  ! artifact_verify bun || fail "a missing bun was accepted"
  fake_tool bun 1.3.0
  artifact_verify bun || fail "an installed bun was rejected"
  verify_step bun || fail "verify_bun disagrees with the registry"
  fake_tool bun 'error: not bun'
  ! artifact_verify bun || fail "an executable that reports no bun version was accepted"
  fake_tool starship "starship 1.23.0"
  artifact_verify starship || fail "an installed starship was rejected"
  fake_tool starship "starship"
  ! artifact_verify starship || fail "a starship that reports no version was accepted"
  fake_tool fnm "fnm 1.39.0"
  artifact_verify fnm || fail "an installed fnm was rejected"
  fake_tool uv "uv 0.9.1 (fixture 2026-10-01)"
  ! artifact_verify uv || fail "uv verified without uvx"
  fake_tool uvx "uvx 0.9.1 (fixture 2026-10-01)"
  artifact_verify uv || fail "an installed uv and uvx were rejected"
  printf 'rpatool body' > "$HOME/.local/bin/rpatool"
  chmod 700 "$HOME/.local/bin/rpatool"
  ! artifact_verify rpatool || fail "rpatool with the wrong digest was accepted"
  artifact_pinned_asset() { printf '%s\t%s\n' https://example.invalid/rpatool "$(printf 'rpatool body' | hash_text)"; }
  artifact_verify rpatool || fail "rpatool with the pinned digest was rejected"
  rm -rf "$temp"
}

# artifact_version_ok: with a version, exactly that one (build details may
# follow after a space); without one, any version in the registry's line.
test_artifact_version_ok_accepts_any_version_without_one() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp"
  mkdir -p "$HOME/.local/bin"
  fake_tool() { printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$HOME/.local/bin/$1"; chmod +x "$HOME/.local/bin/$1"; }
  fake_tool starship "starship 1.23.0"
  artifact_version_ok starship "$HOME/.local/bin/starship" || fail "any-version mode rejected starship 1.23.0"
  artifact_version_ok starship "$HOME/.local/bin/starship" 1.23.0 || fail "the exact version was rejected"
  ! artifact_version_ok starship "$HOME/.local/bin/starship" 1.23 || fail "a version prefix was accepted as the version"
  ! artifact_version_ok starship "$HOME/.local/bin/starship" 1.22.0 || fail "an older version was accepted as the given one"
  fake_tool starship "starship 1.23.09"
  ! artifact_version_ok starship "$HOME/.local/bin/starship" 1.23.0 || fail "a longer version string was accepted as the given one"
  fake_tool uv "uv 0.9.1 (fixture 2026-10-01)"
  artifact_version_ok uv "$HOME/.local/bin/uv" 0.9.1 || fail "build details after the version were rejected"
  artifact_version_ok uv "$HOME/.local/bin/uv" || fail "any-version mode rejected build details"
  fake_tool bun 1.3.0
  artifact_version_ok bun "$HOME/.local/bin/bun" || fail "any-version mode rejected a bare bun version"
  fake_tool bun "hello"
  ! artifact_version_ok bun "$HOME/.local/bin/bun" || fail "any-version mode accepted a line without a version"
  fake_tool fnm "starship 1.23.0"
  ! artifact_version_ok fnm "$HOME/.local/bin/fnm" || fail "another tool's version line was accepted"
  ! artifact_version_ok fnm "$HOME/.local/bin/missing" || fail "a missing executable was accepted"
  rm -rf "$temp"
}

# One artifact record per selected tool, naming its source: the formula on
# macOS, the GitHub release asset on Linux, the URL and digest of a pinned
# file, the default branch of a Git source and npm's latest release.
test_inspect_lists_every_selected_registry_artifact() {
  local output temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME"
  OS_FAMILY=macos
  SELECTED_STEPS=bins,bun,pyenv,yarn,plugins
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=""
  verify_step() { return 1; }
  output=$(inspect_tsv)
  assert_contains "$output" $'artifact\tdirect\trpatool\t'"$RPATOOL_URL"$'\t'"$RPATOOL_SHA256"
  assert_contains "$output" $'artifact\tformula\tbun\tbun\tlatest'
  assert_contains "$output" $'artifact\tformula\tstarship\tstarship\tlatest'
  assert_contains "$output" $'artifact\tformula\tyarn\tyarn\tlatest'
  assert_contains "$output" $'artifact\tgit\tpyenv\t'"$PYENV_REPOSITORY"$'\tdefault-branch'
  assert_contains "$output" $'artifact\tgit\tfzf-tab\t'"$FZF_TAB_REPOSITORY"$'\tdefault-branch'
  [[ $output != *$'\tfnm\t'* ]] || fail "an unselected artifact was listed"
  OS_FAMILY=apt
  uname() { if [[ ${1:-} == -m ]]; then printf 'aarch64\n'; else command uname "$@"; fi; }
  output=$(inspect_tsv)
  assert_contains "$output" $'artifact\tdirect\trpatool\t'"$RPATOOL_URL"$'\t'"$RPATOOL_SHA256"
  assert_contains "$output" $'artifact\trelease\tbun\tgithub.com/oven-sh/bun\tbun-linux-aarch64.zip'
  assert_contains "$output" $'artifact\trelease\tstarship\tgithub.com/starship/starship\tstarship-aarch64-unknown-linux-musl.tar.gz'
  assert_contains "$output" $'artifact\tnpm\tyarn\tregistry.npmjs.org/yarn\tlatest'
  [[ $output != *$'artifact\tformula\t'* ]] || fail "Linux listed a Homebrew formula"
  SELECTED_STEPS=fonts
  REQUESTED_STEPS=fonts
  INSTALL_FONTS=yes
  FONT_NAME=Fixture
  output=$(inspect_tsv)
  assert_contains "$output" $'artifact\trelease\tnerd-font\t'"$NERD_FONTS_RELEASE_URL/Fixture.tar.xz"$'\tSHA-256.txt'
  rm -rf "$temp"
}

# GitHub's release JSON, as the API serves it: the asset's name comes before
# the uploader object, its digest and its download URL. Its digest is null
# for assets uploaded before GitHub computed digests.
release_json_fixture() {
  cat <<'JSON'
{
  "url": "https://api.github.com/repos/fixture/tool/releases/1",
  "tag_name": "v1.4.2",
  "name": "Tool 1.4.2, with fixes",
  "author": { "login": "fixture", "id": 1, "type": "User" },
  "assets": [
    {
      "url": "https://api.github.com/repos/fixture/tool/releases/assets/10",
      "id": 10,
      "name": "tool-linux-x64.tar.gz",
      "label": "",
      "uploader": { "login": "fixture-bot", "id": 2, "type": "Bot", "site_admin": false },
      "content_type": "application/gzip",
      "state": "uploaded",
      "size": 1234,
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "download_count": 5,
      "browser_download_url": "https://github.com/fixture/tool/releases/download/v1.4.2/tool-linux-x64.tar.gz"
    },
    {
      "url": "https://api.github.com/repos/fixture/tool/releases/assets/11",
      "id": 11,
      "name": "tool-linux-arm64.tar.gz",
      "label": null,
      "uploader": { "login": "fixture-bot", "id": 2, "type": "Bot", "site_admin": false },
      "size": 1200,
      "digest": null,
      "browser_download_url": "https://github.com/fixture/tool/releases/download/v1.4.2/tool-linux-arm64.tar.gz"
    },
    {"url":"https://api.github.com/repos/fixture/tool/releases/assets/12","id":12,"name":"tool-sha512.tar.gz","uploader":{"login":"fixture-bot"},"digest":"sha512:abcd","browser_download_url":"https://github.com/fixture/tool/releases/download/v1.4.2/tool-sha512.tar.gz"},
    {"id":13,"name":"tool-mirror.tar.gz","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://mirror.example.invalid/tool-mirror.tar.gz"}
  ],
  "body": "Changes: faster, smaller."
}
JSON
}

test_github_release_asset_record_parses_release_json() {
  local a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  assert_equals "$(release_json_fixture | github_release_asset_record tool-linux-x64.tar.gz)" \
    $'v1.4.2\thttps://github.com/fixture/tool/releases/download/v1.4.2/tool-linux-x64.tar.gz\tsha256:'"$a"
  assert_equals "$(release_json_fixture | github_release_asset_record tool-linux-arm64.tar.gz)" \
    $'v1.4.2\thttps://github.com/fixture/tool/releases/download/v1.4.2/tool-linux-arm64.tar.gz\tnull'
  # Compact JSON (one line) parses the same.
  assert_equals "$(release_json_fixture | tr -d '\n' | github_release_asset_record tool-sha512.tar.gz)" \
    $'v1.4.2\thttps://github.com/fixture/tool/releases/download/v1.4.2/tool-sha512.tar.gz\tsha512:abcd'
  ! release_json_fixture | github_release_asset_record tool-linux-riscv64.tar.gz >/dev/null ||
    fail "an asset the release does not have produced a record"
  ! printf '{"message": "Not Found"}' | github_release_asset_record tool-linux-x64.tar.gz >/dev/null ||
    fail "an API error body produced a record"
}

# github_latest_asset fetches the latest release over HTTPS and accepts only
# a GitHub download with a SHA-256 digest; GITHUB_TOKEN, when set, is sent.
test_github_latest_asset_requires_a_sha256_digest() {
  local temp out a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  temp=$(mktemp -d)
  CURL_LOG="$temp/curl-argv"
  curl() { printf '<%s>' "$@" >> "$CURL_LOG"; printf '\n' >> "$CURL_LOG"; release_json_fixture; }
  unset GITHUB_TOKEN
  out=$(github_latest_asset fixture/tool tool-linux-x64.tar.gz) || fail "a published SHA-256 digest was refused"
  assert_equals "$out" $'v1.4.2\thttps://github.com/fixture/tool/releases/download/v1.4.2/tool-linux-x64.tar.gz\t'"$a"
  assert_contains "$(cat "$CURL_LOG")" '<--proto><=https><--tlsv1.2>'
  assert_contains "$(cat "$CURL_LOG")" '<https://api.github.com/repos/fixture/tool/releases/latest>'
  [[ $(cat "$CURL_LOG") != *Authorization* ]] || fail "an Authorization header was sent without GITHUB_TOKEN"
  : > "$CURL_LOG"
  GITHUB_TOKEN=fixture-token github_latest_asset fixture/tool tool-linux-x64.tar.gz >/dev/null
  assert_contains "$(cat "$CURL_LOG")" '<-H><Authorization: Bearer fixture-token>'
  out=$( (github_latest_asset fixture/tool tool-linux-arm64.tar.gz) 2>&1 ) && fail "an asset with a null digest was accepted"
  assert_contains "$out" "GitHub publishes no SHA-256 digest for tool-linux-arm64.tar.gz in fixture/tool v1.4.2"
  out=$( (github_latest_asset fixture/tool tool-sha512.tar.gz) 2>&1 ) && fail "a non-SHA-256 digest was accepted"
  assert_contains "$out" "no SHA-256 digest"
  out=$( (github_latest_asset fixture/tool tool-mirror.tar.gz) 2>&1 ) && fail "a download outside github.com was accepted"
  assert_contains "$out" "Unexpected download URL"
  out=$( (github_latest_asset fixture/tool tool-linux-riscv64.tar.gz) 2>&1 ) && fail "a missing asset was accepted"
  assert_contains "$out" "The latest fixture/tool release has no tool-linux-riscv64.tar.gz"
  curl() { return 22; }
  out=$( (github_latest_asset fixture/tool tool-linux-x64.tar.gz) 2>&1 ) && fail "an API failure was accepted"
  assert_contains "$out" "Could not read the latest fixture/tool release"
  rm -rf "$temp"
}

test_release_version_strips_the_tag_prefix() {
  assert_equals "$(release_version v1.39.0)" 1.39.0
  assert_equals "$(release_version bun-v1.3.0)" 1.3.0
  assert_equals "$(release_version 0.9.1)" 0.9.1
}

# A Linux release install downloads only when the installed version is not
# the latest release, and checks the result reports that version.
test_release_install_skips_the_installed_latest_version() {
  local temp out
  temp=$(mktemp -d)
  # The stubs read RELEASE_FIXTURE: install_archive_binary has a local $temp.
  RELEASE_FIXTURE=$temp
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin" "$temp/source"
  OS_FAMILY=apt
  DRY_RUN=0
  uname() { if [[ ${1:-} == -m ]]; then printf 'x86_64\n'; else command uname "$@"; fi; }
  github_latest_asset() {
    printf '%s %s\n' "$1" "$2" >> "$RELEASE_FIXTURE/latest.log"
    printf 'v1.23.0\thttps://github.com/starship/starship/releases/download/v1.23.0/%s\t%s\n' "$2" "$(printf x | hash_text)"
  }
  download_verified() {
    printf '%s %s\n' "$1" "$2" >> "$RELEASE_FIXTURE/download.log"
    mkdir -p "$(dirname -- "$3")"; cp "$RELEASE_FIXTURE/starship.tar.gz" "$3"
  }
  fake_starship() {
    printf '#!/bin/sh\nprintf "starship %s\\n"\n' "$2" > "$1"; chmod 755 "$1"
  }
  fake_starship "$temp/source/starship" 1.23.0
  tar -czf "$temp/starship.tar.gz" -C "$temp/source" starship
  # The latest version is installed: nothing is downloaded.
  fake_starship "$HOME/.local/bin/starship" 1.23.0
  out=$(artifact_install starship)
  assert_contains "$out" "starship 1.23.0 is the latest release and already installed"
  assert_equals "$(cat "$temp/latest.log")" "starship/starship starship-x86_64-unknown-linux-musl.tar.gz"
  [[ ! -e $temp/download.log ]] || fail "the installed latest release was downloaded again"
  # An older one is replaced with the verified latest.
  fake_starship "$HOME/.local/bin/starship" 1.22.0
  artifact_install starship >/dev/null
  assert_equals "$(cat "$temp/download.log")" "https://github.com/starship/starship/releases/download/v1.23.0/starship-x86_64-unknown-linux-musl.tar.gz $(printf x | hash_text)"
  assert_equals "$("$HOME/.local/bin/starship" --version)" "starship 1.23.0"
  # A download that does not report the release's version fails the install.
  fake_starship "$HOME/.local/bin/starship" 1.22.0
  fake_starship "$temp/source/starship" 1.21.0
  tar -czf "$temp/starship.tar.gz" -C "$temp/source" starship
  out=$( (artifact_install starship) 2>&1 ) && fail "a download reporting another version was accepted"
  assert_contains "$out" "starship does not report version 1.23.0 after installation"
  # Dry-run names the source and contacts nothing.
  : > "$temp/latest.log"
  DRY_RUN=1
  out=$(artifact_install starship)
  assert_contains "$out" "Would install the latest starship release (starship-x86_64-unknown-linux-musl.tar.gz from github.com/starship/starship)"
  [[ ! -s $temp/latest.log ]] || fail "a dry run asked GitHub for the latest release"
  # A CPU upstream publishes no build for stops with that reason.
  DRY_RUN=0
  uname() { if [[ ${1:-} == -m ]]; then printf 'riscv64\n'; else command uname "$@"; fi; }
  out=$( (artifact_install starship) 2>&1 ) && fail "an unsupported CPU installed starship"
  assert_contains "$out" "starship publishes no Linux build for riscv64"
  rm -rf "$temp"
}

# macOS takes the tools from Homebrew. Copies older installs left in
# ~/.local/bin (ahead of Homebrew on PATH) are removed once the formula is
# installed, but only files that report the tool's own version line.
test_macos_legacy_local_copies_are_removed_only_when_they_are_the_tool() {
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  HOMEBREW_PREFIX="$temp/brew"
  BREW_LOG="$temp/brew.log"
  TARGET="$temp/profile"
  mkdir -p "$HOME/.local/bin" "$HOMEBREW_PREFIX/bin"
  : > "$BREW_LOG"
  OS_FAMILY=macos
  DRY_RUN=0
  FULL_UPGRADE=0
  ensure_brew() { :; }
  brew() {
    local IFS=' '
    printf '%s\n' "$*" >> "$BREW_LOG"
    case $1 in
      list) cat "$temp/brew-installed" 2>/dev/null; return 0 ;;
      outdated) [[ -n ${BREW_OUTDATED:-} ]] && printf '%s\n' "$BREW_OUTDATED"; return 0 ;;
      install) printf '%s\n' "$2" >> "$temp/brew-installed" ;;
    esac
  }
  fake_tool() { printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$1"; chmod +x "$1"; }
  fake_tool "$HOME/.local/bin/uv" "uv 0.8.0 (legacy 2025-01-01)"
  fake_tool "$HOME/.local/bin/uvx" "uvx 0.8.0 (legacy 2025-01-01)"
  fake_tool "$HOME/.local/bin/starship" "my own starship wrapper"
  fake_tool "$HOMEBREW_PREFIX/bin/uv" "uv 0.9.1 (Homebrew 2026-10-01)"
  fake_tool "$HOMEBREW_PREFIX/bin/uvx" "uvx 0.9.1 (Homebrew 2026-10-01)"
  fake_tool "$HOMEBREW_PREFIX/bin/starship" "starship 1.23.0"
  printf 'uv\nstarship\n' > "$temp/brew-installed"
  assert_equals "$(legacy_local_copy uv)" "$HOME/.local/bin/uv"$'\n'"$HOME/.local/bin/uvx"
  assert_equals "$(legacy_local_copy starship)" ""
  assert_equals "$(legacy_local_copy rpatool)" ""
  ! artifact_verify uv || fail "uv verified with the legacy copy ahead of the formula"
  artifact_verify starship || fail "an unrelated ~/.local/bin/starship blocked the formula"
  SELECTED_STEPS=uv,plugins
  out=$(report_tool_migrations)
  assert_contains "$out" $'migration\tlocal-bin\t'"$HOME/.local/bin/uv"$'\tremoved: Homebrew\'s uv formula replaces it'
  assert_contains "$out" $'migration\tlocal-bin\t'"$HOME/.local/bin/uvx"$'\t'
  [[ $out != *starship* ]] || fail "an unrelated starship was reported as a legacy copy"
  artifact_install uv >/dev/null
  [[ ! -e $HOME/.local/bin/uv && ! -e $HOME/.local/bin/uvx ]] || fail "the legacy uv copy was left in front of the formula"
  ! grep -q '^install' "$BREW_LOG" || fail "an installed formula was installed again"
  artifact_verify uv || fail "uv did not verify after the legacy copy was removed"
  artifact_install starship >/dev/null
  [[ -x $HOME/.local/bin/starship ]] || fail "an unrelated ~/.local/bin/starship was removed"
  # Missing formulae are installed; a full upgrade upgrades outdated ones.
  artifact_install bun >/dev/null
  grep -qx 'install bun' "$BREW_LOG" || fail "a missing formula was not installed"
  FULL_UPGRADE=1
  : > "$BREW_LOG"
  artifact_install uv >/dev/null
  ! grep -q '^upgrade' "$BREW_LOG" || fail "an up-to-date formula was upgraded"
  BREW_OUTDATED=uv
  artifact_install uv >/dev/null
  grep -qx 'upgrade uv' "$BREW_LOG" || fail "a full upgrade did not upgrade an outdated formula"
  # Linux never treats ~/.local/bin as a legacy location: it is the install.
  OS_FAMILY=apt
  fake_tool "$HOME/.local/bin/uv" "uv 0.8.0"
  assert_equals "$(legacy_local_copy uv)" ""
  rm -rf "$temp"
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
  # The checksum list comes from the same (latest) release as the archive.
  assert_equals "$(cat "$temp/release/curl.log")" "https://example.invalid/release/SHA-256.txt"$'\n'"https://example.invalid/release/Fixture.tar.xz"
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
  resolve_node_version
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
  TARGET="$temp/profile"
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
  # macOS installs the Homebrew formula itself: nothing is shadowed.
  assert_equals "$(report_shadowed_artifacts)" ""
  # Linux: the release copy in ~/.local/bin shadows a Linuxbrew one.
  OS_FAMILY=apt
  out=$(report_shadowed_artifacts)
  assert_equals "$out" $'shadow\tstarship\t'"$HOMEBREW_PREFIX/bin/starship"$'\t'"$HOME/.local/bin/starship"
  SELECTED_STEPS=pyenv
  [[ -z $(report_shadowed_artifacts) ]] || fail "an unselected artifact was reported as shadowing"
  # macOS: an npm-prefix yarn from an older install is reported for removal.
  OS_FAMILY=macos
  SELECTED_STEPS=yarn,pnpm
  mkdir -p "$HOME/.local/npm/bin"
  printf '#!/bin/sh\n' > "$HOME/.local/npm/bin/yarn"
  assert_equals "$(report_tool_migrations)" $'migration\tnpm-prefix\t'"$HOME/.local/npm/bin/yarn"$'\tremoved: Homebrew\'s yarn formula replaces it'
  OS_FAMILY=apt
  assert_equals "$(report_tool_migrations)" ""
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
  # A Linux CPU upstream publishes no build for is a warning, not an inspect
  # failure. macOS takes the formula, whatever the CPU.
  SELECTED_STEPS=uv
  REQUESTED_STEPS=uv
  uname() { if [[ ${1:-} == -m ]]; then printf 'riscv64\n'; else command uname "$@"; fi; }
  verify_step() { return 1; }
  out=$(inspect_tsv) || fail "inspect failed without a uv build for this CPU"
  assert_contains "$out" $'warning\tno-release-build\tuv publishes no Linux build for riscv64; the uv component cannot be installed here'
  [[ $out != *$'artifact\trelease\tuv\t'* ]] || fail "a release asset was listed for an unsupported CPU"
  OS_FAMILY=macos
  out=$(inspect_tsv)
  assert_contains "$out" $'artifact\tformula\tuv\tuv\tlatest'
  [[ $out != *no-release-build* ]] || fail "macOS warned about a missing release build"
}

# --- --node-version (SEC-5) ------------------------------------------------
test_approved_node_version_is_enforced() {
  local out status=0
  SELECTED_STEPS=fnm
  resolve_node_version() {
    [[ -z $RESOLVED_NODE_VERSION ]] || return 0
    [[ -n $LIVE_LTS ]] || return 1
    RESOLVED_NODE_VERSION=$LIVE_LTS
    NODE_SELECTION=current-lts
  }
  node_default_kept() { [[ -n $KEPT_NODE ]] && printf '%s\n' "$KEPT_NODE"; }
  KEPT_NODE=""
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
  # A run that keeps the installed default compares that, not the live LTS.
  RESOLVED_NODE_VERSION=""
  LIVE_LTS=v24.12.0
  KEPT_NODE=v24.11.1
  check_approved_node_version || fail "the approved, kept default was refused"
  status=0
  KEPT_NODE=v22.20.0
  out=$( (check_approved_node_version) 2>&1 ) || status=$?
  assert_equals "$status" 2
  assert_contains "$out" "keeps the installed default v22.20.0"
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
  assert_contains "$out" $'policy\tnode\tcurrent-lts'
  assert_contains "$out" $'migration\tprofile-schema\t2\t3'
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
  test_artifact_sources_follow_the_platform
  test_package_maps_cover_every_supported_os
  test_default_font_policy_and_npm_tool_sources
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
  test_follow_default_branch_moves_detached_checkouts_onto_the_branch
  test_git_checkout_follows_rejects_detached_and_foreign_checkouts
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
  test_full_upgrade_reruns_steps_that_follow_upstream
  test_stale_lock_fails_closed_with_guidance
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
  test_artifact_signatures_name_the_source_not_a_version
  test_artifact_verification_checks_version_and_digest
  test_artifact_version_ok_accepts_any_version_without_one
  test_inspect_lists_every_selected_registry_artifact
  test_github_release_asset_record_parses_release_json
  test_github_latest_asset_requires_a_sha256_digest
  test_release_version_strips_the_tag_prefix
  test_release_install_skips_the_installed_latest_version
  test_macos_legacy_local_copies_are_removed_only_when_they_are_the_tool
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
