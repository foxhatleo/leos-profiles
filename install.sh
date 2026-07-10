#!/usr/bin/env bash
# Leo's Profiles deterministic installer.
#
# This script is designed to be driven by QUICK-INSTALL.md or invoked directly.
# It is intentionally conservative about mutable repositories, partial state,
# and configuration writes.  Run `bash install.sh --help` for supported flags.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=installer/lock.sh
source "$SCRIPT_DIR/installer/lock.sh"

DEFAULT_TARGET="${LEOS_PROFILES_HOME:-$HOME/.leos-profiles}"
TARGET=$DEFAULT_TARGET
PROFILE_REF=""
# rpatool remains available as the explicit `bins` step, but is not a default
# because its upstream does not publish a stable release.
SELECTED_STEPS="packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell"
SELECTED_GROUPS="core-utils,shell,dev-tools,languages,media,network,system"
SSH_MODE="skip"
SSH_PASSPHRASE_MODE="empty"
GPG_MODE="skip"
GPG_PASSPHRASE_MODE="empty"
GPG_KEY_ID=""
INSTALL_FONTS="auto"
CHANGE_DEFAULT_SHELL="auto"
DRY_RUN=0
ASSUME_YES=0
ALLOW_MUTABLE_REF=0
REPAIR=0
PLAN_ONLY=0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/leos-profiles"
STATE_FILE="$STATE_DIR/install-state.tsv"
OS_FAMILY=""
SSH_KEY_PATH=""
GIT_NAME=""
GIT_EMAIL=""
FONT_NAME=""
SELECTED_PACKAGES=()

say() { printf '%s\n' "==> $*"; }
warn() { printf '%s\n' "WARNING: $*" >&2; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash install.sh --ref <40-hex-commit> [options]

The ref is required by default so the target repository is checked out at an
immutable commit.  `--allow-mutable-ref` is available only for local
development and should not be used in published instructions.

Options:
  --target <path>                 Target profile directory (default ~/.leos-profiles)
  --ref <commit>                  Exact 40-character Git commit to install
  --steps <csv>                   bins,packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell
  --package-groups <csv>          core-utils,shell,dev-tools,languages,media,network,system
  --ssh <skip|reuse|generate>     GitHub SSH-key provisioning choice
  --ssh-key <path>                Required explicit private key when --ssh reuse
  --ssh-passphrase <empty|prompt> New SSH-key passphrase policy
  --gpg <skip|reuse|generate>     Git commit-signing choice
  --gpg-key <fingerprint>         Required explicit secret key when --gpg reuse
  --gpg-passphrase <empty|prompt> New-key passphrase policy
  --fonts <auto|yes|no>           Nerd Fonts policy
  --font <name>                   Nerd Font name (auto defaults to JetBrainsMono)
  --default-shell <auto|yes|no>   Default zsh shell policy
  --git-name <name>               Global Git name when identity is missing
  --git-email <email>             Global Git email when identity is missing
  --repair                        Repair a validated existing target checkout
  --dry-run                       Print mutations without performing them
  --plan                          Print resolved work and exit
  --yes                           Do not ask the final plan confirmation
  --allow-mutable-ref             Development-only escape hatch
  --help                          Show this help
EOF
}

require_value() {
  [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --target) require_value "$1" "${2:-}"; TARGET=$2; shift 2 ;;
    --ref) require_value "$1" "${2:-}"; PROFILE_REF=$2; shift 2 ;;
    --steps) require_value "$1" "${2:-}"; SELECTED_STEPS=$2; shift 2 ;;
    --package-groups) require_value "$1" "${2:-}"; SELECTED_GROUPS=$2; shift 2 ;;
    --ssh) require_value "$1" "${2:-}"; SSH_MODE=$2; shift 2 ;;
    --ssh-key) require_value "$1" "${2:-}"; SSH_KEY_PATH=$2; shift 2 ;;
    --ssh-passphrase) require_value "$1" "${2:-}"; SSH_PASSPHRASE_MODE=$2; shift 2 ;;
    --gpg) require_value "$1" "${2:-}"; GPG_MODE=$2; shift 2 ;;
    --gpg-key) require_value "$1" "${2:-}"; GPG_KEY_ID=$2; shift 2 ;;
    --gpg-passphrase) require_value "$1" "${2:-}"; GPG_PASSPHRASE_MODE=$2; shift 2 ;;
    --fonts) require_value "$1" "${2:-}"; INSTALL_FONTS=$2; shift 2 ;;
    --font) require_value "$1" "${2:-}"; FONT_NAME=$2; shift 2 ;;
    --default-shell) require_value "$1" "${2:-}"; CHANGE_DEFAULT_SHELL=$2; shift 2 ;;
    --git-name) require_value "$1" "${2:-}"; GIT_NAME=$2; shift 2 ;;
    --git-email) require_value "$1" "${2:-}"; GIT_EMAIL=$2; shift 2 ;;
    --repair) REPAIR=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --plan) PLAN_ONLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --allow-mutable-ref) ALLOW_MUTABLE_REF=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

valid_csv() {
  local value=$1 allowed=$2 item
  [[ -n $value ]] || return 1
  [[ $value != ,* && $value != *, && $value != *,,* ]] || return 1
  local old_ifs=$IFS
  IFS=,
  for item in $value; do
    [[ ",$allowed," == *",$item,"* ]] || { IFS=$old_ifs; return 1; }
  done
  IFS=$old_ifs
}

has_csv_item() {
  local list=$1 item=$2
  [[ ",$list," == *",$item,"* ]]
}

add_csv_item() {
  local variable_name=$1 item=$2 current
  current=${!variable_name}
  has_csv_item "$current" "$item" || printf -v "$variable_name" '%s,%s' "$current" "$item"
}

normalise_dependencies() {
  if has_csv_item "$SELECTED_STEPS" pyenv || has_csv_item "$SELECTED_STEPS" rbenv; then
    add_csv_item SELECTED_STEPS packages
    add_csv_item SELECTED_GROUPS dev-tools
  fi
  if has_csv_item "$SELECTED_STEPS" yarn || has_csv_item "$SELECTED_STEPS" pnpm || \
     has_csv_item "$SELECTED_STEPS" bun || has_csv_item "$SELECTED_STEPS" fnm; then
    add_csv_item SELECTED_STEPS packages
    add_csv_item SELECTED_GROUPS languages
  fi
  if has_csv_item "$SELECTED_STEPS" plugins || has_csv_item "$SELECTED_STEPS" zsh-config || \
     has_csv_item "$SELECTED_STEPS" default-shell; then
    add_csv_item SELECTED_STEPS packages
    add_csv_item SELECTED_GROUPS shell
  fi
}

order_selected_steps() {
  local canonical="bins,packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell"
  local step old_ifs=$IFS ordered=""
  IFS=,
  for step in $canonical; do
    has_csv_item "$SELECTED_STEPS" "$step" || continue
    ordered="${ordered:+$ordered,}$step"
  done
  IFS=$old_ifs
  SELECTED_STEPS=$ordered
}

validate_options() {
  valid_csv "$SELECTED_STEPS" "bins,packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell" || die "Invalid --steps value"
  valid_csv "$SELECTED_GROUPS" "core-utils,shell,dev-tools,languages,media,network,system" || die "Invalid --package-groups value"
  [[ $SSH_MODE == skip || $SSH_MODE == reuse || $SSH_MODE == generate ]] || die "Invalid --ssh value"
  [[ $SSH_PASSPHRASE_MODE == empty || $SSH_PASSPHRASE_MODE == prompt ]] || die "Invalid --ssh-passphrase value"
  [[ $GPG_MODE == skip || $GPG_MODE == reuse || $GPG_MODE == generate ]] || die "Invalid --gpg value"
  [[ $GPG_PASSPHRASE_MODE == empty || $GPG_PASSPHRASE_MODE == prompt ]] || die "Invalid --gpg-passphrase value"
  [[ $INSTALL_FONTS == auto || $INSTALL_FONTS == yes || $INSTALL_FONTS == no ]] || die "Invalid --fonts value"
  [[ $CHANGE_DEFAULT_SHELL == auto || $CHANGE_DEFAULT_SHELL == yes || $CHANGE_DEFAULT_SHELL == no ]] || die "Invalid --default-shell value"
  [[ $SSH_MODE != reuse || -n $SSH_KEY_PATH ]] || die "--ssh reuse requires --ssh-key <private-key-path>"
  [[ $GPG_MODE != reuse || -n $GPG_KEY_ID ]] || die "--gpg reuse requires --gpg-key <fingerprint>"
  [[ $INSTALL_FONTS != yes || -n $FONT_NAME ]] || die "--fonts yes requires --font <name>"
  [[ $TARGET == /* ]] || die "--target must be an absolute path"
  [[ $SSH_MODE != reuse || $SSH_KEY_PATH == /* ]] || die "--ssh-key must be an absolute path"
  [[ -z $FONT_NAME || $FONT_NAME =~ ^[A-Za-z0-9_-]+$ ]] || die "--font must be a Nerd Fonts directory name"
  if [[ $ALLOW_MUTABLE_REF -eq 0 ]]; then
    [[ $PROFILE_REF =~ ^[0-9a-f]{40}$ ]] || die "--ref must be a full 40-character commit hash"
  fi
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  [[ $DRY_RUN -eq 1 ]] || "$@"
}

run_shell() {
  say "$1"
  [[ $DRY_RUN -eq 1 ]] || bash -c "$2"
}

detect_os() {
  if [[ $(uname -s) == Darwin ]]; then
    OS_FAMILY=macos
  elif command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY=apt
  elif command -v dnf >/dev/null 2>&1 && grep -Eq '^ID="?fedora"?$' /etc/os-release; then
    OS_FAMILY=fedora
  elif command -v pacman >/dev/null 2>&1; then
    OS_FAMILY=arch
  else
    die "Unsupported platform: expected macOS, Debian/Ubuntu, Fedora, or Arch Linux"
  fi
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

download_verified() {
  local url=$1 expected=$2 destination=$3 tmp
  local -a curl_args
  tmp="${destination}.tmp.$$"
  run mkdir -p "$(dirname -- "$destination")"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would download and SHA-256 verify $url"
    return 0
  fi
  curl_args=(--fail --location --proto '=https' --tlsv1.2 --retry 3
    --connect-timeout 15 --silent --show-error --output "$tmp")
  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    curl_args+=(--retry-all-errors)
  fi
  if ! curl "${curl_args[@]}" "$url"; then
    rm -f "$tmp"
    die "Download failed: $url"
  fi
  [[ $(sha256 "$tmp") == "$expected" ]] || { rm -f "$tmp"; die "Digest mismatch for $url"; }
  chmod 700 "$tmp"
  mv -f "$tmp" "$destination"
}

state_done() {
  local step=$1 signature
  signature=$(step_signature "$step")
  [[ -f $STATE_FILE ]] && awk -F '\t' -v step="$step" -v signature="$signature" \
    '$1 == step && $2 == signature { found=1 } END { exit !found }' "$STATE_FILE"
}

mark_done() {
  local step=$1 signature tmp
  [[ $DRY_RUN -eq 1 ]] && return 0
  signature=$(step_signature "$step")
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  tmp="$STATE_FILE.tmp.$$"
  if [[ -f $STATE_FILE ]]; then
    awk -F '\t' -v step="$step" '$1 != step' "$STATE_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$step" "$signature" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

confirm_plan() {
  say "Platform: $OS_FAMILY"
  say "Target: $TARGET"
  say "Profile ref: ${PROFILE_REF:-mutable development ref}"
  say "Steps: $SELECTED_STEPS"
  say "Package groups: $SELECTED_GROUPS"
  say "SSH: $SSH_MODE; SSH passphrase: $SSH_PASSPHRASE_MODE; GPG: $GPG_MODE; GPG passphrase: $GPG_PASSPHRASE_MODE"
  [[ -z $SSH_KEY_PATH ]] || say "Reused SSH key: $SSH_KEY_PATH"
  [[ -z $GPG_KEY_ID ]] || say "Reused GPG key: $GPG_KEY_ID"
  [[ -z $FONT_NAME ]] || say "Nerd Font: $FONT_NAME"
  say "Fonts: $INSTALL_FONTS; default shell: $CHANGE_DEFAULT_SHELL"
  if [[ $INSTALL_FONTS == auto ]]; then
    if is_desktop; then
      say "Automatic font decision: install JetBrainsMono (desktop detected)"
    else
      say "Automatic font decision: skip (headless host detected)"
    fi
  fi
  [[ $DRY_RUN -eq 0 ]] || say "Dry-run: no mutation will occur."
  [[ $PLAN_ONLY -eq 0 ]] || return 0
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local response
  read -r -p "Apply this plan? [y/N] " response
  [[ $response == y || $response == Y || $response == yes || $response == YES ]] || die "Cancelled"
}

ensure_sudo() {
  [[ $OS_FAMILY == macos ]] && return 0
  [[ $DRY_RUN -eq 1 ]] || sudo -v
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  local installer="${TMPDIR:-/tmp}/leos-homebrew-install-${HOMEBREW_INSTALL_SHA256}.sh"
  say "Installing Homebrew from a pinned, SHA-256-verified script"
  download_verified "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$installer"
  run /bin/bash "$installer"
  [[ $DRY_RUN -eq 0 ]] || return 0
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x $candidate ]]; then
      eval "$("$candidate" shellenv)"
      break
    fi
  done
  command -v brew >/dev/null 2>&1 || die "Homebrew installation did not put brew on PATH"
}

bootstrap_tools() {
  if [[ $OS_FAMILY == macos ]]; then
    ensure_brew
    run brew install git curl
    return 0
  fi
  ensure_sudo
  case $OS_FAMILY in
    apt)
      run sudo apt-get update
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates unzip ;;
    fedora)
      run sudo dnf install -y git curl ca-certificates unzip ;;
    arch)
      run sudo pacman -Syu --needed --noconfirm git curl ca-certificates unzip ;;
  esac
}

origin_matches() {
  [[ -d $TARGET/.git ]] || return 1
  local origin
  origin=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
  [[ $origin == "$LEOS_PROFILE_REPOSITORY" || $origin == git@github.com:foxhatleo/leos-profiles.git ]]
}

ensure_target() {
  if [[ -e $TARGET && ! -d $TARGET ]]; then
    die "Target exists but is not a directory: $TARGET"
  fi
  if [[ -d $TARGET ]]; then
    origin_matches || die "Existing target is not a Leo's Profiles checkout: $TARGET"
    [[ -f $TARGET/zsh/start.zsh ]] || die "Existing target is incomplete: $TARGET"
    if [[ -n $PROFILE_REF ]]; then
      if git -C "$TARGET" cat-file -e "$PROFILE_REF^{commit}" 2>/dev/null; then
        local actual
        actual=$(git -C "$TARGET" rev-parse HEAD)
        if [[ $actual != "$PROFILE_REF" ]]; then
          [[ $REPAIR -eq 1 ]] || die "Target is at $actual, expected $PROFILE_REF; rerun with --repair after reviewing local changes"
          [[ -z $(git -C "$TARGET" status --porcelain) ]] || die "Refusing to repair a target with local changes"
          run git -C "$TARGET" checkout --detach "$PROFILE_REF"
        fi
      else
        [[ $REPAIR -eq 1 ]] || die "Target lacks requested ref; rerun with --repair"
        [[ -z $(git -C "$TARGET" status --porcelain) ]] || die "Refusing to repair a target with local changes"
        run git -C "$TARGET" fetch origin "$PROFILE_REF"
        run git -C "$TARGET" checkout --detach "$PROFILE_REF"
      fi
    fi
    return 0
  fi

  [[ -n $PROFILE_REF || $ALLOW_MUTABLE_REF -eq 1 ]] || die "A pinned --ref is required before cloning"
  run mkdir -p "$(dirname -- "$TARGET")"
  run git clone "$LEOS_PROFILE_REPOSITORY" "$TARGET"
  if [[ -n $PROFILE_REF ]]; then
    if [[ $DRY_RUN -eq 0 ]] && ! git -C "$TARGET" cat-file -e "$PROFILE_REF^{commit}" 2>/dev/null; then
      run git -C "$TARGET" fetch origin "$PROFILE_REF"
    fi
    run git -C "$TARGET" checkout --detach "$PROFILE_REF"
    [[ $DRY_RUN -eq 1 ]] || [[ $(git -C "$TARGET" rev-parse HEAD) == "$PROFILE_REF" ]] || die "Clone did not resolve requested commit"
  fi
}

package_list_for_group() {
  local group=$1
  case "$OS_FAMILY:$group" in
    macos:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils gnu-indent gnu-sed gnu-tar gnu-which grep gawk gzip less nano' ;;
    macos:shell) printf '%s\n' 'zsh' ;;
    macos:dev-tools) printf '%s\n' 'bat direnv eza fd fzf git pkg-config openssl@3 readline ripgrep sqlite3 tcl-tk vim xz zlib zoxide' ;;
    macos:languages) printf '%s\n' 'node python ruby' ;;
    macos:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    macos:network) printf '%s\n' 'wget rclone gnutls heroku ssh-copy-id' ;;
    macos:system) printf '%s\n' 'smartmontools' ;;
    apt:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    apt:shell) printf '%s\n' 'zsh' ;;
    apt:dev-tools) printf '%s\n' 'bat build-essential clang direnv fd-find fzf gcc git libbz2-dev libffi-dev liblzma-dev libncursesw5-dev libreadline-dev libsqlite3-dev libssl-dev libxml2-dev libxmlsec1-dev llvm ripgrep tk-dev vim xz-utils zlib1g-dev zoxide' ;;
    apt:languages) printf '%s\n' 'nodejs npm python-is-python3 ruby' ;;
    apt:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    apt:network) printf '%s\n' 'wget rclone' ;;
    apt:system) printf '%s\n' 'smartmontools' ;;
    fedora:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    fedora:shell) printf '%s\n' 'zsh' ;;
    fedora:dev-tools) printf '%s\n' 'bat bzip2 bzip2-devel direnv fd-find fzf gcc gdbm-libs git libffi-devel libnsl2 libuuid-devel make openssl-devel patch readline-devel ripgrep sqlite sqlite-devel tk-devel vim xz-devel zlib-devel zoxide' ;;
    fedora:languages) printf '%s\n' 'nodejs python-unversioned-command ruby' ;;
    fedora:media) printf '%s\n' 'ImageMagick ffmpeg yt-dlp' ;;
    fedora:network) printf '%s\n' 'wget rclone' ;;
    fedora:system) printf '%s\n' 'smartmontools' ;;
    arch:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    arch:shell) printf '%s\n' 'zsh' ;;
    arch:dev-tools) printf '%s\n' 'base-devel bat direnv eza fd fzf git libffi openssl ripgrep tk vim xz zlib zoxide' ;;
    arch:languages) printf '%s\n' 'nodejs npm python ruby' ;;
    arch:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    arch:network) printf '%s\n' 'wget rclone' ;;
    arch:system) printf '%s\n' 'smartmontools' ;;
  esac
}

collect_selected_packages() {
  local group package_list
  local -a group_packages
  local old_ifs=$IFS
  SELECTED_PACKAGES=()
  IFS=,
  for group in $SELECTED_GROUPS; do
    package_list=$(package_list_for_group "$group")
    IFS=' '
    read -r -a group_packages <<< "$package_list"
    SELECTED_PACKAGES+=("${group_packages[@]}")
    IFS=,
  done
  IFS=$old_ifs
}

package_installed() {
  local package=$1
  case $OS_FAMILY in
    macos) brew list --versions "$package" >/dev/null 2>&1 ;;
    apt) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed' ;;
    fedora) rpm -q "$package" >/dev/null 2>&1 ;;
    arch) pacman -Q "$package" >/dev/null 2>&1 ;;
  esac
}

selected_packages_installed() {
  local package
  collect_selected_packages
  (( ${#SELECTED_PACKAGES[@]} > 0 )) || return 0
  for package in "${SELECTED_PACKAGES[@]}"; do
    package_installed "$package" || return 1
  done
}

install_os_packages() {
  collect_selected_packages
  (( ${#SELECTED_PACKAGES[@]} > 0 )) || return 0
  ensure_sudo
  case $OS_FAMILY in
    macos)
      ensure_brew
      if has_csv_item "$SELECTED_GROUPS" network; then run brew tap heroku/brew; fi
      run brew update
      run brew upgrade
      run brew upgrade --cask
      run brew install "${SELECTED_PACKAGES[@]}" ;;
    apt)
      run sudo apt-get update
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${SELECTED_PACKAGES[@]}"
      run mkdir -p "$HOME/.local/bin"
      if [[ $DRY_RUN -eq 0 ]]; then
        command -v fd >/dev/null 2>&1 || { command -v fdfind >/dev/null 2>&1 && ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"; }
        command -v bat >/dev/null 2>&1 || { command -v batcat >/dev/null 2>&1 && ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"; }
      fi ;;
    fedora)
      run sudo dnf upgrade -y
      if has_csv_item "$SELECTED_GROUPS" dev-tools; then run sudo dnf group install -y development-tools; fi
      if has_csv_item "$SELECTED_GROUPS" media; then
        run sudo dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
      fi
      if has_csv_item "$SELECTED_GROUPS" media; then
        run sudo dnf install -y --allowerasing "${SELECTED_PACKAGES[@]}"
      else
        run sudo dnf install -y "${SELECTED_PACKAGES[@]}"
      fi ;;
    arch)
      run sudo pacman -Syu --noconfirm
      run sudo pacman -S --needed --noconfirm "${SELECTED_PACKAGES[@]}" ;;
  esac
}

clone_pinned() {
  local repository=$1 commit=$2 destination=$3 label=$4 origin
  if [[ -d $destination ]]; then
    [[ -d $destination/.git ]] || die "$label exists but is not a Git checkout: $destination"
    origin=$(git -C "$destination" remote get-url origin 2>/dev/null || true)
    [[ $origin == "$repository" ]] || die "$label checkout has an unexpected origin: $destination"
    [[ -z $(git -C "$destination" status --porcelain) ]] || die "$label checkout has local changes: $destination"
  else
    run mkdir -p "$(dirname -- "$destination")"
    run git clone "$repository" "$destination"
  fi
  if [[ $DRY_RUN -eq 0 ]] && ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
    run git -C "$destination" fetch --depth 1 origin "$commit"
  fi
  run git -C "$destination" checkout --detach "$commit"
  [[ $DRY_RUN -eq 1 ]] || [[ $(git -C "$destination" rev-parse HEAD) == "$commit" ]] || die "$label did not resolve pinned commit"
}

install_local_bins() {
  local destination="$HOME/.local/bin/rpatool"
  download_verified "$RPATOOL_URL" "$RPATOOL_SHA256" "$destination"
  [[ $DRY_RUN -eq 1 ]] || chmod 700 "$destination"
}

install_pyenv() {
  clone_pinned "$PYENV_REPOSITORY" "$PYENV_COMMIT" "$HOME/.pyenv" pyenv
  if [[ $DRY_RUN -eq 0 ]]; then
    (cd "$HOME/.pyenv" && src/configure && make -C src)
  fi
}

install_rbenv() {
  clone_pinned "$RBENV_REPOSITORY" "$RBENV_COMMIT" "$HOME/.rbenv" rbenv
  clone_pinned "$RUBY_BUILD_REPOSITORY" "$RUBY_BUILD_COMMIT" "$HOME/.rbenv/plugins/ruby-build" ruby-build
  if [[ $DRY_RUN -eq 0 && -x $HOME/.rbenv/src/configure ]]; then
    (cd "$HOME/.rbenv" && src/configure && make -C src)
  fi
}

install_plugins() {
  local directory="$TARGET/zsh/plugins"
  clone_pinned "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$ZSH_AUTOSUGGESTIONS_COMMIT" "$directory/zsh-autosuggestions" zsh-autosuggestions
  clone_pinned "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" "$directory/zsh-syntax-highlighting" zsh-syntax-highlighting
  clone_pinned "$ZSH_COMPLETIONS_REPOSITORY" "$ZSH_COMPLETIONS_COMMIT" "$directory/zsh-completions" zsh-completions
  clone_pinned "$FZF_TAB_REPOSITORY" "$FZF_TAB_COMMIT" "$directory/fzf-tab" fzf-tab
}

is_desktop() {
  [[ $OS_FAMILY == macos || -n ${DISPLAY:-}${WAYLAND_DISPLAY:-}${XDG_CURRENT_DESKTOP:-} ]]
}

font_should_install() {
  [[ $INSTALL_FONTS == yes ]] || { [[ $INSTALL_FONTS == auto ]] && is_desktop; }
}

install_fonts() {
  if ! font_should_install; then
    say "Skipping Nerd Fonts ($INSTALL_FONTS policy)"
    return 0
  fi
  local font=${FONT_NAME:-JetBrainsMono}
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would download pinned Nerd Fonts and install $font"
    return 0
  fi
  local temp
  temp=$(mktemp -d)
  clone_pinned "$NERD_FONTS_REPOSITORY" "$NERD_FONTS_COMMIT" "$temp/nerd-fonts" nerd-fonts
  run "$temp/nerd-fonts/install.sh" "$font"
  rm -rf "$temp"
}

ensure_user_npm_prefix() {
  local prefix="$HOME/.local/npm"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would prepare user-local npm prefix: $prefix"
    return 0
  fi
  mkdir -p "$prefix"
}

install_locked_npm_package() {
  local package=$1 url=$2 expected=$3 temp archive
  ensure_user_npm_prefix
  temp=$(mktemp -d)
  archive="$temp/$package.tgz"
  download_verified "$url" "$expected" "$archive"
  run npm install --global --prefix "$HOME/.local/npm" "$archive"
  rm -rf "$temp"
}

install_yarn() {
  install_locked_npm_package yarn "$YARN_URL" "$YARN_SHA256"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/npm/bin/yarn" --version | grep -qx "$YARN_VERSION" || die "Yarn version verification failed"
}

install_pnpm() {
  install_locked_npm_package pnpm "$PNPM_URL" "$PNPM_SHA256"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/npm/bin/pnpm" --version | grep -qx "$PNPM_VERSION" || die "pnpm version verification failed"
}

machine_arch() {
  case $(uname -m) in
    arm64|aarch64) printf '%s\n' aarch64 ;;
    x86_64|amd64) printf '%s\n' x64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

platform_asset() {
  local tool=$1 arch
  arch=$(machine_arch)
  case "$tool:$OS_FAMILY:$arch" in
    bun:macos:aarch64) printf '%s\t%s\n' "$BUN_DARWIN_AARCH64_URL" "$BUN_DARWIN_AARCH64_SHA256" ;;
    bun:macos:x64) printf '%s\t%s\n' "$BUN_DARWIN_X64_URL" "$BUN_DARWIN_X64_SHA256" ;;
    bun:apt:aarch64|bun:fedora:aarch64|bun:arch:aarch64) printf '%s\t%s\n' "$BUN_LINUX_AARCH64_URL" "$BUN_LINUX_AARCH64_SHA256" ;;
    bun:apt:x64|bun:fedora:x64|bun:arch:x64) printf '%s\t%s\n' "$BUN_LINUX_X64_URL" "$BUN_LINUX_X64_SHA256" ;;
    fnm:macos:aarch64|fnm:macos:x64) printf '%s\t%s\n' "$FNM_MACOS_URL" "$FNM_MACOS_SHA256" ;;
    fnm:apt:aarch64|fnm:fedora:aarch64|fnm:arch:aarch64) printf '%s\t%s\n' "$FNM_LINUX_AARCH64_URL" "$FNM_LINUX_AARCH64_SHA256" ;;
    fnm:apt:x64|fnm:fedora:x64|fnm:arch:x64) printf '%s\t%s\n' "$FNM_LINUX_X64_URL" "$FNM_LINUX_X64_SHA256" ;;
    starship:macos:aarch64) printf '%s\t%s\n' "$STARSHIP_DARWIN_AARCH64_URL" "$STARSHIP_DARWIN_AARCH64_SHA256" ;;
    starship:macos:x64) printf '%s\t%s\n' "$STARSHIP_DARWIN_X64_URL" "$STARSHIP_DARWIN_X64_SHA256" ;;
    starship:apt:aarch64|starship:fedora:aarch64|starship:arch:aarch64) printf '%s\t%s\n' "$STARSHIP_LINUX_AARCH64_URL" "$STARSHIP_LINUX_AARCH64_SHA256" ;;
    starship:apt:x64|starship:fedora:x64|starship:arch:x64) printf '%s\t%s\n' "$STARSHIP_LINUX_X64_URL" "$STARSHIP_LINUX_X64_SHA256" ;;
    *) die "No locked $tool artifact for $OS_FAMILY/$arch" ;;
  esac
}

step_signature() {
  local step=$1 material asset
  material="state-v2|$OS_FAMILY|$step"
  case $step in
    bins) material+="|$RPATOOL_URL|$RPATOOL_SHA256" ;;
    packages)
      collect_selected_packages
      material+="|$SELECTED_GROUPS|${SELECTED_PACKAGES[*]}" ;;
    pyenv) material+="|$PYENV_REPOSITORY|$PYENV_COMMIT" ;;
    rbenv) material+="|$RBENV_REPOSITORY|$RBENV_COMMIT|$RUBY_BUILD_REPOSITORY|$RUBY_BUILD_COMMIT" ;;
    bun)
      asset=$(platform_asset bun)
      material+="|$BUN_VERSION|$asset" ;;
    yarn) material+="|$YARN_VERSION|$YARN_URL|$YARN_SHA256|$HOME/.local/npm" ;;
    pnpm) material+="|$PNPM_VERSION|$PNPM_URL|$PNPM_SHA256|$HOME/.local/npm" ;;
    fnm)
      asset=$(platform_asset fnm)
      material+="|$FNM_VERSION|$asset" ;;
    plugins)
      asset=$(platform_asset starship)
      material+="|$TARGET|$STARSHIP_VERSION|$asset|$ZSH_AUTOSUGGESTIONS_COMMIT|$ZSH_SYNTAX_HIGHLIGHTING_COMMIT|$ZSH_COMPLETIONS_COMMIT|$FZF_TAB_COMMIT" ;;
    fonts) material+="|$INSTALL_FONTS|${FONT_NAME:-JetBrainsMono}|$NERD_FONTS_COMMIT" ;;
    zsh-config) material+="|loader-v2|$TARGET" ;;
    default-shell) material+="|$CHANGE_DEFAULT_SHELL" ;;
    *) die "Cannot compute state signature for unknown step: $step" ;;
  esac
  printf '%s' "$material" | hash_text
}

install_locked_archive_binary() {
  local tool=$1 extension=$2 destination=$3 url sha temp archive binary asset
  asset=$(platform_asset "$tool")
  local IFS=$'\t'
  read -r url sha <<< "$asset"
  temp=$(mktemp -d)
  archive="$temp/$tool.$extension"
  download_verified "$url" "$sha" "$archive"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would extract verified $tool to $destination"
    rmdir "$temp" 2>/dev/null || true
    return 0
  fi
  mkdir -p "$temp/extract"
  case $extension in
    zip) unzip -q "$archive" -d "$temp/extract" ;;
    tar.gz) tar -xzf "$archive" -C "$temp/extract" ;;
    *) die "Unsupported archive extension: $extension" ;;
  esac
  binary=$(find "$temp/extract" -type f -name "$tool" -print | sed -n '1p')
  [[ -n $binary ]] || die "Verified $tool archive did not contain its executable"
  mkdir -p "$(dirname -- "$destination")"
  install -m 755 "$binary" "$destination"
  rm -rf "$temp"
}

install_bun() {
  install_locked_archive_binary bun zip "$HOME/.local/bin/bun"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/bin/bun" --version | grep -qx "$BUN_VERSION" || die "Bun version verification failed"
}

install_fnm() {
  install_locked_archive_binary fnm zip "$HOME/.local/bin/fnm"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/bin/fnm" --version | grep -qx "fnm $FNM_VERSION" || die "fnm version verification failed"
  [[ $DRY_RUN -eq 1 ]] || eval "$("$HOME/.local/bin/fnm" env)"
  run "$HOME/.local/bin/fnm" install --lts
  run "$HOME/.local/bin/fnm" default lts-latest
}

install_starship() {
  install_locked_archive_binary starship tar.gz "$HOME/.local/bin/starship"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/bin/starship" --version | grep -q "starship $STARSHIP_VERSION" || die "Starship version verification failed"
}

resolve_config_path() {
  local path=$1 link directory hops=0
  while [[ -L $path ]]; do
    (( hops += 1 ))
    (( hops <= 40 )) || die "Too many symbolic-link hops while resolving $1"
    link=$(readlink "$path")
    if [[ $link == /* ]]; then
      path=$link
    else
      directory=$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P)
      path="$directory/$link"
    fi
  done
  printf '%s\n' "$path"
}

managed_block_well_formed() {
  local file=$1 marker=$2
  [[ ! -e $file ]] && return 0
  awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin {
      begins++
      if (open || begins > 1) invalid=1
      open=1
      next
    }
    $0 == end {
      ends++
      if (!open || ends > 1) invalid=1
      open=0
      next
    }
    END { exit invalid || open || begins != ends }
  ' "$file"
}

managed_block_equals() {
  local file=$1 marker=$2 expected=$3 actual
  file=$(resolve_config_path "$file")
  managed_block_well_formed "$file" "$marker" || return 1
  [[ -e $file ]] || return 1
  actual=$(awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin { capture=1; found=1; next }
    $0 == end { capture=0; next }
    capture { print }
    END { if (!found) exit 1 }
  ' "$file") || return 1
  [[ $actual == "$expected" ]]
}

install_managed_block() {
  local file=$1 marker=$2 content=$3 tmp mode backup separator=""
  [[ $DRY_RUN -eq 1 ]] && { say "Would install managed block in $file"; return 0; }
  file=$(resolve_config_path "$file")
  mkdir -p "$(dirname -- "$file")"
  managed_block_well_formed "$file" "$marker" || die "Refusing to rewrite malformed managed block in $file"
  managed_block_equals "$file" "$marker" "$content" && return 0
  backup="$file.leos-profiles.bak"
  if [[ -e $file && ! -e $backup ]]; then
    cp -p "$file" "$backup"
  fi
  touch "$file"
  if [[ $(uname -s) == Darwin ]]; then
    mode=$(/usr/bin/stat -f '%Lp' "$file")
  else
    mode=$(stat -c '%a' "$file")
  fi
  tmp="$file.leos-profiles.tmp.$$"
  awk -v begin="# >>> leos-profiles ${marker} >>>" -v end="# <<< leos-profiles ${marker} <<<" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp"
  if [[ -s $tmp ]] && [[ -n $(tail -n 1 "$tmp") ]]; then separator=$'\n'; fi
  printf '%s# >>> leos-profiles %s >>>\n%s\n# <<< leos-profiles %s <<<\n' "$separator" "$marker" "$content" "$marker" >> "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
}

zshrc_managed_content() {
  local quoted_target
  printf -v quoted_target '%q' "$TARGET"
  printf '%s\n' "if [[ -z \${LEOS_PROFILES_HOME:-} ]]; then
  LEOS_PROFILES_HOME=$quoted_target
fi
if [[ -o interactive ]]; then
  source \"\$LEOS_PROFILES_HOME/zsh/start.zsh\"
fi"
}

zshenv_managed_content() {
  # These are intentional zsh runtime expansions.
  # shellcheck disable=SC2016
  printf '%s\n' 'typeset -U path
path=("$HOME/.local/bin" "$HOME/.local/npm/bin" $path)
export PATH'
}

install_zsh_config() {
  local zshrc_content zshenv_content
  zshrc_content=$(zshrc_managed_content)
  zshenv_content=$(zshenv_managed_content)
  install_managed_block "$HOME/.zshrc" loader "$zshrc_content"
  install_managed_block "$HOME/.zshenv" environment "$zshenv_content"
}

install_credential_prerequisites() {
  [[ $SSH_MODE == skip && $GPG_MODE == skip ]] && return 0
  case $OS_FAMILY in
    macos)
      ensure_brew
      run brew install gh
      [[ $GPG_MODE == skip ]] || run brew install gnupg ;;
    apt)
      ensure_sudo
      run sudo apt-get update
      run sudo apt-get install -y gh
      [[ $GPG_MODE == skip ]] || run sudo apt-get install -y gnupg ;;
    fedora)
      ensure_sudo
      run sudo dnf install -y gh
      [[ $GPG_MODE == skip ]] || run sudo dnf install -y gnupg2 ;;
    arch)
      ensure_sudo
      run sudo pacman -S --needed --noconfirm github-cli
      [[ $GPG_MODE == skip ]] || run sudo pacman -S --needed --noconfirm gnupg ;;
  esac
}

ensure_git_identity() {
  local existing_name existing_email
  existing_name=$(git config --global user.name || true)
  existing_email=$(git config --global user.email || true)
  if [[ -z $existing_name ]]; then
    [[ -n $GIT_NAME ]] || die "GPG provisioning needs a Git name; pass --git-name"
    run git config --global user.name "$GIT_NAME"
  fi
  if [[ -z $existing_email ]]; then
    [[ -n $GIT_EMAIL ]] || die "GPG provisioning needs a Git email; pass --git-email"
    run git config --global user.email "$GIT_EMAIL"
  fi
}

ssh_public_material() {
  awk 'NF >= 2 { print $1 " " $2; exit }' "$1"
}

github_ssh_key_present() {
  local public_key=$1 material
  material=$(ssh_public_material "$public_key")
  [[ -n $material ]] || return 1
  gh api --paginate user/keys --jq '.[].key' 2>/dev/null | \
    awk 'NF >= 2 { print $1 " " $2 }' | grep -qxF "$material"
}

ensure_github_auth() {
  gh auth status >/dev/null 2>&1 && return 0
  gh auth login --hostname github.com --git-protocol https --web
  gh auth status >/dev/null 2>&1 || die "GitHub CLI authentication did not complete"
}

verify_github_api() {
  gh api user --jq '.login' >/dev/null 2>&1 || die "GitHub API authentication/connectivity verification failed"
}

provision_ssh() {
  [[ $SSH_MODE == skip ]] && return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would provision SSH mode '$SSH_MODE' and verify GitHub authentication"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || die "SSH provisioning requires gh; install/authenticate it first"
  ensure_github_auth
  verify_github_api
  local key="" existing_generate=0
  if [[ $SSH_MODE == reuse ]]; then
    key=$SSH_KEY_PATH
    [[ -f $key ]] || die "Chosen SSH private key does not exist: $key"
  else
    key="$HOME/.ssh/id_ed25519"
    if [[ -e $key || -e $key.pub ]]; then
      [[ -f $key && -f $key.pub ]] || die "Refusing a partial existing SSH key pair at $key"
      existing_generate=1
      say "Found an existing default SSH key pair; it will be reused only if GitHub already has it"
    else
      run mkdir -p "$HOME/.ssh"
      [[ $DRY_RUN -eq 1 ]] || chmod 700 "$HOME/.ssh"
      if [[ $SSH_PASSPHRASE_MODE == prompt ]]; then
        run ssh-keygen -t ed25519 -f "$key"
      else
        run ssh-keygen -t ed25519 -f "$key" -N "" -q
      fi
    fi
  fi
  local derived_public
  derived_public=$(mktemp)
  if [[ $DRY_RUN -eq 0 ]]; then
    ssh-keygen -y -f "$key" > "$derived_public"
  fi
  if [[ ! -f "$key.pub" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would derive public key: $key.pub"
    else
      mv -f "$derived_public" "$key.pub"
      chmod 644 "$key.pub"
      derived_public=""
    fi
  elif [[ $DRY_RUN -eq 0 ]] && [[ $(ssh_public_material "$derived_public") != $(ssh_public_material "$key.pub") ]]; then
    rm -f "$derived_public"
    die "Existing public key does not match the selected private key: $key.pub"
  fi
  [[ -z $derived_public ]] || rm -f "$derived_public"
  local title
  title="leos-profiles-$(hostname)-$(date +%Y%m%d)"
  local key_present=0
  github_ssh_key_present "$key.pub" && key_present=1
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would add selected SSH key to GitHub as $title"
  elif (( existing_generate && ! key_present )); then
    die "The existing default SSH key is not on GitHub; use --ssh reuse --ssh-key $key to select it explicitly"
  elif (( ! key_present )); then
    gh ssh-key add "$key.pub" --title "$title" || die "GitHub rejected SSH-key upload"
  fi
  local ssh_output
  ssh_output=$(ssh -i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)
  grep -q 'successfully authenticated' <<< "$ssh_output" || die "SSH key upload did not produce GitHub authentication"
  gh config set git_protocol ssh --host github.com
}

gpg_secret_fingerprint() {
  gpg --batch --with-colons --list-secret-keys "$1" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'
}

gpg_key_has_email() {
  local fingerprint=$1 email=$2
  gpg --batch --with-colons --list-keys "$fingerprint" 2>/dev/null | awk -F: -v email="<$email>" '
    BEGIN { email=tolower(email) }
    /^uid:/ && index(tolower($10), email) { found=1 }
    END { exit !found }
  '
}

github_gpg_key_present() {
  local fingerprint=$1
  gh api --paginate user/gpg_keys --jq '.[].key_id' 2>/dev/null | awk -v fingerprint="$fingerprint" '
    BEGIN { fingerprint=toupper(fingerprint) }
    {
      remote=toupper($0)
      if (length(remote) <= length(fingerprint) &&
          substr(fingerprint, length(fingerprint) - length(remote) + 1) == remote) found=1
    }
    END { exit !found }
  '
}

provision_gpg() {
  [[ $GPG_MODE == skip ]] && return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would provision GPG mode '$GPG_MODE', configure Git signing, upload the public key, and sign a verification commit"
    return 0
  fi
  command -v gpg >/dev/null 2>&1 || die "GPG provisioning requires gpg; install it first"
  command -v gh >/dev/null 2>&1 || die "GPG provisioning requires gh; install/authenticate it first"
  ensure_github_auth
  verify_github_api
  ensure_git_identity
  local name email keyid="" candidate creation_output exported_key
  name=$(git config --global user.name || true)
  email=$(git config --global user.email || true)
  [[ -n $name && -n $email ]] || die "Set global git user.name and user.email before GPG provisioning"
  if [[ $GPG_MODE == reuse ]]; then
    keyid=$(gpg_secret_fingerprint "$GPG_KEY_ID")
    [[ -n $keyid ]] || die "The selected GPG secret key was not found: $GPG_KEY_ID"
  else
    while IFS= read -r candidate; do
      if [[ -n $candidate ]] && github_gpg_key_present "$candidate"; then
        keyid=$candidate
        say "Reusing an already-provisioned GPG key for $email: $keyid"
        break
      fi
    done < <(gpg --batch --with-colons --list-secret-keys "<$email>" 2>/dev/null | \
      awk -F: '/^sec:/{want=1; next} want && /^fpr:/{print $10; want=0}')
    if [[ -z $keyid ]]; then
      if [[ $GPG_PASSPHRASE_MODE == prompt ]]; then
        creation_output=$(gpg --status-fd 1 --quick-generate-key "$name <$email>" ed25519 sign never)
      else
        creation_output=$(gpg --batch --status-fd 1 --pinentry-mode loopback --passphrase '' --quick-generate-key "$name <$email>" ed25519 sign never)
      fi
      keyid=$(awk '$2 == "KEY_CREATED" {print $4; exit}' <<< "$creation_output")
    fi
  fi
  [[ -n $keyid ]] || die "No matching GPG secret key found"
  gpg_key_has_email "$keyid" "$email" || die "Selected GPG key has no user ID for the Git email $email"
  local temp_repo
  temp_repo=$(mktemp -d)
  git -C "$temp_repo" init -q
  git -C "$temp_repo" config user.name "$name"
  git -C "$temp_repo" config user.email "$email"
  git -C "$temp_repo" config gpg.format openpgp
  git -C "$temp_repo" config user.signingkey "$keyid"
  git -C "$temp_repo" config commit.gpgsign true
  if ! git -C "$temp_repo" commit --allow-empty -S -m 'Verify Leo profiles signing setup' >/dev/null; then
    rm -rf "$temp_repo"
    die "GPG key cannot sign a Git commit"
  fi
  rm -rf "$temp_repo"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would export and add GPG key $keyid to GitHub"
  elif ! github_gpg_key_present "$keyid"; then
    exported_key=$(mktemp)
    gpg --armor --export "$keyid" > "$exported_key"
    if ! gh gpg-key add "$exported_key"; then
      rm -f "$exported_key"
      die "GitHub rejected GPG-key upload"
    fi
    rm -f "$exported_key"
  fi
  git config --global user.signingkey "$keyid"
  git config --global gpg.format openpgp
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
}

current_login_shell() {
  local current_shell
  current_shell=$(getent passwd "$USER" 2>/dev/null | awk -F: '{print $7}' || true)
  [[ -n $current_shell ]] || current_shell=$(dscl . -read /Users/"$USER" UserShell 2>/dev/null | awk '{print $2}' || true)
  printf '%s\n' "$current_shell"
}

set_default_shell() {
  [[ $CHANGE_DEFAULT_SHELL == no ]] && { say "Skipping default shell (--default-shell no)"; return 0; }
  local zsh_path
  zsh_path=$(command -v zsh || true)
  if [[ -z $zsh_path && $DRY_RUN -eq 1 ]]; then
    say "Would configure the zsh path installed by the package step as the login shell"
    return 0
  fi
  [[ -n $zsh_path ]] || die "zsh is not installed"
  if [[ $CHANGE_DEFAULT_SHELL == auto ]]; then
    local current_shell
    current_shell=$(current_login_shell)
    [[ $current_shell == *zsh ]] && { say "Default shell is already zsh"; return 0; }
  fi
  if [[ $OS_FAMILY == macos ]]; then
    grep -qxF "$zsh_path" /etc/shells || run_shell "Add $zsh_path to /etc/shells" "printf '%s\\n' '$zsh_path' | sudo tee -a /etc/shells >/dev/null"
    run sudo chsh -s "$zsh_path" "$USER"
  else
    grep -qxF "$zsh_path" /etc/shells || run_shell "Add $zsh_path to /etc/shells" "printf '%s\\n' '$zsh_path' | sudo tee -a /etc/shells >/dev/null"
    run chsh -s "$zsh_path"
  fi
}

git_checkout_at() {
  local directory=$1 repository=$2 commit=$3 origin
  [[ -d $directory/.git ]] || return 1
  origin=$(git -C "$directory" remote get-url origin 2>/dev/null || true)
  [[ $origin == "$repository" ]] || return 1
  [[ -z $(git -C "$directory" status --porcelain) ]] || return 1
  [[ $(git -C "$directory" rev-parse HEAD 2>/dev/null || true) == "$commit" ]]
}

font_is_installed() {
  local font=${FONT_NAME:-JetBrainsMono} directory
  if [[ $OS_FAMILY == macos ]]; then
    directory="$HOME/Library/Fonts"
  else
    directory="$HOME/.local/share/fonts"
  fi
  [[ -d $directory ]] && find "$directory" -type f -iname "*${font}*NerdFont*" -print -quit | grep -q .
}

verify_step() {
  local step=$1 directory
  case $step in
    bins)
      [[ -x $HOME/.local/bin/rpatool ]] && [[ $(sha256 "$HOME/.local/bin/rpatool") == "$RPATOOL_SHA256" ]] ;;
    packages) selected_packages_installed ;;
    pyenv)
      [[ -x $HOME/.pyenv/bin/pyenv ]] && git_checkout_at "$HOME/.pyenv" "$PYENV_REPOSITORY" "$PYENV_COMMIT" ;;
    rbenv)
      [[ -x $HOME/.rbenv/bin/rbenv ]] &&
        git_checkout_at "$HOME/.rbenv" "$RBENV_REPOSITORY" "$RBENV_COMMIT" &&
        git_checkout_at "$HOME/.rbenv/plugins/ruby-build" "$RUBY_BUILD_REPOSITORY" "$RUBY_BUILD_COMMIT" ;;
    bun)
      [[ -x $HOME/.local/bin/bun ]] && "$HOME/.local/bin/bun" --version 2>/dev/null | grep -qx "$BUN_VERSION" ;;
    yarn)
      [[ -x $HOME/.local/npm/bin/yarn ]] && "$HOME/.local/npm/bin/yarn" --version 2>/dev/null | grep -qx "$YARN_VERSION" ;;
    pnpm)
      [[ -x $HOME/.local/npm/bin/pnpm ]] && "$HOME/.local/npm/bin/pnpm" --version 2>/dev/null | grep -qx "$PNPM_VERSION" ;;
    fnm)
      [[ -x $HOME/.local/bin/fnm ]] &&
        "$HOME/.local/bin/fnm" --version 2>/dev/null | grep -qx "fnm $FNM_VERSION" &&
        [[ -e ${XDG_DATA_HOME:-$HOME/.local/share}/fnm/aliases/default ]] ;;
    plugins)
      [[ -x $HOME/.local/bin/starship ]] &&
        "$HOME/.local/bin/starship" --version 2>/dev/null | sed -n '1p' | grep -qx "starship $STARSHIP_VERSION" &&
        directory="$TARGET/zsh/plugins" &&
        git_checkout_at "$directory/zsh-autosuggestions" "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$ZSH_AUTOSUGGESTIONS_COMMIT" &&
        git_checkout_at "$directory/zsh-syntax-highlighting" "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" &&
        git_checkout_at "$directory/zsh-completions" "$ZSH_COMPLETIONS_REPOSITORY" "$ZSH_COMPLETIONS_COMMIT" &&
        git_checkout_at "$directory/fzf-tab" "$FZF_TAB_REPOSITORY" "$FZF_TAB_COMMIT" ;;
    fonts)
      ! font_should_install || font_is_installed ;;
    zsh-config)
      managed_block_equals "$HOME/.zshrc" loader "$(zshrc_managed_content)" &&
        managed_block_equals "$HOME/.zshenv" environment "$(zshenv_managed_content)" ;;
    default-shell)
      if [[ $CHANGE_DEFAULT_SHELL == no ]]; then
        return 0
      elif [[ $CHANGE_DEFAULT_SHELL == auto ]]; then
        [[ $(current_login_shell) == */zsh ]]
      else
        [[ $(current_login_shell) == "$(command -v zsh)" ]]
      fi ;;
    *) return 1 ;;
  esac
}

run_step() {
  local step=$1
  if state_done "$step" && [[ $REPAIR -eq 0 ]] && verify_step "$step"; then
    say "Skipping $step (recorded complete and verified)"
    return 0
  fi
  if state_done "$step" && [[ $REPAIR -eq 0 ]]; then
    warn "$step was recorded complete but failed verification; repairing it"
  fi
  say "Running $step"
  case $step in
    bins) install_local_bins ;;
    packages) install_os_packages ;;
    pyenv) install_pyenv ;;
    rbenv) install_rbenv ;;
    bun) install_bun ;;
    yarn) install_yarn ;;
    pnpm) install_pnpm ;;
    fnm) install_fnm ;;
    plugins) install_starship; install_plugins ;;
    fonts) install_fonts ;;
    zsh-config) install_zsh_config ;;
    default-shell) set_default_shell ;;
    *) die "Unknown step: $step" ;;
  esac
  [[ $DRY_RUN -eq 1 ]] || verify_step "$step" || die "$step did not pass post-install verification"
  mark_done "$step"
}

main() {
  validate_options
  normalise_dependencies
  order_selected_steps
  detect_os
  confirm_plan
  [[ $PLAN_ONLY -eq 0 ]] || exit 0
  bootstrap_tools
  ensure_target
  install_credential_prerequisites
  provision_ssh
  provision_gpg
  local step old_ifs=$IFS
  IFS=,
  for step in $SELECTED_STEPS; do
    run_step "$step"
  done
  IFS=$old_ifs
  say "Installation complete. Restart the terminal; default-shell changes apply at next login."
}

if [[ ${LEOS_PROFILES_INSTALL_LIB_ONLY:-0} != 1 ]]; then
  main
fi
