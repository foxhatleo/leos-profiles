#!/usr/bin/env bash
# Leo's Profiles deterministic installer.
#
# This is the deterministic execution engine for the AI-led QUICK-INSTALL.md.
# The checkout containing this file is the profile being installed.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=installer/lock.sh
source "$SCRIPT_DIR/installer/lock.sh"

TARGET=$SCRIPT_DIR
LOCAL_DIR="$TARGET/local"
PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
STATE_FILE="$LOCAL_DIR/install-state.tsv"
LOCK_DIR="$LOCAL_DIR/.install.lock"
LEGACY_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/leos-profiles/install-state.tsv"

COMMAND=""
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
FULL_UPGRADE=1
SAVED_FULL_UPGRADE=yes
OS_FAMILY=""
SSH_KEY_PATH=""
GIT_NAME=""
GIT_EMAIL=""
FONT_NAME=""
RESOLVED_NODE_VERSION=""
NODE_CHANNEL="current-lts"
AI_CLI_UPDATE_CHANNEL="native"
PACKAGE_CHANNEL="system"
SELECTED_PACKAGES=()
TEMP_PATHS=()
LOCK_HELD=0

say() { printf '%s\n' "==> $*"; }
warn() { printf '%s\n' "WARNING: $*" >&2; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  bash install.sh inspect [options]
  bash install.sh apply --yes [options]
  bash install.sh reconcile --yes [--full-upgrade]

Options:
  --groups <csv|none>             bins,packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell
  --package-groups <csv|none>     core-utils,shell,dev-tools,languages,media,network,system
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
  --full-upgrade                  Run the host package-manager upgrade phase
  --no-full-upgrade               Install/reconcile packages without a host upgrade
  --dry-run                       Print mutations without performing them
  --yes                           Confirm that the AI-presented plan was approved
  --help                          Show this help

The AI runbook is the supported user interface. `inspect` emits typed TSV for
agents and diagnostics; `apply` and `reconcile` never ask setup questions.
EOF
}

require_value() {
  [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

parse_args() {
  [[ $# -gt 0 ]] || { usage >&2; exit 2; }
  case $1 in
    inspect|apply|reconcile) COMMAND=$1; shift ;;
    --target|--ref|--steps|--repair|--plan|--allow-mutable-ref)
      die "$1 belongs to the retired ref/target CLI; use the AI runbook with this local checkout" ;;
    --help|-h) usage; exit 0 ;;
    *) die "Expected inspect, apply, or reconcile; the AI runbook is the setup interface" ;;
  esac
  if [[ $COMMAND == reconcile ]]; then FULL_UPGRADE=0; fi
  while [[ $# -gt 0 ]]; do
    if [[ $COMMAND == reconcile ]]; then
      case $1 in
        --full-upgrade) FULL_UPGRADE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --target|--ref|--steps|--repair|--plan|--allow-mutable-ref)
          die "$1 belongs to the retired ref/target CLI; use reconcile with the saved local profile" ;;
        --help|-h) usage; exit 0 ;;
        *) die "reconcile reads the saved local profile and only accepts --yes, --full-upgrade, or --dry-run" ;;
      esac
      continue
    fi
    case $1 in
    --groups) require_value "$1" "${2:-}"; SELECTED_STEPS=$2; [[ $SELECTED_STEPS != none ]] || SELECTED_STEPS=""; shift 2 ;;
    --package-groups) require_value "$1" "${2:-}"; SELECTED_GROUPS=$2; [[ $SELECTED_GROUPS != none ]] || SELECTED_GROUPS=""; shift 2 ;;
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
    --full-upgrade) FULL_UPGRADE=1; shift ;;
    --no-full-upgrade) FULL_UPGRADE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --target|--ref|--steps|--repair|--plan|--allow-mutable-ref)
      die "$1 belongs to the retired ref/target CLI; use the AI runbook with this local checkout" ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
    esac
  done
}

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
  has_csv_item "$current" "$item" || printf -v "$variable_name" '%s' "${current:+$current,}$item"
}

normalise_dependencies() {
  # Selecting any package group selects the package executor itself.
  [[ -z $SELECTED_GROUPS ]] || add_csv_item SELECTED_STEPS packages
  if has_csv_item "$SELECTED_STEPS" pyenv || has_csv_item "$SELECTED_STEPS" rbenv; then
    add_csv_item SELECTED_STEPS packages
    add_csv_item SELECTED_GROUPS dev-tools
  fi
  if has_csv_item "$SELECTED_STEPS" yarn || has_csv_item "$SELECTED_STEPS" pnpm || \
     has_csv_item "$SELECTED_STEPS" bun || has_csv_item "$SELECTED_STEPS" fnm || \
     has_csv_item "$SELECTED_STEPS" bins; then
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
  [[ -z $SELECTED_STEPS ]] || valid_csv "$SELECTED_STEPS" "bins,packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell" || die "Invalid --groups value"
  [[ -z $SELECTED_GROUPS ]] || valid_csv "$SELECTED_GROUPS" "core-utils,shell,dev-tools,languages,media,network,system" || die "Invalid --package-groups value"
  [[ $SSH_MODE == skip || $SSH_MODE == reuse || $SSH_MODE == generate ]] || die "Invalid --ssh value"
  [[ $SSH_PASSPHRASE_MODE == empty || $SSH_PASSPHRASE_MODE == prompt ]] || die "Invalid --ssh-passphrase value"
  [[ $GPG_MODE == skip || $GPG_MODE == reuse || $GPG_MODE == generate ]] || die "Invalid --gpg value"
  [[ $GPG_PASSPHRASE_MODE == empty || $GPG_PASSPHRASE_MODE == prompt ]] || die "Invalid --gpg-passphrase value"
  [[ $INSTALL_FONTS == auto || $INSTALL_FONTS == yes || $INSTALL_FONTS == no ]] || die "Invalid --fonts value"
  [[ $CHANGE_DEFAULT_SHELL == auto || $CHANGE_DEFAULT_SHELL == yes || $CHANGE_DEFAULT_SHELL == no ]] || die "Invalid --default-shell value"
  [[ $SSH_MODE != reuse || -n $SSH_KEY_PATH ]] || die "--ssh reuse requires --ssh-key <private-key-path>"
  [[ $GPG_MODE != reuse || -n $GPG_KEY_ID ]] || die "--gpg reuse requires --gpg-key <fingerprint>"
  [[ $INSTALL_FONTS != yes || -n $FONT_NAME ]] || die "--fonts yes requires --font <name>"
  [[ $SSH_MODE != reuse || $SSH_KEY_PATH == /* ]] || die "--ssh-key must be an absolute path"
  [[ -z $FONT_NAME || $FONT_NAME =~ ^[A-Za-z0-9_-]+$ ]] || die "--font must be a Nerd Fonts directory name"
  [[ $NODE_CHANNEL == current-lts ]] || die "Unsupported Node channel in saved profile: $NODE_CHANNEL"
  [[ $AI_CLI_UPDATE_CHANNEL == native ]] || die "Unsupported AI CLI update channel in saved profile: $AI_CLI_UPDATE_CHANNEL"
  [[ $PACKAGE_CHANNEL == system ]] || die "Unsupported package channel in saved profile: $PACKAGE_CHANNEL"
  [[ $SAVED_FULL_UPGRADE == yes || $SAVED_FULL_UPGRADE == no ]] || die "Invalid saved full-upgrade preference: $SAVED_FULL_UPGRADE"
  validate_tsv_value groups "$SELECTED_STEPS"
  validate_tsv_value package-groups "$SELECTED_GROUPS"
  validate_tsv_value ssh-key "$SSH_KEY_PATH"
  validate_tsv_value gpg-key "$GPG_KEY_ID"
  validate_tsv_value git-name "$GIT_NAME"
  validate_tsv_value git-email "$GIT_EMAIL"
  validate_tsv_value profile-root "$TARGET"
}

validate_tsv_value() {
  local label=$1 value=$2
  [[ $value != *$'\t'* && $value != *$'\n'* && $value != *$'\r'* ]] ||
    die "$label may not contain tabs or newlines"
}

prepare_local_dir() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  mkdir -p "$LOCAL_DIR/flags"
  chmod 700 "$LOCAL_DIR" "$LOCAL_DIR/flags"
}

track_temp() { TEMP_PATHS+=("$1"); }

cleanup() {
  local path
  for path in "${TEMP_PATHS[@]-}"; do [[ -z $path ]] || rm -rf -- "$path"; done
  if [[ $LOCK_HELD -eq 1 && -d $LOCK_DIR ]]; then rm -rf -- "$LOCK_DIR"; fi
}

acquire_lock() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  prepare_local_dir
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    chmod 600 "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
  fi
  local owner=""
  [[ -f $LOCK_DIR/pid ]] && owner=$(sed -n '1p' "$LOCK_DIR/pid")
  if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf -- "$LOCK_DIR"
    mkdir "$LOCK_DIR"
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    chmod 600 "$LOCK_DIR/pid"
    LOCK_HELD=1
    return 0
  fi
  die "Another Leo's Profiles operation is running${owner:+ (PID $owner)}"
}

write_profile() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  local tmp
  prepare_local_dir
  tmp=$(mktemp "$LOCAL_DIR/.install-profile.tmp.XXXXXX")
  track_temp "$tmp"
  {
    printf 'schema\t1\n'
    printf 'groups\t%s\n' "$SELECTED_STEPS"
    printf 'package-groups\t%s\n' "$SELECTED_GROUPS"
    printf 'full-upgrade\t%s\n' "$SAVED_FULL_UPGRADE"
    printf 'fonts\t%s\n' "$INSTALL_FONTS"
    printf 'font\t%s\n' "$FONT_NAME"
    printf 'default-shell\t%s\n' "$CHANGE_DEFAULT_SHELL"
    printf 'git-name\t%s\n' "$GIT_NAME"
    printf 'git-email\t%s\n' "$GIT_EMAIL"
    printf 'ssh\t%s\n' "$SSH_MODE"
    printf 'ssh-key\t%s\n' "$SSH_KEY_PATH"
    printf 'ssh-passphrase\t%s\n' "$SSH_PASSPHRASE_MODE"
    printf 'gpg\t%s\n' "$GPG_MODE"
    printf 'gpg-key\t%s\n' "$GPG_KEY_ID"
    printf 'gpg-passphrase\t%s\n' "$GPG_PASSPHRASE_MODE"
    printf 'node-channel\t%s\n' "$NODE_CHANNEL"
    printf 'ai-cli-update-channel\t%s\n' "$AI_CLI_UPDATE_CHANNEL"
    printf 'package-channel\t%s\n' "$PACKAGE_CHANNEL"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROFILE_FILE"
}

read_profile() {
  [[ -f $PROFILE_FILE ]] || die "No saved install profile. Run the AI setup flow first: $PROFILE_FILE"
  local key value extra schema="" seen=","
  while IFS=$'\t' read -r key value extra || [[ -n $key ]]; do
    [[ -z ${extra:-} ]] || die "Malformed install profile row: $key"
    validate_tsv_value "$key" "${value:-}"
    [[ $seen != *",$key,"* ]] || die "Duplicate install profile key: $key"
    seen+="$key,"
    case $key in
      schema) schema=$value ;;
      groups) SELECTED_STEPS=$value ;;
      package-groups) SELECTED_GROUPS=$value ;;
      full-upgrade) SAVED_FULL_UPGRADE=$value ;;
      fonts) INSTALL_FONTS=$value ;;
      font) FONT_NAME=$value ;;
      default-shell) CHANGE_DEFAULT_SHELL=$value ;;
      git-name) GIT_NAME=$value ;;
      git-email) GIT_EMAIL=$value ;;
      ssh) SSH_MODE=$value ;;
      ssh-key) SSH_KEY_PATH=$value ;;
      ssh-passphrase) SSH_PASSPHRASE_MODE=$value ;;
      gpg) GPG_MODE=$value ;;
      gpg-key) GPG_KEY_ID=$value ;;
      gpg-passphrase) GPG_PASSPHRASE_MODE=$value ;;
      node-channel) NODE_CHANNEL=$value ;;
      ai-cli-update-channel) AI_CLI_UPDATE_CHANNEL=$value ;;
      package-channel) PACKAGE_CHANNEL=$value ;;
      '') ;;
      *) die "Unknown install profile key: $key" ;;
    esac
  done < "$PROFILE_FILE"
  [[ $schema == 1 ]] || die "Unsupported install profile schema: ${schema:-missing}"
}

migrate_one_local_file() {
  local legacy=$1 destination=$2
  [[ -e $legacy || -L $legacy ]] || return 0
  if [[ -e $destination || -L $destination ]]; then
    cmp -s "$legacy" "$destination" || die "Conflicting local settings: $legacy and $destination"
    rm -f -- "$legacy"
    return 0
  fi
  mkdir -p "$(dirname -- "$destination")"
  mv -- "$legacy" "$destination"
  chmod 600 "$destination"
}

migrate_local_state() {
  [[ $DRY_RUN -eq 0 ]] || return 0
  prepare_local_dir
  if [[ -f $LEGACY_STATE_FILE && ! -e $STATE_FILE ]]; then
    cp -p "$LEGACY_STATE_FILE" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    rm -f "$LEGACY_STATE_FILE"
  elif [[ -f $LEGACY_STATE_FILE && -f $STATE_FILE ]]; then
    cmp -s "$LEGACY_STATE_FILE" "$STATE_FILE" ||
      die "Conflicting installer state: $LEGACY_STATE_FILE and $STATE_FILE"
    rm -f "$LEGACY_STATE_FILE"
  fi
  migrate_one_local_file "$TARGET/zsh/_private.zsh" "$LOCAL_DIR/private.zsh"
  migrate_one_local_file "$HOME/.brew-china" "$LOCAL_DIR/flags/brew-china"
  migrate_one_local_file "$HOME/.lp-no-gnu" "$LOCAL_DIR/flags/no-gnu"
  migrate_one_local_file "$HOME/.lp-nobrew" "$LOCAL_DIR/flags/no-brew"
  migrate_one_local_file "$HOME/.lp-nopyenv" "$LOCAL_DIR/flags/no-pyenv"
  migrate_one_local_file "$HOME/.lp-norbenv" "$LOCAL_DIR/flags/no-rbenv"
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
  run mkdir -p "$(dirname -- "$destination")"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would download and SHA-256 verify $url"
    return 0
  fi
  tmp=$(mktemp "$(dirname -- "$destination")/.$(basename -- "$destination").tmp.XXXXXX")
  track_temp "$tmp"
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
  local step=$1 signature tmp detail=""
  [[ $DRY_RUN -eq 1 ]] && return 0
  signature=$(step_signature "$step")
  prepare_local_dir
  tmp=$(mktemp "$LOCAL_DIR/.install-state.tmp.XXXXXX")
  track_temp "$tmp"
  if [[ -f $STATE_FILE ]]; then
    awk -F '\t' -v step="$step" '$1 != step' "$STATE_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  [[ $step != fnm ]] || detail=$RESOLVED_NODE_VERSION
  printf '%s\t%s\t%s\t%s\n' "$step" "$signature" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detail" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

ensure_sudo() {
  [[ $OS_FAMILY == macos ]] && return 0
  [[ $DRY_RUN -eq 1 ]] || sudo -v
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  local installer
  installer=$(mktemp "${TMPDIR:-/tmp}/leos-homebrew-install.XXXXXX")
  track_temp "$installer"
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
      run sudo pacman -S --needed --noconfirm git curl ca-certificates unzip ;;
  esac
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
    fedora) rpm -q --whatprovides "$package" >/dev/null 2>&1 ;;
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
      if [[ $FULL_UPGRADE -eq 1 ]]; then
        run brew update
        run brew upgrade
        run brew upgrade --cask
      fi
      run brew install "${SELECTED_PACKAGES[@]}" ;;
    apt)
      run sudo apt-get update
      [[ $FULL_UPGRADE -eq 0 ]] || run sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${SELECTED_PACKAGES[@]}"
      run mkdir -p "$HOME/.local/bin"
      if [[ $DRY_RUN -eq 0 ]]; then
        command -v fd >/dev/null 2>&1 || { command -v fdfind >/dev/null 2>&1 && ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"; }
        command -v bat >/dev/null 2>&1 || { command -v batcat >/dev/null 2>&1 && ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"; }
      fi ;;
    fedora)
      [[ $FULL_UPGRADE -eq 0 ]] || run sudo dnf upgrade -y
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
      [[ $FULL_UPGRADE -eq 0 ]] || run sudo pacman -Syu --noconfirm
      run sudo pacman -S --needed --noconfirm "${SELECTED_PACKAGES[@]}" ;;
  esac
}

github_repo_slug() {
  local url=$1 slug
  case $url in
    https://github.com/*) slug=${url#https://github.com/} ;;
    git@github.com:*) slug=${url#git@github.com:} ;;
    ssh://git@github.com/*) slug=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  slug=${slug%/}
  slug=${slug%.git}
  [[ $slug == */* && $slug != */*/* ]] || return 1
  printf '%s\n' "$slug" | tr '[:upper:]' '[:lower:]'
}

github_origins_equivalent() {
  local actual expected actual_slug expected_slug
  actual=$1
  expected=$2
  actual_slug=$(github_repo_slug "$actual") || return 1
  expected_slug=$(github_repo_slug "$expected") || return 1
  [[ $actual_slug == "$expected_slug" ]]
}

clone_pinned() {
  local repository=$1 commit=$2 destination=$3 label=$4 origin
  if [[ -d $destination ]]; then
    [[ -d $destination/.git ]] || die "$label exists but is not a Git checkout: $destination"
    origin=$(git -C "$destination" remote get-url origin 2>/dev/null || true)
    github_origins_equivalent "$origin" "$repository" || die "$label checkout has an unexpected origin: $destination"
    [[ -z $(git -C "$destination" status --porcelain) ]] || die "$label checkout has local changes: $destination"
    if [[ $origin != "$repository" ]]; then
      run git -C "$destination" remote set-url origin "$repository"
    fi
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
  track_temp "$temp"
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
  track_temp "$temp"
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
      material+="|$FNM_VERSION|$asset|${RESOLVED_NODE_VERSION:-unresolved}" ;;
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
  track_temp "$temp"
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
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would resolve the current Node LTS once, install that exact version, and make it default"
    return 0
  fi
  resolve_node_lts
  eval "$("$HOME/.local/bin/fnm" env --shell bash)"
  run "$HOME/.local/bin/fnm" install "$RESOLVED_NODE_VERSION"
  run "$HOME/.local/bin/fnm" default "$RESOLVED_NODE_VERSION"
}

resolve_node_lts() {
  [[ -z $RESOLVED_NODE_VERSION ]] || return 0
  local fnm_bin latest
  if command -v curl >/dev/null 2>&1; then
    latest=$(curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
      https://nodejs.org/dist/index.tab 2>/dev/null | awk -F '\t' 'NR > 1 && $10 != "-" { print $1; exit }') || true
  fi
  if [[ ! ${latest:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && -x $HOME/.local/bin/fnm ]]; then
    fnm_bin="$HOME/.local/bin/fnm"
  elif [[ ! ${latest:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fnm_bin=$(command -v fnm 2>/dev/null || true)
  fi
  if [[ ! ${latest:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && -n ${fnm_bin:-} ]]; then
    latest=$("$fnm_bin" list-remote --lts 2>/dev/null | tail -n 1 | awk '{print $1}')
  fi
  [[ ${latest:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not resolve the current Node LTS"
  RESOLVED_NODE_VERSION=$latest
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
  tmp=$(mktemp "$(dirname -- "$file")/.$(basename -- "$file").leos-profiles.tmp.XXXXXX")
  track_temp "$tmp"
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
    existing_name=$GIT_NAME
  fi
  if [[ -z $existing_email ]]; then
    [[ -n $GIT_EMAIL ]] || die "GPG provisioning needs a Git email; pass --git-email"
    run git config --global user.email "$GIT_EMAIL"
    existing_email=$GIT_EMAIL
  fi
  GIT_NAME=$existing_name
  GIT_EMAIL=$existing_email
}

ssh_public_material() {
  awk 'NF >= 2 { print $1 " " $2; exit }' "$1"
}

github_ssh_key_present() {
  local public_key=$1 material remote_keys
  material=$(ssh_public_material "$public_key")
  [[ -n $material ]] || return 1
  remote_keys=$(gh api --paginate user/keys --jq '.[].key') \
    || die "Could not list GitHub SSH keys; refusing to guess (check network and gh auth)"
  awk 'NF >= 2 { print $1 " " $2 }' <<< "$remote_keys" | grep -qxF "$material"
}

ensure_github_auth() {
  gh auth status >/dev/null 2>&1 && return 0
  gh auth login --hostname github.com --git-protocol https --web
  gh auth status >/dev/null 2>&1 || die "GitHub CLI authentication did not complete"
}

verify_github_api() {
  gh api user --jq '.login' >/dev/null 2>&1 || die "GitHub API authentication/connectivity verification failed"
}

github_email_is_verified() {
  local email=$1 verified
  if ! verified=$(gh api user/emails --jq '.[] | select(.verified == true) | .email' 2>/dev/null); then
    die "GitHub email verification requires gh scope user:email; let the AI run: gh auth refresh -s user:email"
  fi
  grep -qxiF "$email" <<< "$verified"
}

ensure_github_known_hosts() {
  local approved scanned verified known_tmp host key_type key material existing
  approved=$(mktemp)
  scanned=$(mktemp)
  verified=$(mktemp)
  track_temp "$approved"
  track_temp "$scanned"
  track_temp "$verified"
  gh api meta --jq '.ssh_keys[]' > "$approved" || die "Could not obtain GitHub's published SSH host keys"
  ssh-keyscan -T 15 -t rsa,ecdsa,ed25519 github.com > "$scanned" 2>/dev/null ||
    die "Could not scan GitHub SSH host keys"
  while read -r host key_type key _; do
    material="$key_type $key"
    grep -qxF "$material" "$approved" && printf '%s %s %s\n' "$host" "$key_type" "$key" >> "$verified"
  done < "$scanned"
  [[ -s $verified ]] || die "GitHub SSH host keys did not match GitHub's published metadata"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  known_tmp=$(mktemp "$HOME/.ssh/.known-hosts.tmp.XXXXXX")
  track_temp "$known_tmp"
  if [[ -f $HOME/.ssh/known_hosts ]]; then cp "$HOME/.ssh/known_hosts" "$known_tmp"; fi
  while read -r host key_type key; do
    material="$key_type $key"
    existing=$(awk 'NF >= 3 { print $2 " " $3 }' "$known_tmp")
    grep -qxF "$material" <<< "$existing" || printf '%s %s %s\n' "$host" "$key_type" "$key" >> "$known_tmp"
  done < "$verified"
  chmod 600 "$known_tmp"
  mv -f "$known_tmp" "$HOME/.ssh/known_hosts"
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
  track_temp "$derived_public"
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
  fi
  # Persist an explicitly reused or newly generated reference before remote
  # upload/testing. A retry then repairs this key without replacing it.
  SSH_KEY_PATH=$key
  SSH_MODE=reuse
  write_profile
  if [[ $DRY_RUN -eq 0 ]] && (( ! key_present )); then
    gh ssh-key add "$key.pub" --title "$title" || die "GitHub rejected SSH-key upload"
  fi
  ensure_github_known_hosts
  local ssh_output
  ssh_output=$(ssh -i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -T git@github.com 2>&1 || true)
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
  local fingerprint=$1 remote_ids
  remote_ids=$(gh api --paginate user/gpg_keys --jq '.[].key_id') \
    || die "Could not list GitHub GPG keys; refusing to guess (check network and gh auth)"
  awk -v fingerprint="$fingerprint" '
    BEGIN { fingerprint=toupper(fingerprint) }
    {
      remote=toupper($0)
      if (length(remote) <= length(fingerprint) &&
          substr(fingerprint, length(fingerprint) - length(remote) + 1) == remote) found=1
    }
    END { exit !found }
  ' <<< "$remote_ids"
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
  github_email_is_verified "$email" || die "Git email is not verified on the authenticated GitHub account: $email"
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
  # Save the fingerprint before signing/upload verification so a partial
  # failure retries this exact key instead of creating another one.
  GPG_KEY_ID=$keyid
  GPG_MODE=reuse
  write_profile
  local temp_repo
  temp_repo=$(mktemp -d)
  track_temp "$temp_repo"
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
    track_temp "$exported_key"
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
  github_origins_equivalent "$origin" "$repository" || return 1
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
  [[ -d $directory ]] || return 1
  # Nerd Fonts renames some families on install (CascadiaCode ships as
  # CaskaydiaCoveNerdFont-*), so fall back to any patched font. The fonts
  # state signature pins the requested family, so a changed selection still
  # re-runs the step.
  find "$directory" -type f -iname "*${font}*NerdFont*" -print -quit | grep -q . ||
    find "$directory" -type f -iname "*NerdFont*" -print -quit | grep -q .
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
      [[ -n $RESOLVED_NODE_VERSION ]] || resolve_node_lts || return 1
      [[ -x $HOME/.local/bin/fnm ]] &&
        "$HOME/.local/bin/fnm" --version 2>/dev/null | grep -qx "fnm $FNM_VERSION" &&
        [[ $("$HOME/.local/bin/fnm" default 2>/dev/null) == "$RESOLVED_NODE_VERSION" ]] &&
        [[ $("$HOME/.local/bin/fnm" exec --using="$RESOLVED_NODE_VERSION" -- node --version 2>/dev/null) == "$RESOLVED_NODE_VERSION" ]] ;;
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
  if [[ ! ( $step == packages && $FULL_UPGRADE -eq 1 ) ]] && state_done "$step" && verify_step "$step"; then
    say "Skipping $step (recorded complete and verified)"
    return 0
  fi
  if state_done "$step"; then
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

inspect_tsv() {
  local step group package status origin asset url digest
  printf 'meta\tschema\t1\n'
  printf 'platform\tfamily\t%s\n' "$OS_FAMILY"
  printf 'profile\troot\t%s\n' "$TARGET"
  printf 'policy\tfull-upgrade\t%s\n' "$([[ $FULL_UPGRADE -eq 1 ]] && printf yes || printf no)"
  printf 'channel\tpackages\t%s\n' "$PACKAGE_CHANNEL"
  printf 'channel\tnode\t%s\n' "$NODE_CHANNEL"
  printf 'channel\tai-cli-updates\t%s\n' "$AI_CLI_UPDATE_CHANNEL"
  printf 'group\tinternal\tbootstrap\tselected\n'
  local canonical="bins,packages,pyenv,rbenv,bun,yarn,pnpm,fnm,plugins,fonts,zsh-config,default-shell"
  local old_ifs=$IFS
  IFS=,
  for step in $canonical; do
    has_csv_item "$SELECTED_STEPS" "$step" || continue
    if has_csv_item "$REQUESTED_STEPS" "$step"; then origin=selected; else origin=implied; fi
    printf 'group\tcomponent\t%s\t%s\n' "$step" "$origin"
  done
  for group in core-utils shell dev-tools languages media network system; do
    has_csv_item "$SELECTED_GROUPS" "$group" || continue
    if has_csv_item "$REQUESTED_GROUPS" "$group"; then origin=selected; else origin=implied; fi
    printf 'group\tpackage\t%s\t%s\n' "$group" "$origin"
  done
  IFS=$old_ifs
  printf 'group\tcredential\tssh\t%s\n' "$SSH_MODE"
  printf 'group\tcredential\tgpg\t%s\n' "$GPG_MODE"
  collect_selected_packages
  if (( ${#SELECTED_PACKAGES[@]} > 0 )); then
    for package in "${SELECTED_PACKAGES[@]}"; do printf 'package\t%s\t%s\n' "$OS_FAMILY" "$package"; done
  fi
  printf 'action\tbootstrap\tensure git,curl,ca-certificates,archive tools\n'
  if [[ $OS_FAMILY == macos ]] && ! command -v brew >/dev/null 2>&1; then
    printf 'artifact\tdirect\thomebrew-bootstrap\t%s\t%s\n' "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256"
  fi
  if has_csv_item "$SELECTED_STEPS" packages; then
    printf 'action\tpackages\t%s\n' "$([[ $FULL_UPGRADE -eq 1 ]] && printf 'full host upgrade and selected package installation' || printf 'install missing selected packages without full host upgrade')"
    if [[ $FULL_UPGRADE -eq 1 ]]; then printf 'irreversible\thost-upgrade\tpackage-manager upgrades are not automatically reversible\n'; fi
    if [[ $OS_FAMILY == macos ]] && has_csv_item "$SELECTED_GROUPS" network; then
      printf 'action\trepository\tHomebrew heroku/brew tap\n'
    fi
    if [[ $OS_FAMILY == fedora ]] && has_csv_item "$SELECTED_GROUPS" media; then
      printf 'action\trepository\tRPM Fusion free\n'
    fi
  fi
  if [[ $SSH_MODE != skip ]]; then
    printf 'action\tssh\tverify or provision explicit key and GitHub upload\n'
    printf 'external\tgithub\tSSH public-key upload and Git protocol setting\n'
    printf 'file\tssh-known-hosts\t~/.ssh/known_hosts\n'
  fi
  if [[ $GPG_MODE != skip ]]; then
    printf 'action\tgpg\tverify GitHub email, configure commit signing, and upload public key\n'
    printf 'external\tgithub\tverified-email query and GPG public-key upload\n'
  fi
  if has_csv_item "$SELECTED_STEPS" zsh-config; then printf 'action\tzsh-config\tmanaged blocks in ~/.zshrc and ~/.zshenv\n'; fi
  if has_csv_item "$SELECTED_STEPS" default-shell; then printf 'action\tdefault-shell\t%s\n' "$CHANGE_DEFAULT_SHELL"; fi
  printf 'file\tlocal-profile\t%s\n' "$PROFILE_FILE"
  printf 'file\tlocal-state\t%s\n' "$STATE_FILE"
  if [[ $SSH_MODE != skip ]]; then printf 'file\tssh-reference\t%s\n' "${SSH_KEY_PATH:-generated path under ~/.ssh}"; fi
  if [[ $GPG_MODE != skip ]]; then printf 'global\tgit\tuser.signingkey,gpg.format,commit.gpgsign\n'; fi
  if has_csv_item "$SELECTED_STEPS" default-shell && [[ $CHANGE_DEFAULT_SHELL != no ]]; then printf 'irreversible\tlogin-shell\tchsh may require a new login\n'; fi
  if has_csv_item "$SELECTED_STEPS" bins; then printf 'artifact\tdirect\trpatool\t%s\t%s\n' "$RPATOOL_URL" "$RPATOOL_SHA256"; fi
  if has_csv_item "$SELECTED_STEPS" pyenv; then printf 'artifact\tgit\tpyenv\t%s\t%s\n' "$PYENV_REPOSITORY" "$PYENV_COMMIT"; fi
  if has_csv_item "$SELECTED_STEPS" rbenv; then
    printf 'artifact\tgit\trbenv\t%s\t%s\n' "$RBENV_REPOSITORY" "$RBENV_COMMIT"
    printf 'artifact\tgit\truby-build\t%s\t%s\n' "$RUBY_BUILD_REPOSITORY" "$RUBY_BUILD_COMMIT"
  fi
  if has_csv_item "$SELECTED_STEPS" bun; then
    asset=$(platform_asset bun); IFS=$'\t' read -r url digest <<< "$asset"
    printf 'artifact\tdirect\tbun\t%s\t%s\n' "$url" "$digest"
  fi
  if has_csv_item "$SELECTED_STEPS" yarn; then printf 'artifact\tdirect\tyarn\t%s\t%s\n' "$YARN_URL" "$YARN_SHA256"; fi
  if has_csv_item "$SELECTED_STEPS" pnpm; then printf 'artifact\tdirect\tpnpm\t%s\t%s\n' "$PNPM_URL" "$PNPM_SHA256"; fi
  if has_csv_item "$SELECTED_STEPS" fnm; then
    asset=$(platform_asset fnm); IFS=$'\t' read -r url digest <<< "$asset"
    printf 'artifact\tdirect\tfnm\t%s\t%s\n' "$url" "$digest"
    printf 'external\tnode-lts-index\thttps://nodejs.org/dist/index.tab\n'
  fi
  if has_csv_item "$SELECTED_STEPS" plugins; then
    asset=$(platform_asset starship); IFS=$'\t' read -r url digest <<< "$asset"
    printf 'artifact\tdirect\tstarship\t%s\t%s\n' "$url" "$digest"
    printf 'artifact\tgit\tzsh-autosuggestions\t%s\t%s\n' "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$ZSH_AUTOSUGGESTIONS_COMMIT"
    printf 'artifact\tgit\tzsh-syntax-highlighting\t%s\t%s\n' "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT"
    printf 'artifact\tgit\tzsh-completions\t%s\t%s\n' "$ZSH_COMPLETIONS_REPOSITORY" "$ZSH_COMPLETIONS_COMMIT"
    printf 'artifact\tgit\tfzf-tab\t%s\t%s\n' "$FZF_TAB_REPOSITORY" "$FZF_TAB_COMMIT"
  fi
  if has_csv_item "$SELECTED_STEPS" fonts && font_should_install; then
    printf 'artifact\tgit\tnerd-fonts\t%s\t%s\n' "$NERD_FONTS_REPOSITORY" "$NERD_FONTS_COMMIT"
  fi
  if has_csv_item "$SELECTED_STEPS" fnm; then
    if resolve_node_lts; then printf 'moving\tnode-lts\t%s\n' "$RESOLVED_NODE_VERSION"; else printf 'moving\tnode-lts\tresolve-during-apply\n'; fi
  fi
  old_ifs=$IFS
  IFS=,
  for step in $SELECTED_STEPS; do
    if verify_step "$step"; then status=verified; else status=needed; fi
    printf 'postcondition\t%s\t%s\n' "$step" "$status"
  done
  IFS=$old_ifs
}

main() {
  parse_args "$@"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  if [[ $COMMAND == reconcile ]]; then
    read_profile
  fi
  REQUESTED_STEPS=$SELECTED_STEPS
  REQUESTED_GROUPS=$SELECTED_GROUPS
  validate_options
  normalise_dependencies
  order_selected_steps
  detect_os
  if [[ $COMMAND == inspect ]]; then
    inspect_tsv
    return 0
  fi
  [[ $ASSUME_YES -eq 1 ]] || die "Apply/reconcile requires --yes after the AI-presented plan is approved"
  acquire_lock
  migrate_local_state
  if [[ $COMMAND == apply ]]; then
    if [[ $FULL_UPGRADE -eq 1 ]]; then SAVED_FULL_UPGRADE=yes; else SAVED_FULL_UPGRADE=no; fi
    write_profile
  fi
  bootstrap_tools
  if has_csv_item "$SELECTED_STEPS" fnm && [[ $DRY_RUN -eq 0 ]]; then
    resolve_node_lts
    say "Resolved Node current LTS for this run: $RESOLVED_NODE_VERSION"
  fi
  install_credential_prerequisites
  provision_ssh
  provision_gpg
  write_profile
  local step old_ifs=$IFS
  IFS=,
  for step in $SELECTED_STEPS; do
    run_step "$step"
  done
  IFS=$old_ifs
  say "Profile reconciliation complete. Restart the terminal; default-shell changes apply at next login."
}

if [[ ${LEOS_PROFILES_INSTALL_LIB_ONLY:-0} != 1 ]]; then
  main "$@"
fi
