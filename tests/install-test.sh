#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317,SC2329

set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# Hermetic environment: the assertions below compare exact command lines and
# paths, so nothing from the developer's or runner's environment may steer
# them. The zsh-config tests resolve startup files from ZDOTDIR; proxy
# variables make run_root add `sudo --preserve-env=...` (one test sets one on
# purpose); XDG, tool-root, Homebrew and Git variables relocate or reconfigure
# what the installer inspects. Tests that need any of these set them locally.
unset ZDOTDIR
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY all_proxy
unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CURRENT_DESKTOP DISPLAY WAYLAND_DISPLAY
unset FNM_DIR FNM_NODE_DIST_MIRROR PYENV_ROOT RBENV_ROOT ASDF_DATA_DIR NVM_DIR ZSH ZSH_CUSTOM LEOS_PROFILES_HOME
unset HOMEBREW_PREFIX HOMEBREW_BREW_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN
unset GIT_CONFIG_GLOBAL GIT_CONFIG_COUNT GITHUB_TOKEN GH_TOKEN NERD_FONTS_TEST_RELEASE_URL
# shellcheck source=../install.sh
source "$ROOT/install.sh"
# The host's apt sources must not steer the GitHub CLI repository checks.
APT_ETC=/nonexistent/leos-test-apt

# No test reaches GitHub or reads the developer's gh login: the API token is
# never looked up, gh counts as logged out, and a curl no test stubs fails as
# if offline (inspect then reports releases as unresolved).
GITHUB_API_TOKEN_RESOLVED=1
GH_LOGGED_IN=no
curl() { printf '\n000'; return 7; }

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
  # shellcheck disable=SC2016  # expanded by zsh, not here
  assert_contains "$(< "$HOME/.zshenv")" '(( ${path[(Ie)$HOME/.local/bin]} )) || path=("$HOME/.local/bin" $path)'
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
  install_archive_binary starship tar.gz https://example.invalid/starship.tar.gz deadbeef "$HOME/.local/bin/starship" starship/starship
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
  github_release_pick() {
    assert_equals "$1 $2" "astral-sh/uv uv-aarch64-unknown-linux-musl.tar.gz"
    RELEASE_TAG=0.9.1
    RELEASE_PUBLISHED=2026-10-01T00:00:00Z
    RELEASE_URL="https://github.com/astral-sh/uv/releases/download/0.9.1/$2"
    RELEASE_SHA=$(printf x | hash_text)
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
  assert_equals "$(component_handler starship artifacts)" starship
  assert_equals "$(component_handler plugins artifacts)" ""
  assert_equals "$(component_handler zsh-config artifacts)" ""
}

test_package_maps_cover_every_supported_os() {
  local family group packages
  for family in macos apt fedora arch; do
    OS_FAMILY=$family
    for group in core-utils shell dev-tools python media network system; do
      packages=$(package_list_for_group "$group")
      [[ -n $packages ]] || fail "missing package mapping for $family/$group"
    done
    if [[ $family == macos ]]; then
      assert_equals "$(package_list_for_group heroku)" heroku
    else
      assert_equals "$(package_list_for_group heroku)" ""
    fi
    # Schema 4 retired the languages group on every family.
    assert_equals "$(package_list_for_group languages)" ""
    # No YouTube tooling in any group.
    for group in ${CANONICAL_GROUPS//,/ }; do
      [[ " $(package_list_for_group "$group") " != *" yt-dlp "* ]] || fail "$family/$group still installs yt-dlp"
    done
  done
  has_csv_item "$CANONICAL_GROUPS" languages && fail "languages is still a package group"
  has_csv_item "$RECOMMENDED_GROUPS" languages && fail "Recommended still selects languages"
  # A keg-only formula never reaches PATH; gnutls had no user in the profile.
  OS_FAMILY=macos
  assert_equals "$(package_list_for_group network)" "wget rclone"
  OS_FAMILY=apt
  assert_contains "$(package_list_for_group dev-tools)" "libssl-dev"
  # eza is not packaged on Debian 12 / Ubuntu 22.04, and the apt map covers both.
  [[ " $(package_list_for_group dev-tools) " != *" eza "* ]] || fail "apt dev-tools names eza, which Debian 12 and Ubuntu 22.04 lack"
  OS_FAMILY=fedora
  assert_contains "$(package_list_for_group dev-tools)" "openssl-devel"
  assert_contains " $(package_list_for_group dev-tools) " " eza "
  OS_FAMILY=macos
  assert_contains "$(package_list_for_group dev-tools)" "openssl@3"
}

# ONB-3: `rbenv install` compiles the newest Ruby: openssl, psych (libyaml),
# zlib and fiddle (libffi) extensions, GMP for fast Integer, autoconf and a C
# toolchain, and rustc for YJIT. dev-tools must carry each, per family (macOS
# uses the SDK's libffi). CPython comes prebuilt from uv, so the build
# dependencies only pyenv needed are gone, and Ruby 3.3+ needs no readline.
test_dev_tools_cover_ruby_build_dependencies() {
  local family requirement members python_only
  for family in macos apt fedora arch; do
    OS_FAMILY=$family
    members=" $(package_list_for_group dev-tools) "
    case $family in
      macos) requirement='openssl@3 zlib libyaml gmp autoconf rust'
        python_only='tcl-tk sqlite readline' ;;
      apt) requirement='libssl-dev zlib1g-dev libyaml-dev libffi-dev libgmp-dev autoconf rustc build-essential'
        python_only='clang llvm libbz2-dev liblzma-dev libncurses-dev libreadline-dev libsqlite3-dev libxml2-dev libxmlsec1-dev tk-dev' ;;
      fedora) requirement='openssl-devel zlib-devel libyaml-devel libffi-devel gmp-devel autoconf rust gcc make patch'
        python_only='bzip2-devel gdbm-libs libnsl2 libuuid-devel readline-devel sqlite-devel tk-devel xz-devel' ;;
      arch) requirement='openssl zlib libyaml libffi gmp rust base-devel'
        python_only='readline tk' ;;
    esac
    for requirement in $requirement; do
      [[ $members == *" $requirement "* ]] || fail "$family dev-tools lacks ruby-build dependency $requirement"
    done
    for requirement in $python_only; do
      [[ $members != *" $requirement "* ]] || fail "$family dev-tools still carries the Python-only build dependency $requirement"
    done
    # MI-8: GitHub CLI and jq.
    for requirement in jq "$( [[ $family == arch ]] && printf github-cli || printf gh)"; do
      [[ $members == *" $requirement "* ]] || fail "$family dev-tools lacks $requirement"
    done
  done
}

test_default_font_policy_and_npm_tool_sources() {
  local family
  OS_FAMILY=macos
  INSTALL_FONTS=auto
  FONT_NAME=""
  font_should_install || fail "automatic font policy should install a font on desktop macOS"
  # Corepack comes from npm on every OS (Homebrew's would pull in its node).
  for family in macos apt; do
    OS_FAMILY=$family
    assert_equals "$(inspect_corepack)" $'artifact\tnpm\tcorepack\tregistry.npmjs.org/corepack\tlatest\nartifact\tcorepack\tpnpm\tpnpm@latest\tlatest\nartifact\tcorepack\tyarn\tyarn@stable\tstable'
  done
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
    printf '%s\n' autoconf bat direnv eza fd fzf gh git gmp jq libyaml openssl@3 ripgrep rust vim xz zlib pkg-config
  }
  ensure_brew() { :; }
  out=$(install_os_packages 2>&1)
  assert_contains "$out" "+ brew install zoxide"
  [[ $out != *"brew install"*pkgconf* && $out != *"brew install"*rust* ]] ||
    fail "an installed formula or alias was requested again: $out"
  [[ $(grep -c '^list' "$BREW_CALLS_FILE") == 1 ]] || fail "brew list ran more than once: $(cat "$BREW_CALLS_FILE")"
  # A full upgrade requests everything without listing first.
  FULL_UPGRADE=1
  : > "$BREW_CALLS_FILE"
  out=$(install_os_packages 2>&1)
  assert_contains "$out" "+ brew install autoconf bat direnv"
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
  SELECTED_GROUPS='core-utils,python'
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
      printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv22.1.0\t2025-04-22\tx\tx\tx\tx\tx\tx\tx\tIron\tfalse\n'
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
  local temp owner err
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  LOCK_DIR="$LOCAL_DIR/.install.lock"
  DRY_RUN=0
  LOCK_HELD=0
  prepare_local_dir
  mkdir "$LOCK_DIR"
  # A live process running install.sh holds it.
  "$BASH" -c 'sleep 60; :' "$temp/install.sh" & owner=$!
  printf '%s\n' "$owner" > "$LOCK_DIR/pid"
  err=$( (acquire_lock) 2>&1 ) && { kill "$owner"; fail "concurrent live lock was accepted"; }
  kill "$owner" 2>/dev/null || true
  assert_contains "$err" "Another Leo's Profiles operation is running (PID $owner)"
  rm -rf "$temp"
}

# After an unclean exit the lock's PID can be reused by an unrelated process:
# that lock is stale, and the message says how to remove it.
test_lock_held_by_a_reused_pid_is_reported_stale() {
  local temp owner err
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  LOCK_DIR="$LOCAL_DIR/.install.lock"
  DRY_RUN=0
  LOCK_HELD=0
  prepare_local_dir
  mkdir "$LOCK_DIR"
  sleep 60 & owner=$!
  printf '%s\n' "$owner" > "$LOCK_DIR/pid"
  err=$( (acquire_lock) 2>&1 ) && { kill "$owner"; fail "a reused-PID lock was accepted"; }
  kill "$owner" 2>/dev/null || true
  assert_contains "$err" "looks stale"
  assert_contains "$err" "rm -rf -- '$LOCK_DIR'"
  [[ $err != *"operation is running"* ]] || fail "a reused PID was reported as a running operation: $err"
  [[ -d $LOCK_DIR ]] || fail "the stale lock was removed automatically"
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

# A fixed "now" for release-age tests: 2026-11-12T12:00:00Z.
FIXED_NOW=1794484800
fix_now() {
  current_epoch() { printf '%s\n' "$FIXED_NOW"; }
  RELEASE_CUTOFF_EPOCH=""
  RELEASE_CUTOFF_ISO=""
}

# dated_commit <checkout> <message> <days before FIXED_NOW> [tag]: commit
# (and tag, annotated) with backdated author, committer and tagger dates;
# print the commit.
dated_commit() {
  local date="@$(( FIXED_NOW - $3 * 86400 )) +0000"
  printf '%s\n' "$2" >> "$1/history"
  fixture_git -C "$1" add history
  GIT_AUTHOR_DATE=$date GIT_COMMITTER_DATE=$date fixture_git -C "$1" commit -q -m "$2"
  if [[ -n ${4:-} ]]; then GIT_COMMITTER_DATE=$date fixture_git -C "$1" tag -a -m "$4" "$4"; fi
  fixture_git -C "$1" rev-parse HEAD
}

# An upstream for follow_release_checkout, in FIXTURE_REPOSITORY (a local
# bare repository standing in for GitHub; the origin check compares paths):
#   C1  30 days old, v1.0.0      C4  3 days old, v1.2.0
#   C2  20 days old, v1.1.0      C5  1 day old, untagged
#   C3  10 days old, v1.2.0-rc1 and a lightweight 0.9.0-alpha1-pre
make_release_upstream() {
  local temp=$1
  FIXTURE_REPOSITORY="$temp/upstream.git"
  FIXTURE_WORK="$temp/work"
  fixture_git init -q --bare -b trunk "$FIXTURE_REPOSITORY"
  fixture_git init -q -b trunk "$FIXTURE_WORK"
  C1=$(dated_commit "$FIXTURE_WORK" first 30 v1.0.0)
  C2=$(dated_commit "$FIXTURE_WORK" second 20 v1.1.0)
  C3=$(dated_commit "$FIXTURE_WORK" third 10 v1.2.0-rc1)
  fixture_git -C "$FIXTURE_WORK" tag 0.9.0-alpha1-pre
  C4=$(dated_commit "$FIXTURE_WORK" fourth 3 v1.2.0)
  C5=$(dated_commit "$FIXTURE_WORK" fifth 1)
  fixture_git -C "$FIXTURE_WORK" push -q --tags "$FIXTURE_REPOSITORY" trunk
}

# Git sources end detached at the release their follow mode picks, at least
# MIN_RELEASE_AGE days old: the newest stable tag (`tag`; never an -rc or
# -pre tag), the newest default-branch commit (`commit`) or the newest stable
# tag with no delay (`tag-now`). A checkout on the branch (the 2026-10 layout)
# moves, backwards if need be.
test_follow_release_checkout_picks_by_mode_and_age() {
  local temp out checkout
  temp=$(mktemp -d)
  git() { fixture_git "$@"; }
  github_origins_equivalent() { [[ $1 == "$2" ]]; }
  fix_now
  DRY_RUN=0
  MIN_RELEASE_AGE=7
  make_release_upstream "$temp"
  checkout="$temp/plugins/tool"
  FIXTURE_FOLLOW=tag
  out=$(follow_release_checkout FIXTURE "$checkout" tool)
  assert_contains "$out" "tool is now at v1.1.0 (the newest stable tag at least 7 days old)"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$C2"
  ! git -C "$checkout" symbolic-ref --quiet HEAD >/dev/null || fail "the checkout was left on a branch"
  git_checkout_at_release "$checkout" "$FIXTURE_REPOSITORY" || fail "a checkout detached at its tag did not verify"
  out=$(follow_release_checkout FIXTURE "$checkout" tool)
  assert_contains "$out" "tool is at v1.1.0"
  [[ $out != *"checkout --quiet"* ]] || fail "a checkout at its release was checked out again"
  # A checkout on the default branch, at its head: moved back to the tag.
  git -C "$checkout" checkout -q -B trunk origin/trunk
  ! git_checkout_at_release "$checkout" "$FIXTURE_REPOSITORY" || fail "a checkout on a branch verified"
  out=$(follow_release_checkout FIXTURE "$checkout" tool)
  assert_contains "$out" "checkout --quiet --detach $C2"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$C2"
  # commit: the newest default-branch commit old enough, tagged or not.
  FIXTURE_FOLLOW=commit
  out=$(follow_release_checkout FIXTURE "$checkout" tool)
  assert_contains "$out" "tool is now at $(git -C "$checkout" rev-parse --short "$C3") (the newest default-branch commit at least 7 days old)"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$C3"
  # tag-now: the newest stable tag, however new.
  FIXTURE_FOLLOW='tag-now'
  follow_release_checkout FIXTURE "$checkout" tool >/dev/null
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$C4"
  # A shorter age admits newer releases; one longer than every release finds
  # nothing and stops.
  FIXTURE_FOLLOW=tag
  MIN_RELEASE_AGE=0
  fix_now
  follow_release_checkout FIXTURE "$checkout" tool >/dev/null
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$C4"
  MIN_RELEASE_AGE=40
  fix_now
  out=$( (follow_release_checkout FIXTURE "$checkout" tool) 2>&1 ) && fail "a checkout with no release old enough passed"
  assert_contains "$out" "has nothing to check out as the newest stable tag at least 40 days old"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$C4"
  # A fresh clone in dry-run is only described.
  MIN_RELEASE_AGE=7
  fix_now
  DRY_RUN=1
  out=$(follow_release_checkout FIXTURE "$temp/plugins/new" tool)
  assert_contains "$out" "Would clone tool from $FIXTURE_REPOSITORY and check out the newest stable tag at least 7 days old"
  [[ ! -e $temp/plugins/new ]] || fail "a dry run cloned"
  rm -rf "$temp"
}

# Local work is never thrown away: uncommitted changes, or a checked-out
# commit origin never had, stop the step with nothing changed. A force-push
# upstream is not local work: the checkout moves on, and says why.
test_follow_release_checkout_protects_local_work() {
  local temp out checkout head rewritten
  temp=$(mktemp -d)
  git() { fixture_git "$@"; }
  github_origins_equivalent() { [[ $1 == "$2" ]]; }
  fix_now
  DRY_RUN=0
  MIN_RELEASE_AGE=0
  make_release_upstream "$temp"
  checkout="$temp/plugins/tool"
  FIXTURE_FOLLOW=commit
  follow_release_checkout FIXTURE "$checkout" tool >/dev/null
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$C5"
  printf 'local\n' >> "$checkout/history"
  out=$( (follow_release_checkout FIXTURE "$checkout" tool) 2>&1 ) && fail "a dirty checkout was updated"
  assert_contains "$out" "tool checkout has local changes"
  git -C "$checkout" checkout -q -- history
  head=$(fixture_commit "$checkout" local)
  out=$( (follow_release_checkout FIXTURE "$checkout" tool) 2>&1 ) && fail "a checkout with a local commit was moved"
  assert_contains "$out" "tool has commits that are not on $FIXTURE_REPOSITORY"
  assert_contains "$out" "$head"
  [[ $out != *rewrote* ]] || fail "a local commit was blamed on upstream: $out"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$head"
  # The dry run reports it too.
  out=$( (DRY_RUN=1; follow_release_checkout FIXTURE "$checkout" tool) 2>&1 ) && fail "a dry run accepted a local commit"
  assert_contains "$out" "tool has commits that are not on"
  git -C "$checkout" checkout -q --detach "$C5"
  # Upstream force-pushes C5 away: the checkout held only origin's commits,
  # so it moves to the new head and says upstream rewrote its history.
  fixture_git -C "$FIXTURE_WORK" reset -q --hard "$C4"
  rewritten=$(dated_commit "$FIXTURE_WORK" rewritten 1)
  fixture_git -C "$FIXTURE_WORK" push -q --force "$FIXTURE_REPOSITORY" trunk
  out=$(follow_release_checkout FIXTURE "$checkout" tool)
  assert_contains "$out" "tool's upstream rewrote its history (a force-push)"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$rewritten"
  # A dry run fetches nothing.
  dated_commit "$FIXTURE_WORK" sixth 0 >/dev/null
  fixture_git -C "$FIXTURE_WORK" push -q "$FIXTURE_REPOSITORY" trunk
  DRY_RUN=1
  out=$(follow_release_checkout FIXTURE "$checkout" tool)
  assert_contains "$out" "Would fetch tool and check out the newest default-branch commit at least 0 days old"
  assert_equals "$(git -C "$checkout" rev-parse HEAD)" "$rewritten"
  DRY_RUN=0
  # Anything else at the destination is refused.
  mkdir -p "$temp/plugins/plain"
  out=$( (follow_release_checkout FIXTURE "$temp/plugins/plain" plain) 2>&1 ) && fail "a non-Git directory was taken over"
  assert_contains "$out" "plain exists but is not a Git checkout"
  rm -rf "$temp"
}

# Every Git source has a follow mode, and the modes are the ones chosen:
# commits for the two plugins whose tags lag years behind, ruby-build's
# definitions without delay.
test_git_sources_have_follow_modes() {
  assert_equals "$RBENV_FOLLOW $RUBY_BUILD_FOLLOW" "tag tag-now"
  assert_equals "$ZSH_AUTOSUGGESTIONS_FOLLOW $ZSH_SYNTAX_HIGHLIGHTING_FOLLOW" "commit commit"
  assert_equals "$ZSH_COMPLETIONS_FOLLOW $FZF_TAB_FOLLOW" "tag tag"
  local tag
  for tag in v1.2.3 0.36.0 v20261023 1; do
    [[ $tag =~ $STABLE_TAG_PATTERN ]] || fail "stable tag $tag was rejected"
  done
  for tag in 0.8.0-alpha1-pre-redrawhook v1.2.0-rc1 1.0-pre v1.2. latest; do
    [[ ! $tag =~ $STABLE_TAG_PATTERN ]] || fail "unstable tag $tag was accepted"
  done
}

# git_checkout_at_release: a clean, detached checkout of the expected
# repository. verify_rbenv uses it, so a checkout left on a branch (the
# 2026-10 layout) is moved by the step, and inspect reports the move.
test_git_checkout_at_release_rejects_branch_and_foreign_checkouts() {
  local temp first
  temp=$(mktemp -d)
  HOME="$temp/home"
  git() { fixture_git "$@"; }
  fix_now
  MIN_RELEASE_AGE=7
  mkdir -p "$HOME"
  ! git_checkout_at_release "$HOME/.rbenv" "$RBENV_REPOSITORY" || fail "a missing checkout was accepted"
  fixture_git init -q -b master "$HOME/.rbenv"
  mkdir -p "$HOME/.rbenv/bin"
  printf '#!/bin/sh\n' > "$HOME/.rbenv/bin/rbenv"
  chmod +x "$HOME/.rbenv/bin/rbenv"
  fixture_git -C "$HOME/.rbenv" add bin/rbenv
  fixture_git -C "$HOME/.rbenv" commit -q -m first
  first=$(dated_commit "$HOME/.rbenv" second 30 v2.8.0)
  dated_commit "$HOME/.rbenv" third 2 v2.8.1 >/dev/null
  git -C "$HOME/.rbenv" checkout -q --detach "$first"
  ! git_checkout_at_release "$HOME/.rbenv" "$RBENV_REPOSITORY" || fail "a checkout without an origin was accepted"
  git -C "$HOME/.rbenv" remote add origin git@github.com:RbEnv/rbenv.git
  git_checkout_at_release "$HOME/.rbenv" "$RBENV_REPOSITORY" || fail "a detached checkout of an equivalent origin was rejected"
  OS_FAMILY=apt
  SELECTED_STEPS=rbenv
  TARGET="$temp/profile"
  assert_equals "$(report_tool_migrations)" ""
  git -C "$HOME/.rbenv" checkout -q master
  ! git_checkout_at_release "$HOME/.rbenv" "$RBENV_REPOSITORY" || fail "a checkout on a branch was accepted"
  assert_equals "$(report_tool_migrations)" $'migration\tgit-checkout\t'"$HOME/.rbenv"$'\trbenv moves from origin\'s default branch to tag v2.8.0 (the newest stable tag at least 7 days old), detached'
  git -C "$HOME/.rbenv" checkout -q --detach "$first"
  printf 'local\n' >> "$HOME/.rbenv/history"
  ! git_checkout_at_release "$HOME/.rbenv" "$RBENV_REPOSITORY" || fail "a checkout with local changes was accepted"
  git -C "$HOME/.rbenv" checkout -q -- history
  git -C "$HOME/.rbenv" remote set-url origin https://github.com/example/not-rbenv.git
  ! git_checkout_at_release "$HOME/.rbenv" "$RBENV_REPOSITORY" || fail "a checkout of another repository was accepted"
  rm -rf "$temp"
}

test_recommended_and_whole_group_closure() {
  [[ $SELECTED_STEPS == 'packages,rbenv,bun,fnm,corepack,uv,cpython,starship,plugins,fonts,zsh-config,default-shell' ]] || fail "Recommended components changed"
  [[ $SELECTED_GROUPS == 'core-utils,shell,dev-tools,media,network,system' ]] || fail "Recommended package groups changed"
  # MI-4: the Node, Python and Bun tools bring no OS runtimes.
  SELECTED_STEPS=bun,corepack,cpython,starship
  SELECTED_GROUPS=""
  normalise_dependencies
  order_selected_steps
  assert_equals "$SELECTED_STEPS" packages,bun,fnm,corepack,uv,cpython,starship
  assert_equals "$SELECTED_GROUPS" ""
  # Ruby compiles against dev-tools.
  SELECTED_STEPS=rbenv
  normalise_dependencies
  assert_equals "$SELECTED_GROUPS" dev-tools
  SELECTED_GROUPS=""
  # rpatool needs the OS python3 and nothing else.
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
  # heroku is a homebrew/core formula: no third-party tap is added.
  [[ $out != *"brew tap"* ]] || fail "the heroku group still adds a Homebrew tap: $out"
  assert_contains "$out" "+ brew install wget rclone heroku"
  SELECTED_STEPS=packages
  REQUESTED_STEPS=packages
  REQUESTED_GROUPS=$SELECTED_GROUPS
  verify_step() { return 1; }
  assert_contains "$(inspect_tsv)" $'package\tmacos\theroku'
  [[ $(inspect_tsv) != *heroku/brew* ]] || fail "inspect still discloses the heroku/brew tap"
  SELECTED_GROUPS=network
  [[ $(inspect_tsv) != *heroku* ]] || fail "inspect lists heroku without the heroku group"
}

test_node_lts_is_resolved_once_per_run() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin"
  curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv22.1.0\t2025-04-22\tx\tx\tx\tx\tx\tx\tx\tIron\tfalse\n'; }
  SELECTED_STEPS=fnm
  RESOLVED_NODE_VERSION=""
  resolve_node_version
  assert_equals "$RESOLVED_NODE_VERSION" v22.1.0
  curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\nv25.0.0\t2025-10-01\tx\tx\tx\tx\tx\tx\tx\t-\tfalse\nv24.2.0\t2025-10-28\tx\tx\tx\tx\tx\tx\tx\tKrypton\tfalse\n'; }
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
  assert_equals "$(paste -sd, - < "$RUN_LOG")" packages,rbenv,bun,fnm,corepack,uv,cpython,starship,plugins
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

# Linux changes the login shell as root, like macOS: chsh run as the user
# would ask for the user's own password, which no unattended run can answer.
test_set_default_shell_uses_sudo_chsh_on_linux() {
  CHANGE_DEFAULT_SHELL=yes
  DRY_RUN=1
  OS_FAMILY=apt
  SUDO=sudo
  current_login_shell() { printf '%s\n' /bin/bash; }
  local out
  out=$(set_default_shell 2>&1)
  assert_contains "$out" "sudo chsh -s "
  assert_contains "$out" " $(id -un)"
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

# .zshenv runs in every zsh, so in a child shell it must not move ~/.local/bin
# back in front of the version-manager shims the parent's profile put first.
test_zshenv_block_prepends_only_missing_local_bins() {
  local temp
  command -v zsh >/dev/null 2>&1 || return 0
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME"
  install_zsh_config
  # A fresh login environment: both, in this order, ahead of the system.
  # shellcheck disable=SC2016  # expanded by zsh, not here
  assert_equals "$(HOME="$HOME" zsh -fc 'path=(/usr/bin /bin); source ~/.zshenv; print -r -- $PATH')" \
    "$HOME/.local/bin:$HOME/.local/npm/bin:/usr/bin:/bin"
  # Inherited from a profile shell: left exactly as it is.
  # shellcheck disable=SC2016
  assert_equals "$(HOME="$HOME" zsh -fc 'path=("$HOME/.pyenv/shims" "$HOME/.local/bin" "$HOME/.local/npm/bin" /usr/bin); source ~/.zshenv; print -r -- $PATH')" \
    "$HOME/.pyenv/shims:$HOME/.local/bin:$HOME/.local/npm/bin:/usr/bin"
  # Root with someone else's HOME (`sudo -s`): nothing user-writable is added,
  # but Debian's global compinit is still skipped.
  if [[ $(id -u) == 0 ]] && chown 65534 "$HOME" 2>/dev/null; then
    # shellcheck disable=SC2016
    assert_equals "$(HOME="$HOME" zsh -fc 'path=(/usr/bin /bin); source ~/.zshenv; print -r -- $PATH ${skip_global_compinit-unset}')" \
      "/usr/bin:/bin 1"
  fi
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
  SELECTED_STEPS=packages
  SELECTED_GROUPS=shell,system
  # Newline-joined, as recorded by earlier versions, whatever IFS the caller has.
  expected=$'|shell,system|zsh\nsmartmontools'
  assert_equals "$(signature_packages)" "$expected"
  assert_equals "$(IFS=,; signature_packages)" "$expected"
  assert_equals "$(IFS=$'\n\t'; signature_packages)" "$expected"
  assert_equals "$(IFS=' '; step_signature packages)" "$(step_signature packages)"
}

# Official Node binaries for Linux link libatomic; selecting fnm adds the
# package on the families whose minimal images lack it, and only there.
test_fnm_pulls_libatomic_where_needed() {
  SELECTED_GROUPS=""
  SELECTED_STEPS=packages,fnm
  OS_FAMILY=apt; collect_selected_packages
  assert_equals "${SELECTED_PACKAGES[*]-}" libatomic1
  OS_FAMILY=fedora; collect_selected_packages
  assert_equals "${SELECTED_PACKAGES[*]-}" libatomic
  OS_FAMILY=arch; collect_selected_packages
  assert_equals "${SELECTED_PACKAGES[*]-}" ""
  OS_FAMILY=apt; SELECTED_STEPS=packages; collect_selected_packages
  assert_equals "${SELECTED_PACKAGES[*]-}" ""
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
  assert_contains "$out" "+ sudo dnf install -y ImageMagick "
  assert_contains "$out" "+ sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing"
  [[ $(grep -c -- --allowerasing <<< "$out") == 1 ]] || fail "--allowerasing reached another command: $out"
  SELECTED_GROUPS=core-utils
  out=$(install_os_packages)
  [[ $out != *rpmfusion* && $out != *swap* && $out != *allowerasing* ]] || fail "a non-media install touched RPM Fusion: $out"
  # No ffmpeg-free, but Fedora's split -free libraries may still be present as
  # other packages' dependencies: the plain install replaces them, scoped.
  DRY_RUN=0
  run_root() { printf '+ %s\n' "$*"; }
  pkg_install() { printf '+ pkg_install %s\n' "$*"; }
  out=$(fedora_install_media ImageMagick ffmpeg)
  assert_contains "$out" "+ dnf install -y --allowerasing ffmpeg"
  [[ $(grep -c -- --allowerasing <<< "$out") == 1 ]] || fail "--allowerasing reached another command: $out"
}

# Debian/Ubuntu dev-tools take gh from GitHub CLI's apt repository: the
# pinned keyring and the source line are installed as root before apt's index
# refresh, disclosed in the plan, and never added twice.
test_apt_dev_tools_add_the_github_cli_repository() {
  local temp out keyring list
  temp=$(mktemp -d)
  OS_FAMILY=apt
  DRY_RUN=1
  SUDO=sudo
  FULL_UPGRADE=0
  APT_ETC="$temp/etc/apt"
  keyring="$APT_ETC/keyrings/githubcli-archive-keyring.gpg"
  list="$APT_ETC/sources.list.d/github-cli.list"
  mkdir -p "$APT_ETC/sources.list.d"
  dpkg() { [[ $* == --print-architecture ]] && printf 'arm64\n'; }
  package_installed() { return 1; }
  ensure_sudo() { :; }
  apt_compat_links() { :; }
  SELECTED_STEPS=packages
  SELECTED_GROUPS=dev-tools
  # The bootstrap already refreshed the index; the new repository needs another.
  APT_INDEX_UPDATED=1
  out=$(install_os_packages)
  assert_contains "$out" "Would download and SHA-256 verify https://cli.github.com/packages/githubcli-archive-keyring.gpg"
  assert_contains "$out" "+ sudo install -d -m 755 $APT_ETC/keyrings $APT_ETC/sources.list.d"
  assert_contains "$out" "+ sudo install -m 644 "
  assert_contains "$out" " $keyring "
  assert_contains "$out" " $list "
  [[ $(grep -n "github-cli.list" <<< "$out" | head -1 | cut -d: -f1) -lt $(grep -n "apt-get update" <<< "$out" | cut -d: -f1) ]] ||
    fail "the GitHub CLI repository was not added before apt's index refresh: $out"
  [[ $(grep -n "apt-get update" <<< "$out" | cut -d: -f1) -lt $(grep -n "install -y" <<< "$out" | cut -d: -f1) ]] ||
    fail "apt installed before refreshing the index: $out"
  assert_contains "$(privileged_plan)" $'repository\tsudo install of GitHub CLI\'s apt keyring ('"$keyring"') and source list ('"$list"')'
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=$SELECTED_GROUPS
  verify_step() { return 1; }
  out=$(inspect_tsv)
  assert_contains "$out" $'action\trepository\tGitHub CLI apt repository'
  assert_contains "$out" $'artifact\tdirect\tgithub-cli-keyring\thttps://cli.github.com/packages/githubcli-archive-keyring.gpg\t'"$GH_APT_KEYRING_SHA256"
  assert_contains "$out" $'behaviour\tgithub-cli-apt\t'
  # Without dev-tools, nothing about it.
  SELECTED_GROUPS=shell
  out=$(install_os_packages)
  [[ $out != *cli.github.com* && $out != *github-cli* ]] || fail "a dev-tools-free install touched the GitHub CLI repository: $out"
  [[ $(privileged_plan) != *GitHub* ]] || fail "a dev-tools-free plan discloses the GitHub CLI repository"
  # A real run, as root: the keyring (mode 644) and the exact source line.
  SELECTED_GROUPS=dev-tools
  DRY_RUN=0
  SUDO=""
  FIXTURE_KEYRING="$temp/keyring.gpg"
  printf 'fixture keyring' > "$FIXTURE_KEYRING"
  GH_APT_KEYRING_SHA256=$(sha256 "$FIXTURE_KEYRING")
  # ensure_gh_apt_repository has its own local $temp.
  download_verified() { cp "$FIXTURE_KEYRING" "$3"; }
  ensure_gh_apt_repository >/dev/null
  assert_equals "$(cat "$list")" "deb [arch=arm64 signed-by=$keyring] https://cli.github.com/packages stable main"
  assert_equals "$(cat "$keyring")" "fixture keyring"
  assert_equals "$(file_mode "$keyring")" 644
  assert_equals "$(file_mode "$list")" 644
  assert_equals "$APT_INDEX_UPDATED" 0
  # Idempotent: the same setup is left alone, in the plan and in a run.
  assert_equals "$(gh_apt_repository_state)" configured
  download_verified() { fail "downloaded the keyring for a configured repository"; }
  APT_INDEX_UPDATED=1
  out=$(ensure_gh_apt_repository)
  assert_equals "$out" ""
  DRY_RUN=1
  SUDO=sudo
  out=$(install_os_packages)
  [[ $out != *github-cli* ]] || fail "a configured repository was added again: $out"
  [[ $(privileged_plan) != *GitHub* ]] || fail "a configured repository is still a planned root action"
  # A stale line (an older signed-by path) is replaced.
  printf 'deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' > "$list"
  assert_equals "$(gh_apt_repository_state)" missing
  # Another source for the same repository (here deb822) stays the only one.
  rm -f "$list"
  printf 'Types: deb\nURIs: https://cli.github.com/packages\nSuites: stable\n' > "$APT_ETC/sources.list.d/gh.sources"
  assert_equals "$(gh_apt_repository_state)" other
  out=$(install_os_packages)
  [[ $out != *github-cli* ]] || fail "a second GitHub CLI source was added next to an existing one: $out"
  rm -rf "$temp"
}

# Debian 12 / Ubuntu 22.04 package zoxide 0.4.3: inspect warns in one line,
# only for an apt candidate before 0.8 and only when no other zoxide is on PATH.
test_old_apt_zoxide_is_warned_about() {
  local out
  OS_FAMILY=apt
  SELECTED_STEPS=packages
  SELECTED_GROUPS=dev-tools
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=$SELECTED_GROUPS
  apt-cache() { printf 'zoxide:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' "$FAKE_CANDIDATE"; }
  zoxide_on_path() { [[ -n $FAKE_ZOXIDE ]] && printf '%s\n' "$FAKE_ZOXIDE"; }
  FAKE_ZOXIDE=""
  FAKE_CANDIDATE=0.4.3-5
  out=$(apt_zoxide_outdated) || fail "zoxide 0.4.3 was not reported"
  assert_contains "$out" "zoxide 0.4.3-5 predates 0.8"
  # The distribution's own copy, once installed, is still the old one.
  FAKE_ZOXIDE=/usr/bin/zoxide
  apt_zoxide_outdated >/dev/null || fail "an installed zoxide 0.4.3 was not reported"
  verify_step() { return 1; }
  dpkg() { printf 'amd64\n'; }
  assert_contains "$(inspect_tsv)" $'warning\tzoxide-outdated\tapt\'s zoxide 0.4.3-5 predates 0.8'
  for FAKE_CANDIDATE in 0.9.3-1 1:0.8.0-1 '(none)' ''; do
    ! apt_zoxide_outdated >/dev/null || fail "zoxide '$FAKE_CANDIDATE' was reported as outdated"
  done
  FAKE_CANDIDATE=0.4.3-5
  # The user's own zoxide on PATH wins over the package.
  FAKE_ZOXIDE=$HOME/.local/bin/zoxide
  ! apt_zoxide_outdated >/dev/null || fail "a zoxide outside the package was reported"
  # Other families and selections never look.
  FAKE_ZOXIDE=""
  SELECTED_GROUPS=shell
  ! apt_zoxide_outdated >/dev/null || fail "zoxide was reported without dev-tools"
  OS_FAMILY=fedora
  SELECTED_GROUPS=dev-tools
  ! apt_zoxide_outdated >/dev/null || fail "zoxide was reported on Fedora"
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
  assert_equals "$(signature_starship)" '|formula|starship'
  assert_equals "$(signature_plugins)" "|$TARGET|$ZSH_AUTOSUGGESTIONS_REPOSITORY|$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY|$ZSH_COMPLETIONS_REPOSITORY|$FZF_TAB_REPOSITORY|release"
  assert_equals "$(signature_rbenv)" "|$RBENV_REPOSITORY|$RUBY_BUILD_REPOSITORY|release|ruby-latest-stable"
  assert_equals "$(signature_cpython)" "|uv-python|latest-stable|$HOME/.local/bin"
  assert_equals "$(signature_corepack)" "|npm|corepack@latest|$HOME/.local/npm|pnpm@latest yarn@stable"
  # Nor the minimum release age: changing it re-runs nothing.
  local before
  before=$(step_signature plugins)
  MIN_RELEASE_AGE=30
  assert_equals "$(step_signature plugins)" "$before"
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
  SELECTED_STEPS=bins,bun,corepack,starship,plugins
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=""
  verify_step() { return 1; }
  output=$(inspect_tsv)
  assert_contains "$output" $'artifact\tdirect\trpatool\t'"$RPATOOL_URL"$'\t'"$RPATOOL_SHA256"
  assert_contains "$output" $'artifact\tformula\tbun\tbun\tlatest'
  assert_contains "$output" $'artifact\tformula\tstarship\tstarship\tlatest'
  assert_contains "$output" $'artifact\tnpm\tcorepack\tregistry.npmjs.org/corepack\tlatest'
  assert_contains "$output" $'artifact\tcorepack\tyarn\tyarn@stable\tstable'
  assert_contains "$output" $'artifact\tgit\tfzf-tab\t'"$FZF_TAB_REPOSITORY"$'\ttag'
  assert_contains "$output" $'artifact\tgit\tzsh-autosuggestions\t'"$ZSH_AUTOSUGGESTIONS_REPOSITORY"$'\tcommit'
  assert_contains "$output" $'policy\trelease-age\t7'
  assert_contains "$output" $'warning\trelease-age-homebrew\tHomebrew formulae (bun, starship)'
  assert_contains "$output" $'warning\trelease-age-npm\tnpm installs the latest corepack'
  [[ $output != *$'\nrelease\t'* ]] || fail "macOS listed a GitHub release for a formula"
  [[ $output != *$'\tfnm\t'* ]] || fail "an unselected artifact was listed"
  OS_FAMILY=apt
  uname() { if [[ ${1:-} == -m ]]; then printf 'aarch64\n'; else command uname "$@"; fi; }
  output=$(inspect_tsv)
  assert_contains "$output" $'artifact\tdirect\trpatool\t'"$RPATOOL_URL"$'\t'"$RPATOOL_SHA256"
  assert_contains "$output" $'artifact\trelease\tbun\tgithub.com/oven-sh/bun\tbun-linux-aarch64.zip'
  # Offline (this suite's curl): the release is resolved during apply.
  assert_contains "$output" $'release\tbun\tunresolved\t-\tresolve-during-apply'
  assert_contains "$output" $'warning\trelease-age-npm\tnpm installs the latest corepack'
  assert_contains "$output" $'artifact\trelease\tstarship\tgithub.com/starship/starship\tstarship-aarch64-unknown-linux-musl.tar.gz'
  assert_contains "$output" $'artifact\tcorepack\tpnpm\tpnpm@latest\tlatest'
  [[ $output != *$'artifact\tformula\t'* ]] || fail "Linux listed a Homebrew formula"
  SELECTED_STEPS=fonts
  REQUESTED_STEPS=fonts
  INSTALL_FONTS=yes
  FONT_NAME=Fixture
  output=$(inspect_tsv)
  assert_contains "$output" $'artifact\trelease\tnerd-font\tgithub.com/ryanoasis/nerd-fonts\tFixture.tar.xz'
  assert_contains "$output" $'release\tnerd-font\tunresolved\t-\tresolve-during-apply'
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
    {"id":13,"name":"tool-mirror.tar.gz","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://mirror.example.invalid/tool-mirror.tar.gz"},
    {"id":14,"name":"tool_1.4.2_Linux_arm64.tar.gz","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","browser_download_url":"https://github.com/fixture/tool/releases/download/v1.4.2/tool_1.4.2_Linux_arm64.tar.gz"}
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

# A releases-list response (releases?per_page=30), newest first as GitHub
# sends it, against FIXED_NOW (2026-11-12T12:00:00Z): a prerelease and a
# draft (never picked), v1.5.1 (two days old), a non-prerelease with a -pre
# tag (rejected by its tag), v1.4.2 (ten days old) and v1.4.1.
releases_list_fixture() {
  cat <<'JSON'
[
  {
    "url": "https://api.github.com/repos/fixture/tool/releases/6",
    "author": { "login": "fixture", "id": 1, "type": "User" },
    "tag_name": "v1.6.0-beta.1", "target_commitish": "main", "name": "Beta",
    "draft": false, "immutable": false, "prerelease": true,
    "created_at": "2026-11-11T09:00:00Z", "updated_at": "2026-11-11T09:00:00Z",
    "published_at": "2026-11-11T09:00:00Z",
    "assets": [ { "name": "tool-linux-x64.tar.gz", "state": "uploaded", "created_at": "2026-11-11T09:00:00Z" } ],
    "body": "Try it, \"draft\": false, \"prerelease\": false"
  },
  {
    "tag_name": "v1.6.0", "name": "Next", "draft": true, "prerelease": false,
    "created_at": "2026-10-01T00:00:00Z", "published_at": null, "assets": []
  },
  {
    "tag_name": "v1.5.1", "name": "1.5.1", "draft": false, "prerelease": false,
    "created_at": "2026-11-10T07:00:00Z", "published_at": "2026-11-10T08:00:00Z", "assets": []
  },
  {
    "tag_name": "v1.5.0-pre", "name": "1.5.0 preview", "draft": false, "prerelease": false,
    "created_at": "2026-11-01T00:00:00Z", "published_at": "2026-11-01T00:00:00Z", "assets": []
  },
  {
    "tag_name": "v1.4.2", "name": "1.4.2", "draft": false, "prerelease": false,
    "created_at": "2026-11-02T07:00:00Z", "published_at": "2026-11-02T08:00:00Z",
    "assets": [ { "name": "tool-linux-x64.tar.gz", "uploader": { "login": "bot" }, "created_at": "2026-11-02T07:30:00Z" } ]
  },
  {"tag_name":"v1.4.1","draft":false,"prerelease":false,"created_at":"2026-10-20T00:00:00Z","published_at":"2026-10-20T00:00:00Z","assets":[]}
]
JSON
}

# fake_github_api <log>: a curl that serves the fixtures by URL and logs each
# argv (and its stdin when it reads --config -): the releases list, release
# v1.4.2 and an attestation answer with status ATTESTATION_STATUS (404 unless
# set). FAKE_API_STATUS, when set, answers every request with that status.
fake_github_api() {
  CURL_LOG=$1
  : > "$CURL_LOG"
  curl() {
    printf '<%s>' "$@" >> "$CURL_LOG"; printf '\n' >> "$CURL_LOG"
    [[ $1 != --config ]] || cat >> "$CURL_LOG.stdin"
    local url
    for url in "$@"; do :; done
    if [[ -n ${FAKE_API_STATUS:-} ]]; then printf '{}\n%s' "$FAKE_API_STATUS"; return 0; fi
    case $url in
      */releases\?per_page=30) releases_list_fixture; printf '\n200' ;;
      */releases/tags/v1.4.2) release_json_fixture; printf '\n200' ;;
      */attestations/*) printf '{"attestations": []}\n%s' "${ATTESTATION_STATUS:-404}" ;;
      *) printf '{"message": "Not Found"}\n404' ;;
    esac
  }
}

# Drafts and prereleases are never candidates, nor a release whose tag is not
# a plain version; the rest come newest first.
test_release_candidates_skip_drafts_prereleases_and_pre_tags() {
  assert_equals "$(releases_list_fixture | github_release_candidates)" \
    $'v1.5.1\t2026-11-10T08:00:00Z\nv1.4.2\t2026-11-02T08:00:00Z\nv1.4.1\t2026-10-20T00:00:00Z'
  # Compact JSON parses the same, and so do bun's prefixed tags.
  assert_equals "$(releases_list_fixture | tr -d '\n' | github_release_candidates | sed -n '1p')" $'v1.5.1\t2026-11-10T08:00:00Z'
  assert_equals "$(printf '[{"tag_name":"bun-v1.3.2","draft":false,"prerelease":false,"published_at":"2026-10-01T00:00:00Z"},{"tag_name":"canary","draft":false,"prerelease":false,"published_at":"2026-11-11T00:00:00Z"}]' | github_release_candidates)" \
    $'bun-v1.3.2\t2026-10-01T00:00:00Z'
  assert_equals "$(printf '{"message": "Not Found"}' | github_release_candidates)" ""
}

# github_release_pick takes the newest release published at least
# MIN_RELEASE_AGE days ago, then reads that release for the asset's URL and
# GitHub's SHA-256 digest; once per repository and asset per run. The token
# goes on curl's stdin, never in its argv.
test_release_pick_takes_the_newest_release_old_enough() {
  local temp out status a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  temp=$(mktemp -d)
  fix_now
  MIN_RELEASE_AGE=7
  fake_github_api "$temp/curl-argv"
  github_release_pick fixture/tool tool-linux-x64.tar.gz || fail "the pick failed with status $?"
  assert_equals "$RELEASE_TAG|$RELEASE_PUBLISHED|$RELEASE_URL|$RELEASE_SHA" \
    "v1.4.2|2026-11-02T08:00:00Z|https://github.com/fixture/tool/releases/download/v1.4.2/tool-linux-x64.tar.gz|$a"
  assert_equals "$RELEASE_CUTOFF_ISO" 2026-11-05T12:00:00Z
  assert_contains "$(cat "$CURL_LOG")" '<--proto><=https><--tlsv1.2>'
  assert_contains "$(sed -n '1p' "$CURL_LOG")" '<https://api.github.com/repos/fixture/tool/releases?per_page=30>'
  assert_contains "$(sed -n '2p' "$CURL_LOG")" '<https://api.github.com/repos/fixture/tool/releases/tags/v1.4.2>'
  [[ $(cat "$CURL_LOG") != *Authorization* && ! -e $CURL_LOG.stdin ]] || fail "an Authorization header was sent without a token"
  # Cached: the same pick asks GitHub nothing.
  : > "$CURL_LOG"
  RELEASE_TAG=""
  github_release_pick fixture/tool tool-linux-x64.tar.gz
  assert_equals "$RELEASE_TAG|$RELEASE_SHA" "v1.4.2|$a"
  [[ ! -s $CURL_LOG ]] || fail "a cached pick asked GitHub again: $(cat "$CURL_LOG")"
  # Age 0 admits v1.5.1 (never the prerelease, the draft or the -pre tag);
  # an age older than every release finds none.
  RELEASE_TAG_CACHE=""
  MIN_RELEASE_AGE=0
  fix_now
  github_release_tag_pick fixture/tool
  assert_equals "$RELEASE_TAG" v1.5.1
  RELEASE_TAG_CACHE=""
  MIN_RELEASE_AGE=365
  fix_now
  status=0; github_release_tag_pick fixture/tool || status=$?
  assert_equals "$status" "$GITHUB_LOOKUP_TOO_NEW"
  # A token: GITHUB_TOKEN, else gh's when it is logged in; on curl's stdin.
  MIN_RELEASE_AGE=7
  fix_now
  RELEASE_TAG_CACHE=""
  GITHUB_API_TOKEN_RESOLVED=0
  GITHUB_TOKEN=fixture-token
  : > "$CURL_LOG"
  github_release_tag_pick fixture/tool
  assert_contains "$(cat "$CURL_LOG")" '<--config><->'
  [[ $(cat "$CURL_LOG") != *fixture-token* ]] || fail "the token was passed in curl's argv: $(cat "$CURL_LOG")"
  assert_equals "$(cat "$CURL_LOG.stdin")" 'header = "Authorization: Bearer fixture-token"'
  unset GITHUB_TOKEN
  rm -f "$CURL_LOG.stdin"
  RELEASE_TAG_CACHE=""
  GITHUB_API_TOKEN_RESOLVED=0
  GITHUB_API_TOKEN=""
  GH_LOGGED_IN=""
  gh() { [[ $* == 'auth token --hostname github.com' ]] && printf 'gh-token\n'; }
  github_release_tag_pick fixture/tool
  assert_equals "$(cat "$CURL_LOG.stdin")" 'header = "Authorization: Bearer gh-token"'
  # Unreachable, refused (the rate limit's 403, or 429) and a missing
  # repository: a status and no exit, so an installed copy can be kept.
  GITHUB_API_TOKEN=""
  for status in 000:"$GITHUB_LOOKUP_UNREACHABLE" 403:"$GITHUB_LOOKUP_REFUSED" 429:"$GITHUB_LOOKUP_REFUSED" \
    404:"$GITHUB_LOOKUP_UNREACHABLE" 502:"$GITHUB_LOOKUP_UNREACHABLE"; do
    RELEASE_TAG_CACHE=""
    FAKE_API_STATUS=${status%%:*}
    out=0; github_release_pick fixture/tool tool-linux-x64.tar.gz || out=$?
    assert_equals "$FAKE_API_STATUS:$out" "$status"
  done
  unset FAKE_API_STATUS
  # A release that does not publish the asset properly stops the run.
  RELEASE_TAG_CACHE=""
  out=$( (github_release_pick fixture/tool tool-linux-arm64.tar.gz) 2>&1 ) && fail "an asset with a null digest was accepted"
  assert_contains "$out" "GitHub publishes no SHA-256 digest for tool-linux-arm64.tar.gz in fixture/tool v1.4.2"
  out=$( (github_release_pick fixture/tool tool-sha512.tar.gz) 2>&1 ) && fail "a non-SHA-256 digest was accepted"
  assert_contains "$out" "no SHA-256 digest"
  out=$( (github_release_pick fixture/tool tool-mirror.tar.gz) 2>&1 ) && fail "a download outside github.com was accepted"
  assert_contains "$out" "Unexpected download URL"
  out=$( (github_release_pick fixture/tool tool-linux-riscv64.tar.gz) 2>&1 ) && fail "a missing asset was accepted"
  assert_contains "$out" "The fixture/tool release v1.4.2 has no tool-linux-riscv64.tar.gz"
  rm -rf "$temp"
}

# Asset templates (gum's assets carry the version and platform in the name):
# {version} is the tag's version, {os} Linux or Darwin, {arch} x86_64 or
# arm64, whatever uname -m calls it.
test_release_asset_templates_expand() {
  local temp
  temp=$(mktemp -d)
  uname() {
    case ${1:-} in
      -m) printf '%s\n' "$FAKE_MACHINE" ;;
      -s) printf '%s\n' "$FAKE_SYSTEM" ;;
      *) command uname "$@" ;;
    esac
  }
  FAKE_SYSTEM=Linux FAKE_MACHINE=aarch64
  assert_equals "$(release_asset_name 'gum_{version}_{os}_{arch}.tar.gz' v0.17.0)" gum_0.17.0_Linux_arm64.tar.gz
  FAKE_MACHINE=x86_64
  assert_equals "$(release_asset_name 'gum_{version}_{os}_{arch}.tar.gz' v0.17.0)" gum_0.17.0_Linux_x86_64.tar.gz
  FAKE_SYSTEM=Darwin FAKE_MACHINE=arm64
  assert_equals "$(release_asset_name 'gum_{version}_{os}_{arch}.tar.gz' v0.17.0)" gum_0.17.0_Darwin_arm64.tar.gz
  assert_equals "$(release_asset_name bun-linux-x64.zip bun-v1.3.2)" bun-linux-x64.zip
  # A pick with a template finds the expanded asset in the picked release.
  FAKE_SYSTEM=Linux FAKE_MACHINE=aarch64
  fix_now
  MIN_RELEASE_AGE=7
  fake_github_api "$temp/curl-argv"
  github_release_pick fixture/tool 'tool_{version}_{os}_{arch}.tar.gz'
  assert_equals "$RELEASE_URL" https://github.com/fixture/tool/releases/download/v1.4.2/tool_1.4.2_Linux_arm64.tar.gz
  rm -rf "$temp"
}

# Attestations, after the digest check and only when gh is logged in: a
# repository that publishes none for the file (404) relies on the digest; one
# that does must have `gh attestation verify` pass, or nothing is installed.
test_release_attestation_is_checked_when_published() {
  local temp out sha
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME" "$temp/source"
  printf '#!/bin/sh\nprintf "starship 1.23.0\\n"\n' > "$temp/source/starship"
  chmod 755 "$temp/source/starship"
  TEST_ARCHIVE="$temp/starship.tar.gz"
  tar -czf "$TEST_ARCHIVE" -C "$temp/source" starship
  sha=$(sha256 "$TEST_ARCHIVE")
  DRY_RUN=0
  fake_github_api "$temp/curl-argv"
  GH_LOG="$temp/gh.log"
  gh() {
    [[ $* != 'attestation verify --help' ]] || return "${GH_ATTESTATION_SUPPORTED:-0}"
    printf '%s\n' "$*" >> "$GH_LOG"
    [[ $1 != attestation ]] || return "${GH_VERIFY_STATUS:-0}"
  }
  download_verified() { mkdir -p "$(dirname -- "$3")"; cp "$TEST_ARCHIVE" "$3"; }
  # Logged out: the digest alone, and GitHub is not asked.
  GH_LOGGED_IN=no
  install_archive_binary starship tar.gz https://example.invalid/s.tar.gz "$sha" "$HOME/.local/bin/starship" starship/starship
  assert_equals "$RELEASE_VERIFIED_BY" digest
  [[ ! -s $CURL_LOG && ! -e $GH_LOG ]] || fail "attestations were looked up while gh is logged out"
  # Logged in, none published: the digest alone.
  GH_LOGGED_IN=yes
  ATTESTATION_STATUS=404
  install_archive_binary starship tar.gz https://example.invalid/s.tar.gz "$sha" "$HOME/.local/bin/starship" starship/starship
  assert_equals "$RELEASE_VERIFIED_BY" digest
  assert_contains "$(cat "$CURL_LOG")" "<https://api.github.com/repos/starship/starship/attestations/sha256:$sha>"
  [[ ! -e $GH_LOG ]] || fail "gh attestation verify ran for a repository without attestations"
  # Published and verified.
  ATTESTATION_STATUS=200
  install_archive_binary starship tar.gz https://example.invalid/s.tar.gz "$sha" "$HOME/.local/bin/starship" starship/starship
  assert_equals "$RELEASE_VERIFIED_BY" attestation
  assert_contains "$(cat "$GH_LOG")" "attestation verify "
  assert_contains "$(cat "$GH_LOG")" "/starship.tar.gz --repo starship/starship"
  # A gh too old for `gh attestation` says so and relies on the digest.
  GH_ATTESTATION_SUPPORTED=1
  out=$(install_archive_binary starship tar.gz https://example.invalid/s.tar.gz "$sha" "$HOME/.local/bin/starship" starship/starship 2>&1)
  assert_contains "$out" "this gh cannot verify them"
  GH_ATTESTATION_SUPPORTED=0
  # Published but not verifying: nothing is installed.
  rm -f "$HOME/.local/bin/starship"
  GH_VERIFY_STATUS=1
  out=$( (install_archive_binary starship tar.gz https://example.invalid/s.tar.gz "$sha" "$HOME/.local/bin/starship" starship/starship) 2>&1 ) &&
    fail "an archive failing its attestation was installed"
  assert_contains "$out" "starship.tar.gz does not verify against starship/starship's attestation; nothing was installed"
  [[ ! -e $HOME/.local/bin/starship ]] || fail "an archive failing its attestation was installed"
  # GitHub cannot say whether there is one: stop rather than guess.
  GH_VERIFY_STATUS=0
  ATTESTATION_STATUS=502
  out=$( (install_archive_binary starship tar.gz https://example.invalid/s.tar.gz "$sha" "$HOME/.local/bin/starship" starship/starship) 2>&1 ) &&
    fail "an unreadable attestation answer was accepted"
  assert_contains "$out" "Could not read starship/starship's attestations"
  [[ ! -e $HOME/.local/bin/starship ]] || fail "starship was installed without an attestation answer"
  rm -rf "$temp"
}

# When no release can be picked (GitHub unreachable or refusing, or every
# recent release too new), a release tool that is installed and verifies is
# kept with a warning; without one the run stops and says what to do.
test_release_lookup_failure_keeps_a_verified_install() {
  local temp out status=0
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.local/bin"
  OS_FAMILY=apt
  DRY_RUN=0
  fix_now
  MIN_RELEASE_AGE=7
  uname() { if [[ ${1:-} == -m ]]; then printf 'x86_64\n'; else command uname "$@"; fi; }
  download_verified() { fail "downloaded without a release"; }
  fake_github_api "$temp/curl-argv"
  FAKE_API_STATUS=000
  printf '#!/bin/sh\nprintf "starship 1.22.0\\n"\n' > "$HOME/.local/bin/starship"
  chmod 755 "$HOME/.local/bin/starship"
  out=$(artifact_install starship 2>&1) || fail "an installed, verified starship failed the run: $out"
  assert_contains "$out" "kept the installed starship: could not read starship/starship's releases from GitHub"
  FAKE_API_STATUS=403
  out=$(artifact_install starship 2>&1) || fail "a rate-limited lookup failed a verified starship: $out"
  assert_contains "$out" "kept the installed starship: GitHub refused the request"
  unset FAKE_API_STATUS
  MIN_RELEASE_AGE=365
  fix_now
  out=$(artifact_install starship 2>&1) || fail "a run of new releases failed a verified starship: $out"
  assert_contains "$out" "kept the installed starship: none of starship/starship's 30 newest releases is at least 365 days old"
  # Nothing installed: the run stops with the reason.
  rm -f "$HOME/.local/bin/starship"
  out=$( (artifact_install starship) 2>&1 ) && fail "no release old enough installed nothing and passed"
  assert_contains "$out" "Rerun with a smaller --min-release-age"
  MIN_RELEASE_AGE=7
  fix_now
  FAKE_API_STATUS=403
  out=$( (artifact_install starship) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "rate limit"
  assert_contains "$out" "GITHUB_TOKEN"
  FAKE_API_STATUS=000
  out=$( (artifact_install starship) 2>&1 ) && fail "an unreachable GitHub installed nothing and passed"
  assert_contains "$out" "could not read starship/starship's releases from GitHub; check the network"
  [[ $out != *GITHUB_TOKEN* ]] || fail "an unreachable GitHub was blamed on the rate limit"
  # A release that publishes no usable asset still fails, even with a copy.
  unset FAKE_API_STATUS
  printf '#!/bin/sh\nprintf "starship 1.22.0\\n"\n' > "$HOME/.local/bin/starship"
  chmod 755 "$HOME/.local/bin/starship"
  out=$( (artifact_install starship) 2>&1 ) && fail "a release without the asset kept passing"
  assert_contains "$out" "has no starship-x86_64-unknown-linux-musl.tar.gz"
  rm -rf "$temp"
}

# inspect names the release each Linux release tool resolves to now and how
# it will be verified: the attestation when gh is logged in and the project
# publishes one for the asset, otherwise GitHub's digest.
test_inspect_reports_the_picked_release() {
  local temp output
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME"
  OS_FAMILY=apt
  fix_now
  MIN_RELEASE_AGE=7
  SELECTED_STEPS=starship
  REQUESTED_STEPS=starship
  SELECTED_GROUPS=""
  REQUESTED_GROUPS=""
  verify_step() { return 1; }
  uname() { if [[ ${1:-} == -m ]]; then printf 'x86_64\n'; else command uname "$@"; fi; }
  artifact_release_asset() { printf 'fixture/tool\ttool-linux-x64.tar.gz\n'; }
  fake_github_api "$temp/curl-argv"
  output=$(inspect_tsv)
  assert_contains "$output" $'policy\trelease-age\t7'
  assert_contains "$output" $'release\tstarship\tv1.4.2\t2026-11-02T08:00:00Z\tdigest'
  [[ $(cat "$CURL_LOG") != *attestations* ]] || fail "inspect asked for attestations while gh is logged out"
  GH_LOGGED_IN=yes
  ATTESTATION_STATUS=200
  output=$(inspect_tsv)
  assert_contains "$output" $'release\tstarship\tv1.4.2\t2026-11-02T08:00:00Z\tattestation'
  # The age comes from the option: with none, v1.5.1 is the pick; the asset
  # lookup for it fails here, so inspect reports it unresolved instead of
  # stopping.
  MIN_RELEASE_AGE=0
  fix_now
  output=$(inspect_tsv 2>/dev/null)
  assert_contains "$output" $'policy\trelease-age\t0'
  assert_contains "$output" $'release\tstarship\tunresolved\t-\tresolve-during-apply'
  rm -rf "$temp"
}

# Signatures never name a release: a new upstream release (and the pick
# moving to it) leaves every recorded step valid.
test_signatures_are_unchanged_by_a_new_upstream_release() {
  local temp step i=0
  local -a before=() after=()
  temp=$(mktemp -d)
  OS_FAMILY=apt
  TARGET=/fixture/profile
  INSTALL_FONTS=yes
  FONT_NAME=Fixture
  NODE_POLICY=current-lts
  uname() { if [[ ${1:-} == -m ]]; then printf 'x86_64\n'; else command uname "$@"; fi; }
  fix_now
  MIN_RELEASE_AGE=7
  fake_github_api "$temp/curl-argv"
  github_release_tag_pick fixture/tool
  assert_equals "$RELEASE_TAG" v1.4.2
  for step in rbenv bun fnm corepack uv cpython starship plugins fonts; do before+=("$(step_signature "$step")"); done
  # A week later v1.5.1 is old enough and becomes the pick.
  FIXED_NOW=$(( FIXED_NOW + 7 * 86400 ))
  fix_now
  RELEASE_TAG_CACHE=""
  github_release_tag_pick fixture/tool
  assert_equals "$RELEASE_TAG" v1.5.1
  NERD_FONTS_RELEASE_BASE="$NERD_FONTS_DOWNLOAD_URL/v3.5.0"
  for step in rbenv bun fnm corepack uv cpython starship plugins fonts; do after+=("$(step_signature "$step")"); done
  for step in rbenv bun fnm corepack uv cpython starship plugins fonts; do
    assert_equals "$step:${after[$i]}" "$step:${before[$i]}"
    i=$(( i + 1 ))
  done
  rm -rf "$temp"
}

# --min-release-age: a whole number of days from 0 to 365, saved as the
# profile's release-age row; a profile without the row (written before it
# existed) means 7.
test_min_release_age_is_validated_and_saved() {
  local temp value
  temp=$(mktemp -d)
  for value in 0 7 30 365; do
    MIN_RELEASE_AGE=$value
    validate_options || fail "--min-release-age $value was rejected"
  done
  for value in -1 366 1000 7d 1.5 '' 007 ' 7'; do
    MIN_RELEASE_AGE=$value
    ! (validate_options) >/dev/null 2>&1 || fail "--min-release-age '$value' was accepted"
  done
  parse_args apply --min-release-age 14
  assert_equals "$MIN_RELEASE_AGE" 14
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  DRY_RUN=0
  write_profile
  assert_equals "$(awk -F '\t' '$1 == "release-age" { print $2 }' "$PROFILE_FILE")" 14
  MIN_RELEASE_AGE=7
  read_profile
  assert_equals "$MIN_RELEASE_AGE" 14
  grep -v '^release-age' "$PROFILE_FILE" > "$temp/old" && cat "$temp/old" > "$PROFILE_FILE"
  MIN_RELEASE_AGE=30
  read_profile
  assert_equals "$MIN_RELEASE_AGE" 7
  printf 'release-age\t400\n' >> "$PROFILE_FILE"
  ! (read_profile) >/dev/null 2>&1 || fail "a saved release-age of 400 was accepted"
  # reconcile takes the saved value, not an option.
  ! (parse_args reconcile --yes --min-release-age 3) >/dev/null 2>&1 || fail "reconcile accepted --min-release-age"
  rm -rf "$temp"
}

test_release_version_strips_the_tag_prefix() {
  assert_equals "$(release_version v1.39.0)" 1.39.0
  assert_equals "$(release_version bun-v1.3.0)" 1.3.0
  assert_equals "$(release_version 0.9.1)" 0.9.1
}

# A Linux release install downloads only when the installed version is not
# the picked release, and checks the result reports that version. A newer
# installed copy is replaced too: the pick is what the release age allows.
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
  github_release_pick() {
    printf '%s %s\n' "$1" "$2" >> "$RELEASE_FIXTURE/latest.log"
    RELEASE_TAG=v1.23.0
    RELEASE_PUBLISHED=2026-11-01T00:00:00Z
    RELEASE_URL="https://github.com/starship/starship/releases/download/v1.23.0/$2"
    RELEASE_SHA=$(printf x | hash_text)
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
  assert_contains "$out" "starship 1.23.0 is already installed (the newest release at least 7 days old, published 2026-11-01T00:00:00Z)"
  assert_equals "$(cat "$temp/latest.log")" "starship/starship starship-x86_64-unknown-linux-musl.tar.gz"
  [[ ! -e $temp/download.log ]] || fail "the installed latest release was downloaded again"
  # An older one is replaced with the verified latest.
  fake_starship "$HOME/.local/bin/starship" 1.22.0
  artifact_install starship >/dev/null
  assert_equals "$(cat "$temp/download.log")" "https://github.com/starship/starship/releases/download/v1.23.0/starship-x86_64-unknown-linux-musl.tar.gz $(printf x | hash_text)"
  assert_equals "$("$HOME/.local/bin/starship" --version)" "starship 1.23.0"
  fake_starship "$HOME/.local/bin/starship" 1.24.0
  artifact_install starship >/dev/null
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
  assert_contains "$out" "Would install the newest starship release at least 7 days old (starship-x86_64-unknown-linux-musl.tar.gz from github.com/starship/starship)"
  [[ ! -s $temp/latest.log ]] || fail "a dry run asked GitHub for a release"
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
  # Nothing was saved yet, so the message must not point at reconcile.
  assert_contains "$out" "There is nothing to resume"
  [[ $out != *"reconcile --yes"* ]] || fail "run-in-terminal told the user to reconcile: $out"
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
  # Linux chsh runs as root, so on its own it no longer stops a run without a
  # terminal: sudo's own check (privileged_plan, stubbed empty here) covers it.
  SELECTED_STEPS=default-shell
  CHANGE_DEFAULT_SHELL=yes
  verify_default_shell() { return 1; }
  command() { if [[ ${1:-} == -v && ${2:-} == chsh ]]; then printf '/usr/bin/chsh\n'; return 0; fi; builtin command "$@"; }
  status=0
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 0
  [[ $out != *"chsh asks"* ]] || fail "preflight still blames chsh: $out"
  # Re-arm a stop so the dry-run assertion below still has one to report.
  SSH_MODE=generate
  # Dry-run reports the stop instead of exiting, and never calls sudo.
  DRY_RUN=1
  : > "$SUDO_LOG"
  out=$(preflight 2>&1) || fail "dry-run preflight failed: $out"
  assert_contains "$out" "Would stop before any change"
  [[ ! -s $SUDO_LOG ]] || fail "a dry run called sudo"
}

# --- Version-manager conflicts (ONB-5, CI-11) ------------------------------
test_existing_rbenv_is_reported_and_can_be_kept() {
  local temp out status=0
  temp=$(mktemp -d)
  HOME="$temp/home"
  HOMEBREW_PREFIX="$temp/brew"
  mkdir -p "$HOME/.rbenv/bin" "$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/opt/rbenv"
  OS_FAMILY=macos
  SELECTED_STEPS=rbenv
  assert_equals "$(version_manager_conflicts rbenv)" "$HOME/.rbenv"$'\tnot-a-git-checkout\n'"$HOMEBREW_PREFIX/opt/rbenv"$'\thomebrew-install'
  out=$(report_conflicts)
  assert_contains "$out" $'conflict\trbenv\t'"$HOME/.rbenv"$'\tnot-a-git-checkout'
  assert_contains "$out" $'conflict\trbenv\t'"$HOMEBREW_PREFIX/opt/rbenv"$'\thomebrew-install'
  # pyenv is no longer the profile's: an existing one is no conflict.
  (version_manager_conflicts pyenv) >/dev/null 2>&1 && fail "pyenv still has version-manager conflicts"
  # Without the option, preflight stops before any change and names it.
  privileged_plan() { :; }
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "--skip-existing-version-managers"
  # With it, the component is skipped and reported as such.
  SKIP_EXISTING_VERSION_MANAGERS=1
  install_rbenv() { fail "the kept rbenv was replaced"; }
  out=$(run_step rbenv)
  assert_contains "$out" "Skipping rbenv: keeping the existing installation"
  SELECTED_GROUPS=""
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=""
  assert_contains "$(inspect_tsv)" $'postcondition\trbenv\tskipped'
  # A checkout of another repository is a conflict too.
  rm -rf "$HOME/.rbenv"
  git init -q "$HOME/.rbenv"
  git -C "$HOME/.rbenv" remote add origin https://github.com/example/not-rbenv.git
  assert_contains "$(version_manager_conflicts rbenv)" "$HOME/.rbenv"$'\tunexpected-origin'
  rm -rf "$temp"
}

# --- Disclosure records (ONB-6, ONB-11, MI-3, R5) --------------------------
test_existing_setups_and_shadowed_artifacts_are_disclosed() {
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  HOMEBREW_PREFIX="$temp/brew"
  TARGET="$temp/profile"
  mkdir -p "$HOME/.oh-my-zsh" "$HOME/.nvm" "$HOME/miniconda3" "$HOME/.pyenv" "$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/opt/powerlevel10k"
  printf '#!/bin/sh\n' > "$HOMEBREW_PREFIX/bin/starship"
  chmod +x "$HOMEBREW_PREFIX/bin/starship"
  unset ZSH NVM_DIR
  OS_FAMILY=macos
  SELECTED_STEPS=starship
  out=$(report_existing_setups)
  # pyenv is no longer installed; one left by an earlier install is disclosed.
  assert_contains "$out" $'existing\tpyenv\t'"$HOME/.pyenv"$'\tno longer installed or updated; it stays'
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
  SELECTED_STEPS=plugins
  [[ -z $(report_shadowed_artifacts) ]] || fail "plugins still owns Starship"
  # An npm-prefix yarn from the retired yarn component is reported for
  # removal on every OS; Corepack's own shim is not.
  SELECTED_STEPS=corepack
  STATE_FILE="$temp/state.tsv"
  mkdir -p "$HOME/.local/npm/bin" "$HOME/.local/npm/lib/node_modules/corepack/dist"
  printf '#!/bin/sh\n' > "$HOME/.local/npm/bin/yarn"
  ln -s ../lib/node_modules/corepack/dist/pnpm.js "$HOME/.local/npm/bin/pnpm"
  for family in apt macos; do
    OS_FAMILY=$family
    load_brew_formulae() { BREW_FORMULAE=$'\nyarn\npnpm\n'; }
    assert_equals "$(report_tool_migrations)" $'migration\tnpm-prefix\t'"$HOME/.local/npm/bin/yarn"$'\tremoved: Corepack\'s yarn replaces it'
  done
  # macOS: Homebrew's yarn is uninstalled only when the profile's retired yarn
  # step recorded it.
  printf 'yarn\tsig\t2026-01-01T00:00:00Z\t\n' > "$STATE_FILE"
  assert_contains "$(report_tool_migrations)" $'migration\thomebrew-formula\t'"$HOMEBREW_PREFIX/opt/yarn"$'\tuninstalled: the profile installed it'
  [[ $(report_tool_migrations) != *"opt/pnpm"* ]] || fail "a Homebrew pnpm the profile never installed was reported for removal"
  OS_FAMILY=apt
  [[ $(report_tool_migrations) != *homebrew-formula* ]] || fail "Linux reported a Homebrew formula migration"
  SELECTED_STEPS=plugins
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
  # Linux changes the login shell as root too (no chsh password prompt).
  OS_FAMILY=apt
  out=$(privileged_plan)
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
  printf '%s\t%s\n' schema 2 groups zsh-config package-groups shell,languages full-upgrade yes \
    fonts no font '' default-shell no git-name '' git-email '' ssh skip ssh-key '' \
    ssh-passphrase empty gpg skip gpg-key '' gpg-passphrase empty node-channel current-lts \
    node-policy preserve-compatible ai-cli-update-channel native package-channel system > "$temp/profile/local/install-profile.tsv"
  out=$(run_cli "$temp/profile" "$temp/home" inspect --saved 2>&1) || fail "inspect --saved failed: $out"
  assert_contains "$out" $'policy\tselection\tsaved'
  assert_contains "$out" $'policy\tfull-upgrade\tno'
  assert_contains "$out" $'policy\tnode\tcurrent-lts'
  assert_contains "$out" $'migration\tprofile-schema\t2\t4'
  assert_contains "$out" $'migration\tpackage-group\tlanguages\tdropped: the packages it installed stay installed'
  assert_contains "$out" $'group\tcomponent\tzsh-config\tselected'
  [[ $out != *$'group\tpackage\tlanguages'* ]] || fail "inspect --saved kept the retired languages group"
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
      [[ -e $temp/bin/${tool##*/} || -L $temp/bin/${tool##*/} ]] || ln -s "$tool" "$temp/bin/${tool##*/}"
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
  SELECTED_STEPS=starship,fonts
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
  # The Windows download comes from the release the Linux font came from.
  NERD_FONTS_RELEASE_BASE="$NERD_FONTS_DOWNLOAD_URL/v3.4.0"
  install_fonts 2>/dev/null
  assert_contains "$PENDING_MANUAL_ACTIONS" $'manual-action\tinstall-windows-font\t'"$XDG_DATA_HOME/fonts/NerdFonts"$'\t'"$NERD_FONTS_DOWNLOAD_URL/v3.4.0/CascadiaCode.zip"
  rm -rf "$temp"
}

# CQ-2: a command that fails unexpectedly (here a stray `return 2` inside
# preflight) ends the run with status 1 and its location, never with 2 or 3,
# which mean "the plan changed" and "manual action required".
test_unexpected_failures_never_exit_2_or_3() {
  local temp out status=0
  temp=$(mktemp -d)
  make_fixture_checkout "$temp/profile"
  printf '%s\n' 'stray_failure() { return 2; }' 'preflight() { stray_failure; }' >> "$temp/profile/installer/plan.sh"
  out=$(run_cli "$temp/profile" "$temp/home" apply --yes --dry-run --groups none --package-groups none 2>&1) || status=$?
  assert_equals "$status" 1
  # The engine reports its own physical path (macOS: /private/var/...).
  assert_contains "$out" "ERROR: unexpected failure (status 2) at $(cd "$temp" && pwd -P)/profile/installer/plan.sh:"
  # A deliberate exit keeps its meaning.
  printf '%s\n' 'preflight() { exit 3; }' >> "$temp/profile/installer/plan.sh"
  status=0
  run_cli "$temp/profile" "$temp/home" apply --yes --dry-run --groups none --package-groups none >/dev/null 2>&1 || status=$?
  assert_equals "$status" 3
  rm -rf "$temp"
}

# The checksum list and the archive come from one release: the latest tag is
# resolved once, so a release published mid-run cannot pair them wrongly. The
# font signature keeps its old URL text, so installs do not re-run.
test_nerd_font_release_is_resolved_once() {
  local temp err
  temp=$(mktemp -d)
  make_font_release "$temp/release" || { rm -rf "$temp"; return 0; }
  unset NERD_FONTS_TEST_RELEASE_URL
  HOME="$temp/home"
  OS_FAMILY=apt
  DRY_RUN=0
  fix_now
  MIN_RELEASE_AGE=7
  # v3.5.0 is two days old; v3.4.0 is the newest at least a week old.
  NERD_FONT_RELEASES='[{"tag_name":"v3.5.0","draft":false,"prerelease":false,"published_at":"2026-11-10T00:00:00Z"},{"tag_name":"v3.4.0","draft":false,"prerelease":false,"published_at":"2026-10-01T00:00:00Z"}]'
  curl() {
    [[ ${1:-} == --help ]] && return 0
    local out="" want=0 a url=""
    for a in "$@"; do
      [[ $want == 1 ]] && { out=$a; want=0; continue; }
      [[ $a == --output ]] && want=1
      url=$a
    done
    printf '%s\n' "$url" >> "$FONT_RELEASE_DIR/curl.log"
    if [[ $url == https://api.github.com/* ]]; then
      printf '%s\n200' "$NERD_FONT_RELEASES"
      return 0
    fi
    cp "$FONT_RELEASE_DIR/${url##*/}" "$out"
  }
  NERD_FONTS_CHECKSUMS_FILE="$temp/SHA-256.txt"
  fetch_nerd_font_checksums "$NERD_FONTS_CHECKSUMS_FILE"
  # A release that ages past the cutoff in between is not used: the run
  # resolved its release once.
  NERD_FONT_RELEASES='[{"tag_name":"v3.5.0","draft":false,"prerelease":false,"published_at":"2026-10-02T00:00:00Z"}]'
  install_nerd_font Fixture "$NERD_FONTS_CHECKSUMS_FILE"
  assert_equals "$(cat "$temp/release/curl.log")" \
    "https://api.github.com/repos/ryanoasis/nerd-fonts/releases?per_page=30"$'\n'"$NERD_FONTS_DOWNLOAD_URL/v3.4.0/SHA-256.txt"$'\n'"$NERD_FONTS_DOWNLOAD_URL/v3.4.0/Fixture.tar.xz"
  [[ -f $HOME/.local/share/fonts/NerdFonts/FixtureNerdFont-Regular.ttf ]] || fail "the font was not installed"
  INSTALL_FONTS=yes
  FONT_NAME=Fixture
  assert_equals "$(signature_fonts)" "|yes|Fixture|https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
  # GitHub unreachable, or no release old enough: the run stops.
  NERD_FONTS_RELEASE_BASE=""
  RELEASE_TAG_CACHE=""
  curl() { printf '\n000'; return 7; }
  err=$( (nerd_fonts_release) 2>&1 ) && fail "an unreachable GitHub picked a release"
  assert_contains "$err" "Could not read the Nerd Fonts releases from GitHub"
  curl() { printf '%s\n200' '[{"tag_name":"v3.5.0","draft":false,"prerelease":false,"published_at":"2026-11-10T00:00:00Z"}]'; }
  err=$( (nerd_fonts_release) 2>&1 ) && fail "a release younger than the minimum age was picked"
  assert_contains "$err" "No Nerd Fonts release among the 30 newest is at least 7 days old"
  rm -rf "$temp"
}

# /etc/shells without a final newline: the zsh path goes on a line of its own.
test_etc_shells_append_keeps_lines_separate() {
  local temp name
  temp=$(mktemp -d)
  mkdir -p "$temp/bin"
  printf '#!/bin/sh\nexit 0\n' > "$temp/bin/zsh"
  printf '#!/bin/sh\nexit 0\n' > "$temp/bin/chsh"
  # Only the fixture file may be written.
  printf '#!/bin/sh\ncase "$2" in "%s"/*) exec %s "$@" ;; esac\necho "refused: $*" >&2; exit 1\n' "$temp" "$(command -v tee)" > "$temp/bin/tee"
  chmod +x "$temp/bin/zsh" "$temp/bin/chsh" "$temp/bin/tee"
  PATH="$temp/bin:$PATH"
  ETC_SHELLS="$temp/shells"
  printf '/bin/sh\n/bin/bash' > "$ETC_SHELLS"
  SUDO=""
  DRY_RUN=0
  OS_FAMILY=apt
  CHANGE_DEFAULT_SHELL=yes
  current_login_shell() { printf '%s\n' /bin/bash; }
  set_default_shell </dev/null >/dev/null
  assert_equals "$(cat "$ETC_SHELLS")" $'/bin/sh\n/bin/bash\n'"$temp/bin/zsh"
  # A file that ends with a newline gets no blank line.
  printf '/bin/sh\n' > "$ETC_SHELLS"
  set_default_shell </dev/null >/dev/null
  assert_equals "$(cat "$ETC_SHELLS")" $'/bin/sh\n'"$temp/bin/zsh"
  rm -rf "$temp"
}

# ONB-2: a default `gh auth login` cannot list keys (GitHub answers 404 without
# read:public_key / read:gpg_key). That is a manual action with the exact
# refresh command, not a network failure.
test_github_key_listing_without_scope_is_a_manual_action() {
  local temp out status=0
  temp=$(mktemp -d)
  printf '%s\n' 'ssh-ed25519 AAAATEST comment' > "$temp/key.pub"
  gh() {
    printf '%s\n' 'gh: Not Found (HTTP 404)' 'This API operation needs the "read:public_key" scope.' >&2
    return 1
  }
  SSH_MODE=reuse
  GPG_MODE=skip
  out=$( (github_ssh_key_present "$temp/key.pub") 2>"$temp/err" ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" $'manual-action\tgithub-key-scope\t\tgh auth refresh -h github.com -s read:public_key'
  assert_contains "$(cat "$temp/err")" "gh auth refresh -h github.com -s read:public_key"
  # Both kinds selected: one refresh grants both scopes.
  GPG_MODE=generate
  status=0
  out=$( (github_gpg_key_present ABCDEF1234567890) 2>/dev/null ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" $'\tgh auth refresh -h github.com -s read:public_key,read:gpg_key'
  rm -rf "$temp"
}

# SEC-7: a symlinked ~/.ssh/known_hosts is updated where it points; the link
# stays a link.
test_known_hosts_symlink_is_written_through() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  mkdir -p "$HOME/.ssh" "$temp/dotfiles"
  printf '%s\n' 'example.com ssh-ed25519 AAAAOTHER' > "$temp/dotfiles/known_hosts"
  ln -s "$temp/dotfiles/known_hosts" "$HOME/.ssh/known_hosts"
  gh() { printf '%s\n' 'ssh-ed25519 AAAAGOOD'; }
  ssh-keyscan() { printf '%s\n' 'github.com ssh-ed25519 AAAAGOOD'; }
  ensure_github_known_hosts
  [[ -L $HOME/.ssh/known_hosts ]] || fail "the known_hosts symlink was replaced by a file"
  assert_equals "$(cat "$temp/dotfiles/known_hosts")" $'example.com ssh-ed25519 AAAAOTHER\ngithub.com ssh-ed25519 AAAAGOOD'
  rm -rf "$temp"
}

# macOS casks (GUI apps; some ask for sudo) upgrade only with
# --upgrade-casks, which is disclosed, preflighted for sudo and saved.
test_cask_upgrade_is_opt_in() {
  local temp out
  temp=$(mktemp -d)
  OS_FAMILY=macos
  SELECTED_STEPS=packages
  SELECTED_GROUPS=dev-tools
  FULL_UPGRADE=1
  DRY_RUN=1
  ensure_brew() { :; }
  out=$(install_os_packages 2>&1)
  assert_contains "$out" "+ brew upgrade "
  [[ $out != *"--cask"* ]] || fail "casks were upgraded without --upgrade-casks: $out"
  [[ $(privileged_plan) != *cask* && $(report_behaviour) != *cask* ]] || fail "a cask upgrade was disclosed while off"
  UPGRADE_CASKS=1
  out=$(install_os_packages 2>&1)
  assert_contains "$out" "+ brew upgrade --cask"
  assert_contains "$(privileged_plan)" $'cask-upgrade\tbrew upgrade --cask'
  assert_contains "$(report_behaviour)" $'behaviour\tcask-upgrade\tfull upgrade also upgrades every Homebrew cask (GUI apps; some ask for sudo)'
  # Without a full upgrade nothing is upgraded, so nothing is disclosed.
  FULL_UPGRADE=0
  [[ $(report_behaviour) != *cask* ]] || fail "a cask upgrade was disclosed without a full upgrade"
  # The choice is saved; a profile from before the flag reads as off.
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  DRY_RUN=0
  write_profile
  UPGRADE_CASKS=0
  read_profile
  assert_equals "$UPGRADE_CASKS" 1
  grep -v '^upgrade-casks' "$PROFILE_FILE" > "$temp/old-profile"
  mv "$temp/old-profile" "$PROFILE_FILE"
  read_profile
  assert_equals "$UPGRADE_CASKS" 0
  # The flag parses for apply, and Linux refuses it.
  UPGRADE_CASKS=0
  parse_args apply --yes --upgrade-casks
  assert_equals "$UPGRADE_CASKS" 1
  make_fixture_checkout "$temp/profile"
  if [[ $(uname -s) != Darwin ]]; then
    out=$(run_cli "$temp/profile" "$temp/home" inspect --upgrade-casks 2>&1) && fail "Linux accepted --upgrade-casks"
    assert_contains "$out" "--upgrade-casks applies to Homebrew on macOS only"
  fi
  rm -rf "$temp"
}

# A GPG key --gpg generate created is remembered across apply's profile
# rewrite, so retrying the same apply after its pause reuses it.
test_generated_gpg_key_survives_the_apply_profile_rewrite() {
  local temp fingerprint=0123456789ABCDEF0123456789ABCDEF01234567
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  DRY_RUN=0
  GPG_MODE=reuse
  GPG_KEY_ID=$fingerprint
  GPG_GENERATED_KEY=$fingerprint
  write_profile
  # The retried apply: --gpg generate again, no key in its options.
  GPG_MODE=generate
  GPG_KEY_ID=""
  GPG_GENERATED_KEY=""
  remember_generated_gpg_key
  write_profile
  assert_equals "$GPG_GENERATED_KEY" "$fingerprint"
  GPG_GENERATED_KEY=""
  read_profile
  assert_equals "$GPG_GENERATED_KEY" "$fingerprint"
  rm -rf "$temp"
}

# Explicit order: each test runs in its own subshell, so stubs and globals it
# changes (OS_FAMILY, INSTALL_FONTS, HOME, function overrides) cannot leak into
# later tests, and every test starts from install.sh's defaults. An EXIT trap
# runs the installer's own cleanup, removing temporary files a test's code
# under test tracked (ensure_github_known_hosts, download_verified, ...).
# --- Runtimes and schema 4 (PR E) ------------------------------------------

# day_before_now <days>: the YYYY-MM-DD that many days before FIXED_NOW.
day_before_now() { epoch_to_iso "$(( FIXED_NOW - $1 * 86400 ))" | cut -c1-10; }

# A schema-3 profile names the retired components and the languages group;
# read_profile maps them to schema 4 without writing, inspect reports the
# migration, and the next approved write records schema 4.
test_profile_schema_3_migrates_to_4() {
  local temp
  temp=$(mktemp -d)
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  mkdir -p "$LOCAL_DIR"
  printf '%s\t%s\n' schema 3 groups packages,pyenv,rbenv,fnm,yarn,pnpm,uv,plugins,zsh-config \
    package-groups core-utils,shell,dev-tools,languages,media full-upgrade no \
    fonts no font '' default-shell no git-name '' git-email '' ssh skip ssh-key '' \
    ssh-passphrase empty gpg skip gpg-key '' gpg-passphrase empty node-channel current-lts \
    node-policy current-lts ai-cli-update-channel native package-channel system > "$PROFILE_FILE"
  cp "$PROFILE_FILE" "$temp/before"
  read_profile
  assert_equals "$PROFILE_SCHEMA" 3
  assert_equals "$SELECTED_STEPS" packages,cpython,rbenv,fnm,corepack,uv,plugins,starship,zsh-config
  assert_equals "$SELECTED_GROUPS" core-utils,shell,dev-tools,media
  validate_options
  normalise_dependencies
  order_selected_steps
  assert_equals "$SELECTED_STEPS" packages,rbenv,fnm,corepack,uv,cpython,starship,plugins,zsh-config
  assert_equals "$(report_profile_migration)" $'migration\tprofile-schema\t3\t4\nmigration\tpackage-group\tlanguages\tdropped: the packages it installed stay installed; fnm, cpython (uv) and rbenv provide Node, Python and Ruby'
  DRY_RUN=1
  write_profile
  cmp -s "$temp/before" "$PROFILE_FILE" || fail "a dry run wrote the migrated profile"
  DRY_RUN=0
  write_profile
  grep -qx $'schema\t4' "$PROFILE_FILE" || fail "the profile was not written as schema 4"
  grep -qx $'groups\tpackages,rbenv,fnm,corepack,uv,cpython,starship,plugins,zsh-config' "$PROFILE_FILE" ||
    fail "the migrated selection was not saved: $(cat "$PROFILE_FILE")"
  assert_equals "$(report_profile_migration)" ""
  # Schema 4 is read as it is: no second mapping.
  read_profile
  assert_equals "$PROFILE_SCHEMA" 4
  assert_equals "$SELECTED_STEPS" packages,rbenv,fnm,corepack,uv,cpython,starship,plugins,zsh-config
  # A schema-4 profile naming a retired component is invalid, not migrated.
  sed -i.bak $'s/^groups\t.*/groups\tpyenv,zsh-config/' "$PROFILE_FILE"
  read_profile
  ( validate_options ) >/dev/null 2>&1 && fail "a schema-4 profile with pyenv was accepted"
  rm -rf "$temp"
}

# The retired names on the command line stop the run with their replacement.
test_retired_components_and_languages_are_refused() {
  local temp out status
  temp=$(mktemp -d)
  make_fixture_checkout "$temp/profile"
  status=0
  out=$(run_cli "$temp/profile" "$temp/home" inspect --package-groups core-utils,languages 2>&1) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "The languages package group was removed"
  for item in pyenv yarn pnpm; do
    status=0
    out=$(run_cli "$temp/profile" "$temp/home" inspect --groups "$item" 2>&1) || status=$?
    assert_equals "$item:$status" "$item:1"
    assert_contains "$out" "The $item component was removed"
  done
  assert_contains "$out" "Use --groups corepack"
  rm -rf "$temp"
}

# Non-interactive shells get fnm's default Node (and with it Corepack's
# shims) from the .zshenv block, after the local bins, only when the alias
# exists, and never twice.
test_zshenv_block_adds_fnm_default_node() {
  local temp default_bin
  command -v zsh >/dev/null 2>&1 || return 0
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  DRY_RUN=0
  mkdir -p "$HOME"
  assert_contains "$(zshenv_managed_content)" '${FNM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fnm}'
  assert_contains "$(zshenv_managed_content)" '/aliases/default/bin'
  assert_contains "$(zprofile_managed_content)" '/aliases/default/bin'
  install_zsh_config
  # No fnm yet: nothing is added.
  # shellcheck disable=SC2016
  assert_equals "$(HOME="$HOME" zsh -fc 'path=(/usr/bin /bin); source ~/.zshenv; print -r -- $PATH')" \
    "$HOME/.local/bin:$HOME/.local/npm/bin:/usr/bin:/bin"
  default_bin="$HOME/.local/share/fnm/aliases/default/bin"
  mkdir -p "$default_bin"
  printf '#!/bin/sh\necho v26.13.1\n' > "$default_bin/node"
  chmod +x "$default_bin/node"
  # shellcheck disable=SC2016
  assert_equals "$(HOME="$HOME" zsh -fc 'path=(/usr/bin /bin); source ~/.zshenv; print -r -- $PATH')" \
    "$HOME/.local/bin:$HOME/.local/npm/bin:$default_bin:/usr/bin:/bin"
  # What `zsh -c` without -i runs: .zshenv, then the command.
  assert_equals "$(env -i HOME="$HOME" PATH=/usr/bin:/bin ZDOTDIR="$HOME" zsh -c 'node -v')" v26.13.1
  # Inherited: left as it is.
  # shellcheck disable=SC2016
  assert_equals "$(HOME="$HOME" zsh -fc 'path=("$HOME/.local/bin" "$HOME/.local/npm/bin" "$HOME/.local/share/fnm/aliases/default/bin" /usr/bin); source ~/.zshenv; print -r -- $PATH')" \
    "$HOME/.local/bin:$HOME/.local/npm/bin:$default_bin:/usr/bin"
  # FNM_DIR wins; macOS's Application Support is the fallback fnm itself uses.
  mkdir -p "$temp/custom/aliases/default/bin" "$HOME/Library/Application Support/fnm/aliases/default/bin"
  # shellcheck disable=SC2016
  assert_equals "$(HOME="$HOME" FNM_DIR="$temp/custom" zsh -fc 'path=(/usr/bin); source ~/.zshenv; print -r -- $PATH')" \
    "$HOME/.local/bin:$HOME/.local/npm/bin:$temp/custom/aliases/default/bin:/usr/bin"
  rm -rf "$HOME/.local/share/fnm"
  # shellcheck disable=SC2016
  assert_equals "$(HOME="$HOME" zsh -fc 'path=(/usr/bin); source ~/.zshenv; print -r -- $PATH')" \
    "$HOME/.local/bin:$HOME/.local/npm/bin:$HOME/Library/Application Support/fnm/aliases/default/bin:/usr/bin"
  # shellcheck disable=SC2016
  assert_equals "$(HOME="$HOME" zsh -fc 'path=(/usr/bin "$HOME/.local/bin"); source <(print -r -- "$1"); print -r -- $PATH' zsh "$(zprofile_managed_content)")" \
    "$HOME/.local/bin:$HOME/.local/npm/bin:$HOME/Library/Application Support/fnm/aliases/default/bin:/usr/bin"
  rm -rf "$temp"
}

# index.tab rows, newest first: version, date, 7 unused columns, LTS codename.
node_index_fixture() {
  printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity\n'
  printf '%s\t%s\tx\tx\tx\tx\tx\tx\tx\t%s\tfalse\n' \
    v27.0.0 "$(day_before_now 1)" - \
    v26.3.1 "$(day_before_now 1)" Lithium \
    v26.3.0 "$(day_before_now 3)" Lithium \
    v26.2.0 "$(day_before_now 20)" - \
    v24.9.2 "$(day_before_now 1)" Krypton \
    v24.9.1 "$(day_before_now 40)" Krypton \
    v24.8.0 "$(day_before_now 400)" Krypton
}

# A new LTS line waits the minimum release age, counted from its first LTS
# release; patches (of either line) do not.
test_node_lts_line_waits_the_release_age() {
  fix_now
  MIN_RELEASE_AGE=7
  assert_equals "$(node_index_fixture | node_lts_pick "$(day_before_now 7)")" v24.9.2
  MIN_RELEASE_AGE=2
  assert_equals "$(node_index_fixture | node_lts_pick "$(day_before_now 2)")" v26.3.1
  assert_equals "$(node_index_fixture | node_lts_pick "$(day_before_now 500)")" ""
  curl() { node_index_fixture; }
  MIN_RELEASE_AGE=7
  fix_now
  RESOLVED_NODE_VERSION=""
  resolve_node_version
  assert_equals "$RESOLVED_NODE_VERSION" v24.9.2
  MIN_RELEASE_AGE=0
  fix_now
  RESOLVED_NODE_VERSION=""
  resolve_node_version
  assert_equals "$RESOLVED_NODE_VERSION" v26.3.1
}

# uv's download list, as `uv python list --only-downloads --output-format
# json` prints it (one line; fields in uv's order): previews, freethreaded
# builds and other implementations must not count.
uv_list_fixture() {
  local version variant implementation key sep=""
  printf '['
  while read -r implementation version variant; do
    key="$implementation-$version"
    [[ $variant == default ]] || key="$key+$variant"
    printf '%s{"key":"%s-linux-x86_64-gnu","version":"%s","version_parts":{"major":3,"minor":1,"patch":0},"path":null,"symlink":null,"url":"https://example.invalid/%s.tar.gz","os":"linux","variant":"%s","implementation":"%s","arch":"x86_64","libc":"gnu"}' \
      "$sep" "$key" "$version" "$key" "$variant" "$implementation"
    sep=,
  done <<'ROWS'
cpython 3.16.0a1 default
cpython 3.15.2 freethreaded
cpython 3.15.2 default
cpython 3.15.1 default
cpython 3.14.6 default
cpython 3.14.6 freethreaded
cpython 3.13.14 default
pypy 3.17.1 default
graalpy 3.18.0 default
ROWS
  printf ']\n'
}

# fake_uv <home>: a uv in ~/.local/bin that lists uv_list_fixture, reports
# `python dir` as UV_FIXTURE_DIR, and logs every other call to UV_LOG; with
# UV_NEEDS_PREVIEW, `--default` fails as uv before 0.8 did without --preview.
fake_uv() {
  mkdir -p "$1/.local/bin"
  uv_list_fixture > "$1/uv-list.json"
  cat > "$1/.local/bin/uv" <<'UV'
#!/bin/sh
case "$1 $2" in
  "python list") cat "$HOME/uv-list.json"; exit 0 ;;
  "python dir") printf '%s\n' "$UV_FIXTURE_DIR"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$UV_LOG"
case " $* " in
  *" --default "*)
    case " $* " in *" --preview "*) ;; *) [ -z "$UV_NEEDS_PREVIEW" ] || { echo "error: The --default flag is only available in preview mode; add the --preview flag to use --default" >&2; exit 2; } ;; esac ;;
esac
exit 0
UV
  chmod +x "$1/.local/bin/uv"
}

# python_org_fixture <x.y.0 release date or "">: curl answering python.org's
# release API like the real one (a one-element list, or [] for none).
python_org_fixture() {
  PYTHON_ORG_DATE=$1
  curl() {
    local url
    for url in "$@"; do :; done
    printf '%s\n' "$url" >> "$PYTHON_ORG_LOG"
    if [[ -z $PYTHON_ORG_DATE ]]; then printf '[]\n'; return 0; fi
    printf '[{"name":"Python %s","slug":"python","version":3,"is_published":true,"is_latest":false,"release_date":"%s","pre_release":false,"release_page":null}]\n' \
      "${url##*%20}" "$PYTHON_ORG_DATE"
  }
}

test_python_line_waits_the_release_age() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  OS_FAMILY=apt
  fake_uv "$HOME"
  UV_LOG="$temp/uv.log"
  PYTHON_ORG_LOG="$temp/python-org.log"
  export UV_LOG UV_FIXTURE_DIR="$temp/uv-python"
  fix_now
  MIN_RELEASE_AGE=7
  assert_equals "$(uv_cpython_versions < "$HOME/uv-list.json" | stable_version_lines)" $'3.15\t3.15.2\n3.14\t3.14.6\n3.13\t3.13.14'
  # Python 3.15.0 came out 3 days ago: the previous line, at its newest patch.
  python_org_fixture "$(day_before_now 3)T14:13:54Z"
  resolve_python_line
  assert_equals "$RESOLVED_PYTHON_LINE:$RESOLVED_PYTHON_VERSION:$PYTHON_SELECTION" 3.14:3.14.6:latest-stable
  assert_equals "$(cat "$PYTHON_ORG_LOG")" "${PYTHON_RELEASE_API}?name=Python%203.15.0"
  # 30 days ago: the new line, with its patches at once.
  python_org_fixture "$(day_before_now 30)T14:13:54Z"
  RESOLVED_PYTHON_LINE=""
  resolve_python_line
  assert_equals "$RESOLVED_PYTHON_LINE:$RESOLVED_PYTHON_VERSION:$PYTHON_SELECTION" 3.15:3.15.2:latest-stable
  # python.org gives no date: the previous line, said so.
  python_org_fixture ""
  RESOLVED_PYTHON_LINE=""
  resolve_python_line
  assert_equals "$RESOLVED_PYTHON_LINE:$PYTHON_SELECTION:$PYTHON_NEWEST_LINE" 3.14:release-date-unknown:3.15
  # ...unless python3 is already on the newest line: never moved back.
  printf '#!/bin/sh\necho Python 3.15.1\n' > "$HOME/.local/bin/python3"
  chmod +x "$HOME/.local/bin/python3"
  RESOLVED_PYTHON_LINE=""
  resolve_python_line
  assert_equals "$RESOLVED_PYTHON_LINE:$PYTHON_SELECTION" 3.15:latest-stable
  # Without uv, nothing resolves (inspect: resolve-during-apply).
  rm -f "$HOME/.local/bin/uv"
  RESOLVED_PYTHON_LINE=""
  ! resolve_python_line || fail "a Python line resolved without uv"
  rm -rf "$temp"
}

test_cpython_installs_with_uv_and_verifies() {
  local temp out
  temp=$(mktemp -d)
  HOME="$temp/home"
  OS_FAMILY=apt
  DRY_RUN=0
  fake_uv "$HOME"
  export UV_LOG="$temp/uv.log" UV_FIXTURE_DIR="$temp/uv-python"
  PYTHON_ORG_LOG="$temp/python-org.log"
  python_org_fixture "$(day_before_now 30)T14:13:54Z"
  fix_now
  MIN_RELEASE_AGE=7
  FULL_UPGRADE=0
  : > "$UV_LOG"
  out=$(install_cpython 2>&1)
  assert_contains "$out" "Selected Python 3.15 (now 3.15.2"
  assert_equals "$(cat "$UV_LOG")" "python install --default 3.15"
  # A full upgrade also moves the line to its newest patch.
  FULL_UPGRADE=1
  : > "$UV_LOG"
  install_cpython >/dev/null 2>&1
  assert_equals "$(cat "$UV_LOG")" $'python install --default 3.15\npython upgrade 3.15'
  # A uv that keeps --default behind --preview gets it.
  FULL_UPGRADE=0
  export UV_NEEDS_PREVIEW=1
  : > "$UV_LOG"
  install_cpython >/dev/null 2>&1 || fail "install_cpython failed with a preview-only --default"
  assert_equals "$(cat "$UV_LOG")" $'python install --default 3.15\npython install --default 3.15 --preview'
  unset UV_NEEDS_PREVIEW
  # Verification: python3 in ~/.local/bin must be uv's and run.
  ! verify_cpython || fail "cpython verified without python3"
  mkdir -p "$UV_FIXTURE_DIR/cpython-3.15-linux-x86_64-gnu/bin"
  printf '#!/bin/sh\necho Python 3.15.2\n' > "$UV_FIXTURE_DIR/cpython-3.15-linux-x86_64-gnu/bin/python3.15"
  chmod +x "$UV_FIXTURE_DIR/cpython-3.15-linux-x86_64-gnu/bin/python3.15"
  printf '#!/bin/sh\necho Python 3.12.3\n' > "$HOME/.local/bin/python3"
  chmod +x "$HOME/.local/bin/python3"
  ! verify_cpython || fail "a python3 that is not uv's verified"
  ln -sf "$UV_FIXTURE_DIR/cpython-3.15-linux-x86_64-gnu/bin/python3.15" "$HOME/.local/bin/python3"
  verify_cpython || fail "uv's python3 was rejected"
  assert_equals "$(python_default_version)" 3.15.2
  # A lookup failure keeps a working Python, and stops without one.
  RESOLVED_PYTHON_LINE=""
  printf '#!/bin/sh\ncase "$1 $2" in "python dir") echo "$UV_FIXTURE_DIR";; *) exit 2;; esac\n' > "$HOME/.local/bin/uv"
  out=$(install_cpython 2>&1) || fail "a kept Python failed the run: $out"
  assert_contains "$out" "kept the installed Python"
  rm -f "$HOME/.local/bin/python3"
  out=$( (install_cpython) 2>&1 ) && fail "an unresolvable Python passed"
  assert_contains "$out" "Could not resolve the newest stable CPython line"
  rm -rf "$temp"
}

# ruby_build_fixture <home>: a ruby-build checkout whose definitions were
# added by dated commits, and a ruby-build that lists them.
ruby_build_fixture() {
  local build="$1/.rbenv/plugins/ruby-build" definition age
  mkdir -p "$build/bin" "$build/share/ruby-build"
  printf '#!/bin/sh\n[ "$1" = --definitions ] && ls "$(dirname "$0")/../share/ruby-build"\n' > "$build/bin/ruby-build"
  chmod +x "$build/bin/ruby-build"
  fixture_git init -q -b master "$build"
  while read -r definition age; do
    : > "$build/share/ruby-build/$definition"
    fixture_git -C "$build" add "share/ruby-build/$definition"
    GIT_AUTHOR_DATE="@$(( FIXED_NOW - age * 86400 )) +0000" GIT_COMMITTER_DATE="@$(( FIXED_NOW - age * 86400 )) +0000" \
      fixture_git -C "$build" commit -q -m "Add $definition"
  done <<'ROWS'
3.3.9 900
3.4.0 400
3.4.7 60
4.0.0-preview2 50
jruby-10.0.0.0 45
truffleruby-34.0.1 44
3.4.8 2
4.0.0 3
4.0.0-dev 3
ROWS
}

test_ruby_line_waits_the_release_age() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  git() { fixture_git "$@"; }
  fix_now
  MIN_RELEASE_AGE=7
  ruby_build_fixture "$HOME"
  # 4.0.0 was added 3 days ago: the previous line, with its 2-day-old patch.
  resolve_ruby_version
  assert_equals "$RESOLVED_RUBY_VERSION:$RUBY_SELECTION:$RUBY_NEWEST_LINE" 3.4.8:latest-stable:4.0
  assert_equals "$(ruby_line_added 4.0)" "$(( FIXED_NOW - 3 * 86400 ))"
  MIN_RELEASE_AGE=2
  fix_now
  RESOLVED_RUBY_VERSION=""
  resolve_ruby_version
  assert_equals "$RESOLVED_RUBY_VERSION" 4.0.0
  # A line whose x.y.0 history is unknown (a shallow or copied checkout).
  MIN_RELEASE_AGE=7
  fix_now
  : > "$HOME/.rbenv/plugins/ruby-build/share/ruby-build/4.1.1"
  RESOLVED_RUBY_VERSION=""
  resolve_ruby_version
  assert_equals "$RESOLVED_RUBY_VERSION:$RUBY_SELECTION" 4.0.0:release-date-unknown
  rm -rf "$temp"
}

# install_ruby compiles with rbenv install. A failed compile warns, records
# ruby-failed:<v> and still verifies, so a reconcile does not compile again;
# a full upgrade re-runs the step and retries.
test_ruby_compile_failure_is_recorded_not_retried() {
  local temp out rbenv
  temp=$(mktemp -d)
  HOME="$temp/home"
  LOCAL_DIR="$temp/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  OS_FAMILY=apt
  DRY_RUN=0
  git() { fixture_git "$@"; }
  fix_now
  MIN_RELEASE_AGE=7
  ruby_build_fixture "$HOME"
  rbenv="$HOME/.rbenv/bin/rbenv"
  mkdir -p "$HOME/.rbenv/bin"
  cat > "$rbenv" <<'RBENV'
#!/bin/sh
printf '%s\n' "$*" >> "$RBENV_LOG"
case "$1" in
  install)
    [ -z "$RBENV_FAIL" ] || exit 1
    mkdir -p "$RBENV_ROOT/versions/$3/bin"
    printf '#!/bin/sh\nexit 0\n' > "$RBENV_ROOT/versions/$3/bin/ruby"
    chmod +x "$RBENV_ROOT/versions/$3/bin/ruby" ;;
  global) printf '%s\n' "$2" > "$RBENV_ROOT/version" ;;
esac
RBENV
  chmod +x "$rbenv"
  export RBENV_LOG="$temp/rbenv.log" RBENV_FAIL=1
  git_checkout_at_release() { return 0; }
  out=$(install_ruby 2>&1; printf 'result=%s\n' "$RUBY_RESULT")
  assert_contains "$out" "Ruby 3.4.8 did not compile"
  assert_contains "$out" "result=ruby-failed:3.4.8"
  assert_equals "$(cat "$RBENV_LOG")" "install --skip-existing 3.4.8"
  RUBY_RESULT=ruby-failed:3.4.8
  verify_rbenv || fail "a recorded failed compile did not verify"
  mark_done rbenv
  RUBY_RESULT=""
  assert_equals "$(state_detail rbenv)" ruby-failed:3.4.8
  verify_rbenv || fail "the state's failed compile did not verify"
  step_follows_upstream rbenv || fail "a full upgrade would not retry the compile"
  # The next compile works: rbenv's global is the new Ruby.
  unset RBENV_FAIL
  : > "$RBENV_LOG"
  RESOLVED_RUBY_VERSION=""
  install_ruby >/dev/null 2>&1
  assert_equals "$(cat "$RBENV_LOG")" $'install --skip-existing 3.4.8\nglobal 3.4.8'
  assert_equals "$RUBY_RESULT" ruby:3.4.8
  assert_equals "$(ruby_global_version)" 3.4.8
  mark_done rbenv
  # A deleted Ruby no longer verifies once a compile has worked.
  RUBY_RESULT=""
  rm -rf "$HOME/.rbenv/versions/3.4.8"
  ! verify_rbenv || fail "rbenv verified without its Ruby"
  rm -rf "$temp"
}

# Schema 4 drops the state rows of retired steps: pyenv at once; yarn and pnpm
# when the corepack step has removed what they installed.
test_retired_state_rows_are_dropped() {
  local temp
  temp=$(mktemp -d)
  HOME="$temp/home"
  TARGET="$temp/profile"
  LOCAL_DIR="$TARGET/local"
  STATE_FILE="$LOCAL_DIR/install-state.tsv"
  LEGACY_STATE_FILE="$temp/legacy/install-state.tsv"
  mkdir -p "$LOCAL_DIR" "$HOME"
  printf '%s\tsig\t2026-01-01T00:00:00Z\t\n' packages pyenv yarn pnpm fnm > "$STATE_FILE"
  DRY_RUN=1
  migrate_local_state >/dev/null
  assert_equals "$(cut -f1 "$STATE_FILE" | paste -sd, -)" packages,pyenv,yarn,pnpm,fnm
  DRY_RUN=0
  migrate_local_state
  assert_equals "$(cut -f1 "$STATE_FILE" | paste -sd, -)" packages,yarn,pnpm,fnm
  drop_state_rows yarn pnpm
  assert_equals "$(cut -f1 "$STATE_FILE" | paste -sd, -)" packages,fnm
  rm -rf "$temp"
}

# --- setup: the wizard (installer/setup.sh) and its prompts (installer/ui.sh)
# setup_answers <answer...>: the plain prompts read these lines, as they would
# from /dev/tty.
setup_answers() {
  local file
  file=$(mktemp)
  track_temp "$file"
  if (( $# )); then printf '%s\n' "$@" > "$file"; else : > "$file"; fi
  UI_TTY=$file
  UI_PLAIN=1
  ui_init 2>/dev/null
}

# every answer was read (the next read hits the end of the file).
assert_answers_used() {
  local extra
  if IFS= read -r extra <&7; then fail "an answer was left unread: '$extra'"; fi
}

# Customize, through every stage: each answer lands in the global the
# matching apply option sets, and the result passes the engine's validation.
test_setup_customize_stages_set_the_globals() {
  local temp
  temp=$(mktemp -d)
  track_temp "$temp"
  HOME="$temp/home"
  mkdir -p "$HOME/.ssh"
  printf 'private\n' > "$HOME/.ssh/id_test"
  printf 'ssh-ed25519 AAAATEST test@host\n' > "$HOME/.ssh/id_test.pub"
  printf 'ssh-ed25519 AAAAORPHAN no-private-key\n' > "$HOME/.ssh/orphan.pub"
  export GIT_CONFIG_GLOBAL="$temp/gitconfig"
  : > "$GIT_CONFIG_GLOBAL"
  OS_FAMILY=apt
  PROFILE_FILE="$temp/no-such-profile.tsv"
  gpg() {
    printf '%s\n' 'sec:u:255:22:AAAAAAAAAAAAAAAA:1::::::scESC:' \
      'fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:' \
      'uid:u::::1::HASH::Fixture User, Jr. <fixture@example.com>::::' \
      'ssb:u:255:18:BBBBBBBBBBBBBBBB:1::::::e:' \
      'fpr:::::::::FFFF456789ABCDEF0123456789ABCDEF01234567:'
  }
  # mode: Customize; components: none, then starship..default-shell; package
  # groups: none, then shell; font: yes, FiraCode; no full upgrade; login
  # shell: no; release age: change, a bad value, then 3; SSH: the existing
  # key; GPG: the existing key; Git name, a bad email, then a good one.
  setup_answers 2 none '9 10 11 12 13' '' none 2 '' 2 FiraCode n 3 2 abc 3 3 1 3 1 Ada bad ada@example.com
  setup_wizard 2>/dev/null
  assert_answers_used
  assert_equals "$SETUP_MODE" customize
  assert_equals "$SELECTED_STEPS" starship,plugins,fonts,zsh-config,default-shell
  assert_equals "$SELECTED_GROUPS" shell
  assert_equals "$INSTALL_FONTS|$FONT_NAME" yes\|FiraCode
  assert_equals "$FULL_UPGRADE|$UPGRADE_CASKS" 0\|0
  assert_equals "$CHANGE_DEFAULT_SHELL" no
  assert_equals "$MIN_RELEASE_AGE" 3
  assert_equals "$SSH_MODE|$SSH_KEY_PATH" "reuse|$HOME/.ssh/id_test"
  assert_equals "$GPG_MODE|$GPG_KEY_ID" reuse\|0123456789ABCDEF0123456789ABCDEF01234567
  assert_equals "$GIT_NAME|$GIT_EMAIL" Ada\|ada@example.com
  validate_options
}

# Recommended asks only about keys; Git identity is not asked for when Git
# has one. heroku and the cask upgrade are offered on macOS only.
test_setup_recommended_asks_only_for_keys() {
  local temp recommended_steps=$SELECTED_STEPS
  temp=$(mktemp -d)
  track_temp "$temp"
  HOME="$temp/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$temp/gitconfig"
  git config --global user.name 'Fixture User'
  git config --global user.email fixture@example.com
  OS_FAMILY=macos
  PROFILE_FILE="$temp/no-such-profile.tsv"
  gpg() { :; }
  # Recommended; SSH: generate at the default path, no passphrase; GPG:
  # generate with a passphrase prompt (the default).
  setup_answers '' 2 '' 2 2 ''
  setup_wizard 2>/dev/null
  assert_answers_used
  assert_equals "$SETUP_MODE" recommended
  assert_equals "$SELECTED_STEPS" "$recommended_steps"
  assert_equals "$SELECTED_GROUPS" "$RECOMMENDED_GROUPS"
  assert_equals "$SSH_MODE|$SSH_KEY_PATH|$SSH_PASSPHRASE_MODE" "generate|$HOME/.ssh/id_ed25519|empty"
  assert_equals "$GPG_MODE|$GPG_PASSPHRASE_MODE" generate\|prompt
  assert_equals "$GIT_NAME$GIT_EMAIL" ""
  setup_answers all ''
  setup_package_groups 2>/dev/null
  assert_equals "$SELECTED_GROUPS" "$CANONICAL_GROUPS"
  setup_answers '' y
  setup_full_upgrade 2>/dev/null
  setup_casks 2>/dev/null
  assert_equals "$FULL_UPGRADE|$UPGRADE_CASKS" 1\|1
  OS_FAMILY=apt
  UPGRADE_CASKS=0
  setup_answers all ''
  setup_package_groups 2>/dev/null
  assert_equals "$SELECTED_GROUPS" core-utils,shell,dev-tools,python,media,network,system
  setup_answers ''
  setup_full_upgrade 2>/dev/null
  setup_casks 2>/dev/null
  assert_answers_used
  assert_equals "$UPGRADE_CASKS" 0
}

# With a saved profile, its choices are the default; only the full upgrade is
# asked again, defaulting to the saved preference.
test_setup_saved_choices_come_from_the_profile() {
  local temp
  temp=$(mktemp -d)
  track_temp "$temp"
  LOCAL_DIR="$temp/local"
  PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
  DRY_RUN=0
  SELECTED_STEPS=zsh-config,starship
  SELECTED_GROUPS=shell
  SAVED_FULL_UPGRADE=no
  MIN_RELEASE_AGE=12
  write_profile
  SELECTED_STEPS=$CANONICAL_STEPS
  MIN_RELEASE_AGE=7
  setup_answers '' ''
  setup_wizard 2>/dev/null
  assert_answers_used
  assert_equals "$SETUP_MODE" saved
  assert_equals "$SELECTED_STEPS|$SELECTED_GROUPS|$MIN_RELEASE_AGE" zsh-config,starship\|shell\|12
  assert_equals "$FULL_UPGRADE" 0
}

# An existing ~/.rbenv that preflight would stop on becomes the choice to keep
# it (--skip-existing-version-managers) or to stop before anything changes.
test_setup_turns_an_rbenv_conflict_into_a_choice() {
  local temp out status=0
  temp=$(mktemp -d)
  track_temp "$temp"
  HOME="$temp/home"
  mkdir -p "$HOME/.rbenv"
  OS_FAMILY=apt
  SELECTED_STEPS=rbenv
  setup_answers 1
  setup_conflicts 2>/dev/null
  assert_equals "$SKIP_EXISTING_VERSION_MANAGERS" 1
  SKIP_EXISTING_VERSION_MANAGERS=0
  setup_answers 2
  out=$( (setup_conflicts) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "Nothing was changed"
  rmdir "$HOME/.rbenv"
  setup_answers 'unused'
  setup_conflicts 2>/dev/null
  assert_equals "$SKIP_EXISTING_VERSION_MANAGERS" 0
}

# The plain prompts re-ask on a bad answer, and end setup (130, nothing
# changed) when the terminal input ends.
test_plain_prompts_validate_and_stop_at_end_of_input() {
  local out status=0
  setup_answers 0 9 x 2
  ui_choose "Pick" 0 one two 2>/dev/null
  assert_equals "$UI_INDEX|$UI_REPLY" 1\|two
  setup_answers maybe N
  if ui_confirm "Sure?" yes 2>/dev/null; then fail "N was taken as yes"; fi
  setup_answers '' 
  ui_confirm "Sure?" yes 2>/dev/null || fail "the default yes was not taken"
  setup_answers '1 7' '3' 'none' '2' ''
  ui_multi "Pick" "0 2" a b c 2>/dev/null
  assert_equals "$UI_REPLY" 1
  setup_answers
  out=$( (ui_choose "Pick" 0 one two) 2>&1 ) || status=$?
  assert_equals "$status" 130
  assert_contains "$out" "nothing was changed"
}

# render_plan shows every inspect record type the contract documents (all but
# meta) and ends with the per-component summary.
test_render_plan_shows_every_record_type() {
  local plan_rows type columns i row out
  plan_rows=$(mktemp)
  track_temp "$plan_rows"
  while IFS=: read -r type columns; do
    row=$type
    i=2
    while [[ $i -le $columns ]]; do
      row="$row"$'\t'"M-$type"
      i=$((i + 1))
    done
    printf '%s\n' "$row" >> "$plan_rows"
  done < <(awk -F '|' '/^\| `[a-z-]+` \| [0-9]+ \|/ {
      type = $2; count = $3; gsub(/[ `]/, "", type); gsub(/ /, "", count); print type ":" count }' "$ROOT/docs/development.md")
  [[ $(wc -l < "$plan_rows") -gt 20 ]] || fail "could not read the record table"
  printf '%s\n' $'postcondition\tzsh-config\tverified' $'postcondition\tfnm\tneeded' \
    $'release\tbun\tunresolved\t-\tresolve-during-apply' $'group\tcomponent\tpackages\timplied' \
    $'artifact\trelease\tstarship\tgithub.com/starship/starship\tstarship.tar.gz' \
    $'release\tstarship\tv1.0.0\t2026-01-01T00:00:00Z\tdigest' >> "$plan_rows"
  out=$(render_plan "$plan_rows")
  while IFS=: read -r type columns; do
    [[ $type == meta ]] || assert_contains "$out" "M-$type"
  done < <(cut -f1 "$plan_rows" | sort -u | sed 's/$/:0/')
  for heading in Selection 'Packages (1)' Runtimes 'Releases and sources' 'Runs as root' \
    'Cannot be undone' 'Side effects' Conflicts 'Existing setups' 'Moves off an older layout' Warnings Summary; do
    assert_contains "$out" "$heading"
  done
  assert_contains "$out" "packages (implied)"
  assert_contains "$out" "bun: release not resolved yet"
  # A release tool's source and its picked release share one line.
  assert_contains "$out" "starship: release github.com/starship/starship starship.tar.gz, v1.0.0, published 2026-01-01T00:00:00Z, checked by digest"
  [[ $(grep -c 'starship' <<< "$out") -eq 1 ]] || fail "a release tool was listed more than once: $out"
  assert_contains "$out" "done       zsh-config"
  assert_contains "$out" "to do      fnm"
  assert_contains "$out" "2 to do, 1 already done; 1 packages; 1 root actions; 1 irreversible; 1 warnings"
}

# setup through the real entrypoint (dry run): the wizard's selection is
# inspected and shown, and the same selection is applied in that process.
test_setup_applies_the_plan_it_showed() {
  local temp checkout answers out status=0 shown ran
  temp=$(mktemp -d)
  track_temp "$temp"
  checkout="$temp/profile"
  make_fixture_checkout "$checkout"
  answers="$temp/answers"
  # Customize: zsh-config only, no package group, no full upgrade, keep the
  # release age, no keys; then approve.
  printf '%s\n' 2 none 12 '' none '' n '' '' '' y > "$answers"
  out=$(export UI_TTY=$answers UI_PLAIN=1; run_cli "$checkout" "$temp/home" setup --dry-run < /dev/null 2>&1) || status=$?
  assert_equals "$status" 0
  assert_contains "$out" "components: packages (implied), zsh-config"
  assert_contains "$out" "policy full-upgrade: no"
  assert_contains "$out" "Setup complete"
  shown=$(awk '/^Summary/ { s = 1; next } s && /^  (to do|done|skipped) / { print $NF }' <<< "$out" | paste -sd, -)
  ran=$(sed -En 's/^==> (Running|Skipping) ([a-z-]+).*/\2/p' <<< "$out" | paste -sd, -)
  assert_equals "$shown" packages,zsh-config
  assert_equals "$ran" "$shown"
  [[ ! -e $checkout/local/install-profile.tsv ]] || fail "a dry run saved the profile"
  # Declining the plan changes nothing and says so.
  printf '%s\n' '' '' '' n > "$answers"
  out=$(export UI_TTY=$answers UI_PLAIN=1; run_cli "$checkout" "$temp/home" setup --dry-run < /dev/null 2>&1) || fail "declining failed: $out"
  assert_contains "$out" "Nothing was changed"
  [[ $out != *"==> Running"* ]] || fail "a declined plan ran steps"
  # setup needs a terminal to ask on.
  status=0
  out=$(export UI_TTY=$temp/no-terminal; run_cli "$checkout" "$temp/home" setup < /dev/null 2>&1) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "apply --yes"
}

# At a terminal in setup, a credential manual action waits ("done? check
# again"), can run gh auth login for the user, and only falls back to exit 3
# when the user stops; component actions end as a checklist.
test_setup_waits_for_manual_actions_at_a_terminal() {
  local temp out status=0
  temp=$(mktemp -d)
  track_temp "$temp"
  GH_LOG="$temp/gh.log"
  : > "$GH_LOG"
  COMMAND=setup
  INTERACTIVE_MANUAL=1
  SSH_MODE=reuse
  GPG_MODE=skip
  AUTH_AFTER=3
  gh() {
    printf '%s\n' "$*" >> "$GH_LOG"
    case "$1 $2" in
      'auth status') (( $(grep -c '^auth status' "$GH_LOG") >= AUTH_AFTER )) ;;
      *) return 0 ;;
    esac
  }
  # "Done: check again" twice; the third check passes. While setup waits in
  # place, the explanation does not tell the user to rerun anything.
  setup_answers 2 2
  out=$(ensure_github_auth 2>&1)
  assert_answers_used
  assert_contains "$out" 'then choose "Done: check again" below.'
  [[ $out != *rerun* ]] || fail "setup told a waiting user to rerun: $out"
  assert_equals "$(grep -c '^auth status' "$GH_LOG")" 3
  assert_equals "$PENDING_MANUAL_ACTIONS" ""
  # "Run it for me now": gh auth login, with the scope the key check needs.
  : > "$GH_LOG"
  AUTH_AFTER=2
  setup_answers 1
  ensure_github_auth 2>/dev/null
  assert_contains "$(cat "$GH_LOG")" 'auth login --hostname github.com --scopes read:public_key'
  # Stopping ends the run with exit 3, as a checklist rather than records.
  : > "$GH_LOG"
  AUTH_AFTER=99
  setup_answers 3
  out=$( (ensure_github_auth) 2>&1 ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" "Still to do by hand"
  [[ $out != *$'manual-action\t'* ]] || fail "setup printed manual-action records: $out"
  # A component's action (a missing chsh) is a checklist at the end of setup.
  PENDING_MANUAL_ACTIONS=""
  PENDING_MANUAL_EXPLANATIONS=""
  queue_manual_action set-login-shell /bin/zsh tester "install chsh" 2>/dev/null
  out=$(finish_manual_actions final 2>&1) || fail "setup's final checklist exited: $out"
  assert_contains "$out" "[ ] install chsh"
  # Outside setup nothing waits: exit 3 with the records, as before.
  COMMAND=apply
  INTERACTIVE_MANUAL=0
  status=0
  out=$( (ensure_github_auth) 2>/dev/null ) || status=$?
  assert_equals "$status" 3
  assert_contains "$out" $'manual-action\tgithub-login\t\thttps://github.com/login'
}

# preflight never hands a setup user a run-in-terminal command.
test_preflight_never_stops_setup_with_run_in_terminal() {
  local out status=0
  preflight_fixture no 1
  COMMAND=setup
  out=$( (preflight) 2>&1 ) || status=$?
  assert_equals "$status" 1
  [[ $out != *run-in-terminal* ]] || fail "setup was told to run a command in a terminal: $out"
}

# `install.sh` alone: setup at a terminal; in a Codespace or dev container
# without one, the lean profile, unattended; otherwise the usage (exit 2).
test_bare_install_sh_runs_setup_lean_profile_or_usage() {
  local out status=0 variable mode
  unset CODESPACES REMOTE_CONTAINERS DEVCONTAINER
  stdin_is_terminal() { return 0; }
  ui_terminal_available() { return 0; }
  COMMAND=""
  parse_args
  assert_equals "$COMMAND" setup
  stdin_is_terminal() { return 1; }
  out=$( (parse_args) 2>&1 ) || status=$?
  assert_equals "$status" 2
  assert_contains "$out" "Usage:"
  for variable in CODESPACES REMOTE_CONTAINERS DEVCONTAINER; do
    (
      export "$variable=true"
      COMMAND=""
      parse_args >/dev/null
      assert_equals "$COMMAND|$ASSUME_YES|$FULL_UPGRADE" apply\|1\|0
      assert_equals "$INSTALL_FONTS|$CHANGE_DEFAULT_SHELL|$SSH_MODE|$GPG_MODE" no\|no\|skip\|skip
      valid_csv "$SELECTED_STEPS" "$CANONICAL_STEPS" || fail "the lean profile names an unknown component: $SELECTED_STEPS"
      normalise_dependencies
      order_selected_steps
      assert_equals "$SELECTED_STEPS|$SELECTED_GROUPS" packages,starship,plugins,zsh-config\|shell
    ) || fail "$variable did not select the lean profile"
  done
  # Codespaces runs install.sh itself, so it must be executable.
  [[ -x $ROOT/install.sh ]] || fail "install.sh is not executable"
  mode=$(git -C "$ROOT" ls-files -s install.sh 2>/dev/null | cut -c1-6) || mode=""
  [[ -z $mode || $mode == 100755 ]] || fail "install.sh is mode $mode in Git, not 100755"
}

# gum: the one on PATH, else Homebrew's (macOS, not in a dry run), else its
# GitHub release in a temporary directory; none: plain prompts.
test_ensure_gum_prefers_path_then_brew_then_release() {
  local temp saved_path=$PATH dir
  temp=$(mktemp -d)
  track_temp "$temp"
  if [[ -x /usr/bin/gum || -x /bin/gum ]]; then return 0; fi
  GUM_CALLS="$temp/calls"
  : > "$GUM_CALLS"
  mkdir -p "$temp/path" "$temp/brewbin"
  fake_gum() { mkdir -p "$(dirname -- "$1")"; printf '#!/bin/sh\necho "gum version v0.17.0"\n' > "$1"; chmod +x "$1"; }
  say() { :; }
  warn() { :; }
  brew() {
    printf 'brew %s\n' "$*" >> "$GUM_CALLS"
    case $1 in
      install) fake_gum "$BREW_BIN/gum" ;;
      --prefix) printf '%s\n' "$BREW_BIN/.." ;;
    esac
  }
  github_release_pick() {
    printf 'pick %s\n' "$*" >> "$GUM_CALLS"
    [[ -z ${PICK_STATUS:-} ]] || return "$PICK_STATUS"
    RELEASE_URL=https://github.com/charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_Linux_x86_64.tar.gz
    RELEASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  }
  install_archive_binary() {
    printf 'install %s TMPDIR=%s DRY_RUN=%s\n' "$*" "$TMPDIR" "$DRY_RUN" >> "$GUM_CALLS"
    fake_gum "$5"
  }
  BREW_BIN="$temp/brewbin"
  # 1. On PATH.
  fake_gum "$temp/path/gum"
  PATH="$temp/path:/usr/bin:/bin"
  OS_FAMILY=macos DRY_RUN=0
  ensure_gum
  PATH=$saved_path
  assert_equals "$GUM" "$temp/path/gum"
  [[ ! -s $GUM_CALLS ]] || fail "gum on PATH still installed one: $(cat "$GUM_CALLS")"
  # 2. Homebrew, on macOS.
  PATH="$temp/brewbin:/usr/bin:/bin"
  ensure_gum
  PATH=$saved_path
  assert_equals "$GUM" "$temp/brewbin/gum"
  assert_equals "$(cat "$GUM_CALLS")" 'brew install gum'
  # 3. The release, on Linux (or in a dry run on macOS: brew would change
  # the host), into a temporary directory, downloaded even in a dry run.
  rm -f "$temp/brewbin/gum"
  for mode in apt:0 macos:1; do
    : > "$GUM_CALLS"
    OS_FAMILY=${mode%:*} DRY_RUN=${mode#*:}
    PATH="$temp/brewbin:/usr/bin:/bin"
    ensure_gum
    PATH=$saved_path
    dir=${GUM%/bin/gum}
    [[ $GUM == */bin/gum && -x $GUM && -d $dir ]] || fail "no release gum: '$GUM'"
    assert_equals "$(sed -n '1p' "$GUM_CALLS")" 'pick charmbracelet/gum gum_{version}_{os}_{arch}.tar.gz'
    assert_equals "$(sed -n '2p' "$GUM_CALLS")" \
      "install gum tar.gz https://github.com/charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_Linux_x86_64.tar.gz bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb $dir/bin/gum charmbracelet/gum TMPDIR=$dir DRY_RUN=0"
    [[ $(cat "$GUM_CALLS") != *brew* ]] || fail "$mode ran brew"
  done
  # None: ensure_gum fails, and setup uses plain prompts.
  OS_FAMILY=apt DRY_RUN=0
  PICK_STATUS=4
  PATH="/usr/bin:/bin"
  if ensure_gum; then PATH=$saved_path; fail "ensure_gum succeeded without any gum"; fi
  PATH=$saved_path
  assert_equals "$GUM" ""
}

# gum's release assets, as goreleaser names them, for each supported OS and
# CPU, and a pick of the template from a fixture of its release.
test_gum_release_asset_names() {
  GUM_DIGEST=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  uname() {
    case ${1:-} in
      -m) printf '%s\n' "$FAKE_MACHINE" ;;
      -s) printf '%s\n' "$FAKE_SYSTEM" ;;
      *) command uname "$@" ;;
    esac
  }
  FAKE_SYSTEM=Linux FAKE_MACHINE=x86_64
  assert_equals "$(release_asset_name "$GUM_RELEASE_ASSET" v0.17.0)" gum_0.17.0_Linux_x86_64.tar.gz
  FAKE_MACHINE=aarch64
  assert_equals "$(release_asset_name "$GUM_RELEASE_ASSET" v0.17.0)" gum_0.17.0_Linux_arm64.tar.gz
  FAKE_SYSTEM=Darwin FAKE_MACHINE=arm64
  assert_equals "$(release_asset_name "$GUM_RELEASE_ASSET" v0.17.0)" gum_0.17.0_Darwin_arm64.tar.gz
  FAKE_MACHINE=x86_64
  assert_equals "$(release_asset_name "$GUM_RELEASE_ASSET" v0.17.0)" gum_0.17.0_Darwin_x86_64.tar.gz
  FAKE_SYSTEM=Linux FAKE_MACHINE=aarch64
  fix_now
  MIN_RELEASE_AGE=7
  curl() {
    local url
    for url in "$@"; do :; done
    case $url in
      */repos/charmbracelet/gum/releases\?per_page=30)
        printf '[{"tag_name": "v0.18.0", "draft": false, "prerelease": false, "published_at": "2026-11-11T00:00:00Z"},
          {"tag_name": "v0.17.0", "draft": false, "prerelease": false, "published_at": "2025-09-04T12:00:00Z"}]\n200' ;;
      */repos/charmbracelet/gum/releases/tags/v0.17.0)
        printf '{"tag_name": "v0.17.0", "assets": [\n'
        for asset in checksums.txt gum_0.17.0_Darwin_arm64.tar.gz gum_0.17.0_Linux_arm64.tar.gz gum_0.17.0_Linux_x86_64.tar.gz; do
          printf '{"name": "%s", "uploader": {"login": "github-actions[bot]"}, "digest": "sha256:%s", "browser_download_url": "https://github.com/charmbracelet/gum/releases/download/v0.17.0/%s"},\n' \
            "$asset" "$GUM_DIGEST" "$asset"
        done
        printf '{"name": "last"}]}\n200' ;;
      *) printf '{}\n404' ;;
    esac
  }
  github_release_pick "$GUM_REPOSITORY" "$GUM_RELEASE_ASSET" || fail "the gum pick failed with status $?"
  assert_equals "$RELEASE_TAG|$RELEASE_URL|$RELEASE_SHA" \
    "v0.17.0|https://github.com/charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_Linux_arm64.tar.gz|$GUM_DIGEST"
}

# The Homebrew installer runs with NONINTERACTIVE=1: the plan was approved and
# preflight validated sudo, so it must not stop for RETURN.
test_homebrew_installer_runs_noninteractively() {
  local out
  # ensure_brew uses an installed Homebrew (a macOS runner has one).
  if [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]]; then return 0; fi
  OS_FAMILY=macos
  DRY_RUN=1
  command() { if [[ ${1:-} == -v && ${2:-} == brew ]]; then return 1; fi; builtin command "$@"; }
  out=$(ensure_brew 2>&1)
  assert_contains "$out" "+ env NONINTERACTIVE=1 /bin/bash "
}

# Before the Ruby compile: renew sudo's login while it is cached (never a
# prompt), or ask at a terminal; unattended without one, leave it.
test_sudo_is_refreshed_before_long_steps() {
  local temp
  temp=$(mktemp -d)
  track_temp "$temp"
  SUDO_LOG="$temp/sudo.log"
  sudo() { printf '%s\n' "$*" >> "$SUDO_LOG"; [[ $1 != -n ]] || return "$SUDO_N_STATUS"; }
  SUDO=sudo DRY_RUN=0 SUDO_PLANNED=1
  SUDO_N_STATUS=0
  : > "$SUDO_LOG"
  refresh_sudo
  assert_equals "$(cat "$SUDO_LOG")" '-n -v'
  SUDO_N_STATUS=1
  stdin_is_terminal() { return 0; }
  : > "$SUDO_LOG"
  refresh_sudo >/dev/null
  assert_equals "$(paste -sd, "$SUDO_LOG")" '-n -v,-v'
  stdin_is_terminal() { return 1; }
  : > "$SUDO_LOG"
  refresh_sudo
  assert_equals "$(cat "$SUDO_LOG")" '-n -v'
  # Nothing runs as root: no sudo at all.
  SUDO_PLANNED=0
  : > "$SUDO_LOG"
  refresh_sudo
  sudo_keepalive_start
  [[ ! -s $SUDO_LOG && -z $SUDO_KEEPALIVE_PID ]] || fail "sudo was used without a root action: $(cat "$SUDO_LOG")"
  # The keepalive starts only with a cached login and stops with the step.
  SUDO_PLANNED=1 SUDO_N_STATUS=0
  sudo_keepalive_start
  if [[ -z $SUDO_KEEPALIVE_PID ]] || ! kill -0 "$SUDO_KEEPALIVE_PID"; then fail "no sudo keepalive"; fi
  sudo_keepalive_stop
  [[ -z $SUDO_KEEPALIVE_PID ]] || fail "the keepalive was not stopped"
}

# --- bootstrap.sh -----------------------------------------------------------
# bootstrap_fixture: a fixture HOME and Git configuration in which the
# profile's GitHub URL is a local "upstream" repository (url.insteadOf), so
# the real git clones and pulls without the network.
bootstrap_fixture() {
  BS_FIXTURE=$(mktemp -d)
  track_temp "$BS_FIXTURE"
  export HOME="$BS_FIXTURE/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BS_FIXTURE/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name 'Fixture User'
  git config --global user.email fixture@example.com
  git config --global init.defaultBranch master
  git config --global url."$BS_FIXTURE/upstream".insteadOf https://github.com/foxhatleo/leos-profiles.git
  git init -q "$BS_FIXTURE/upstream"
  printf '#!/usr/bin/env bash\n' > "$BS_FIXTURE/upstream/install.sh"
  printf 'local/\n' > "$BS_FIXTURE/upstream/.gitignore"
  git -C "$BS_FIXTURE/upstream" add -A
  git -C "$BS_FIXTURE/upstream" commit -q -m 'first'
}

test_bootstrap_clones_updates_and_refuses() {
  local out status dir
  bootstrap_fixture
  LEOS_BOOTSTRAP_LIB_ONLY=1 source "$ROOT/bootstrap.sh"
  bs_start_setup() { printf 'setup %s\n' "$*"; }
  bs_say() { printf '==> %s\n' "$*"; }
  BS_OS=apt
  dir="$HOME/.leos-profiles"
  # A fresh clone, then setup in it with the arguments given.
  out=$(main --dry-run 2>&1)
  assert_contains "$out" "Cloning Leo's Profiles into $dir"
  assert_contains "$out" "setup $dir --dry-run"
  [[ -f $dir/install.sh ]] || fail "nothing was cloned"
  assert_equals "$(git -C "$dir" config --get remote.origin.url)" https://github.com/foxhatleo/leos-profiles.git
  # An existing clean checkout is fast-forwarded (ignored local/ state is
  # not a change).
  printf 'echo new\n' >> "$BS_FIXTURE/upstream/install.sh"
  git -C "$BS_FIXTURE/upstream" commit -q -am 'second'
  mkdir -p "$dir/local"
  printf 'state\n' > "$dir/local/install-profile.tsv"
  out=$(main 2>&1)
  assert_contains "$out" "Updating the existing checkout"
  assert_equals "$(git -C "$dir" rev-parse HEAD)" "$(git -C "$BS_FIXTURE/upstream" rev-parse HEAD)"
  # Local changes are refused, and left as they are.
  printf 'edit\n' >> "$dir/install.sh"
  status=0
  out=$( (main) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "has local changes"
  [[ $(tail -n 1 "$dir/install.sh") == edit ]] || fail "the local change was touched"
  git -C "$dir" checkout -q -- install.sh
  # A checkout of another repository is refused.
  git -C "$dir" remote set-url origin https://github.com/someone/else.git
  status=0
  out=$( (main) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "is a checkout of https://github.com/someone/else.git"
  # SSH and HTTPS spellings of the profile's own origin are accepted.
  bs_origin_ok git@github.com:FoxHatLeo/leos-profiles.git || fail "the SSH origin was refused"
  bs_origin_ok https://github.com/foxhatleo/leos-profiles/ || fail "the HTTPS origin was refused"
  ! bs_origin_ok https://github.com/foxhatleo/leos-profiles-fork.git || fail "a fork was accepted"
  # Something else in the way is left alone.
  rm -rf "$dir"
  mkdir -p "$dir"
  status=0
  out=$( (main) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "is not a Git checkout"
  # LEOS_PROFILES_HOME chooses the directory.
  out=$(LEOS_PROFILES_HOME="$BS_FIXTURE/elsewhere" main 2>&1)
  assert_contains "$out" "setup $BS_FIXTURE/elsewhere"
  [[ -f $BS_FIXTURE/elsewhere/install.sh ]] || fail "LEOS_PROFILES_HOME was not used"
}

# Without Git: the OS's own way to get it (Linux: the package manager, as
# root; macOS: the Command Line Tools installer, then waiting for it).
test_bootstrap_installs_git_when_missing() {
  local out status family
  bootstrap_fixture
  LEOS_BOOTSTRAP_LIB_ONLY=1 source "$ROOT/bootstrap.sh"
  BS_LOG="$BS_FIXTURE/calls"
  BS_POLL_SECONDS=0
  BS_POLL_LIMIT=5
  git() { [[ $GIT_READY -eq 1 ]] || return 127; }
  id() { printf '%s\n' "$FAKE_UID"; }
  sudo() { printf 'sudo %s\n' "$*" >> "$BS_LOG"; [[ $* != *' install '*git* && $* != *'-Syu '*git* ]] || GIT_READY=1; }
  apt-get() { printf 'apt-get %s\n' "$*" >> "$BS_LOG"; [[ $1 != install ]] || GIT_READY=1; }
  bs_say() { :; }
  FAKE_UID=1000
  for family in apt fedora arch; do
    BS_OS=$family GIT_READY=0
    : > "$BS_LOG"
    bs_install_git
    case $family in
      apt) assert_equals "$(paste -sd'|' "$BS_LOG")" 'sudo apt-get update|sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates' ;;
      fedora) assert_equals "$(cat "$BS_LOG")" 'sudo dnf install -y git ca-certificates' ;;
      arch) assert_equals "$(cat "$BS_LOG")" 'sudo pacman -Syu --needed --noconfirm git ca-certificates' ;;
    esac
  done
  # As root, no sudo.
  FAKE_UID=0 BS_OS=apt GIT_READY=0
  : > "$BS_LOG"
  env() { shift; "$@"; }
  bs_install_git
  assert_equals "$(paste -sd'|' "$BS_LOG")" 'apt-get update|apt-get install -y git ca-certificates'
  unset -f env
  # Git already works: nothing is installed.
  GIT_READY=1
  : > "$BS_LOG"
  bs_install_git
  [[ ! -s $BS_LOG ]] || fail "Git was installed although it works: $(cat "$BS_LOG")"
  # macOS: start the Command Line Tools installer, then poll until Git runs.
  BS_OS=macos GIT_READY=1 CLT_POLLS=0
  xcode-select() {
    printf 'xcode-select %s\n' "$*" >> "$BS_LOG"
    [[ $1 == -p ]] || return 0
    CLT_POLLS=$((CLT_POLLS + 1))
    (( CLT_POLLS > 3 ))
  }
  : > "$BS_LOG"
  bs_install_git
  # The first check, three polls that fail, one that passes, the last check.
  assert_equals "$(grep -c -- '-p' "$BS_LOG")" 5
  assert_contains "$(cat "$BS_LOG")" 'xcode-select --install'
  # ...and gives up, saying what to do, if they never arrive.
  CLT_POLLS=-100
  status=0
  out=$( (bs_install_git) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "Command Line Tools are still not installed"
  BS_OS=unknown GIT_READY=0
  status=0
  out=$( (bs_install_git) 2>&1 ) || status=$?
  assert_equals "$status" 1
  assert_contains "$out" "Unsupported platform"
}

# A download cut short anywhere runs nothing: every statement is inside main,
# called on the last line.
test_bootstrap_cut_short_runs_nothing() {
  local temp lines n name
  temp=$(mktemp -d)
  track_temp "$temp"
  mkdir -p "$temp/bin"
  for name in git sudo xcode-select apt-get dnf pacman curl uname id mkdir bash env sleep; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/ran"\n' "$name" "$temp" > "$temp/bin/$name"
    chmod +x "$temp/bin/$name"
  done
  lines=$(wc -l < "$ROOT/bootstrap.sh")
  for (( n = 1; n < lines; n++ )); do
    head -n "$n" "$ROOT/bootstrap.sh" > "$temp/cut.sh"
    PATH="$temp/bin" HOME="$temp" "$BASH" "$temp/cut.sh" >/dev/null 2>&1 || true
  done
  [[ ! -e $temp/ran ]] || fail "a truncated bootstrap ran commands: $(sort -u "$temp/ran" | head -5)"
  assert_equals "$(tail -n 1 "$ROOT/bootstrap.sh")" '[[ ${LEOS_BOOTSTRAP_LIB_ONLY:-0} == 1 ]] || main "$@"'
  "$BASH" -n "$ROOT/bootstrap.sh" || fail "bootstrap.sh does not parse"
}

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
  test_zshenv_block_prepends_only_missing_local_bins
  test_zsh_config_follows_zdotdir
  test_zsh_config_follows_zdotdir_set_in_zshenv
  test_macos_login_path_block
  test_bootstrap_skips_present_tools_on_linux
  test_bootstrap_installs_unzip_when_missing
  test_concurrent_lock_rejection
  test_equivalent_github_origins
  test_follow_release_checkout_picks_by_mode_and_age
  test_follow_release_checkout_protects_local_work
  test_git_sources_have_follow_modes
  test_git_checkout_at_release_rejects_branch_and_foreign_checkouts
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
  test_set_default_shell_uses_sudo_chsh_on_linux
  test_set_default_shell_uses_sudo_chsh_on_macos
  test_known_hosts_matches_metadata_and_dedupes
  test_package_signature_is_ifs_independent
  test_fnm_pulls_libatomic_where_needed
  test_empty_package_selection_signs_and_runs
  test_pkg_install_uses_one_command_per_family
  test_root_runs_privileged_commands_without_sudo
  test_login_shell_lookup_ignores_unset_user
  test_artifact_signatures_name_the_source_not_a_version
  test_artifact_verification_checks_version_and_digest
  test_artifact_version_ok_accepts_any_version_without_one
  test_inspect_lists_every_selected_registry_artifact
  test_github_release_asset_record_parses_release_json
  test_release_candidates_skip_drafts_prereleases_and_pre_tags
  test_release_pick_takes_the_newest_release_old_enough
  test_release_asset_templates_expand
  test_release_attestation_is_checked_when_published
  test_inspect_reports_the_picked_release
  test_signatures_are_unchanged_by_a_new_upstream_release
  test_min_release_age_is_validated_and_saved
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
  test_apt_dev_tools_add_the_github_cli_repository
  test_old_apt_zoxide_is_warned_about
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
  test_existing_rbenv_is_reported_and_can_be_kept
  test_existing_setups_and_shadowed_artifacts_are_disclosed
  test_privileged_and_behaviour_records
  test_unsupported_macs_are_warned_about
  test_approved_node_version_is_enforced
  test_inspect_saved_uses_the_saved_selection
  test_inventory_lists_managed_items
  test_remove_blocks_and_inventory_need_no_supported_platform
  test_success_names_the_terminal_font_and_wsl_action
  test_release_lookup_failure_keeps_a_verified_install
  test_lock_held_by_a_reused_pid_is_reported_stale
  test_unexpected_failures_never_exit_2_or_3
  test_nerd_font_release_is_resolved_once
  test_etc_shells_append_keeps_lines_separate
  test_github_key_listing_without_scope_is_a_manual_action
  test_known_hosts_symlink_is_written_through
  test_cask_upgrade_is_opt_in
  test_generated_gpg_key_survives_the_apply_profile_rewrite
  test_profile_schema_3_migrates_to_4
  test_retired_components_and_languages_are_refused
  test_zshenv_block_adds_fnm_default_node
  test_node_lts_line_waits_the_release_age
  test_python_line_waits_the_release_age
  test_cpython_installs_with_uv_and_verifies
  test_ruby_line_waits_the_release_age
  test_ruby_compile_failure_is_recorded_not_retried
  test_retired_state_rows_are_dropped
  test_setup_customize_stages_set_the_globals
  test_setup_recommended_asks_only_for_keys
  test_setup_saved_choices_come_from_the_profile
  test_setup_turns_an_rbenv_conflict_into_a_choice
  test_plain_prompts_validate_and_stop_at_end_of_input
  test_render_plan_shows_every_record_type
  test_setup_applies_the_plan_it_showed
  test_setup_waits_for_manual_actions_at_a_terminal
  test_preflight_never_stops_setup_with_run_in_terminal
  test_bare_install_sh_runs_setup_lean_profile_or_usage
  test_ensure_gum_prefers_path_then_brew_then_release
  test_gum_release_asset_names
  test_homebrew_installer_runs_noninteractively
  test_sudo_is_refreshed_before_long_steps
  test_bootstrap_clones_updates_and_refuses
  test_bootstrap_installs_git_when_missing
  test_bootstrap_cut_short_runs_nothing
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
