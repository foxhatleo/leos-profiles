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
# shellcheck source=installer/registry.sh
source "$SCRIPT_DIR/installer/registry.sh"
readonly CANONICAL_GROUPS="core-utils,shell,dev-tools,languages,media,network,system"
# rpatool remains available as the explicit `bins` step, but is not a default
# because its upstream does not publish a stable release.
SELECTED_STEPS="${CANONICAL_STEPS/,bins/}"
SELECTED_GROUPS="$CANONICAL_GROUPS"
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
NODE_POLICY="preserve-compatible"
NODE_SELECTION=""
PROFILE_SCHEMA=2
AI_CLI_UPDATE_CHANNEL="native"
PACKAGE_CHANNEL="system"
SELECTED_PACKAGES=()
TEMP_PATHS=()
LOCK_HELD=0

say() { printf '%s\n' "==> $*"; }
warn() { printf '%s\n' "WARNING: $*" >&2; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  bash install.sh inspect [options]
  bash install.sh apply --yes [options]
  bash install.sh reconcile --yes [--full-upgrade]
  bash install.sh remove-blocks [--dry-run]

Options:
  --groups <csv|none>             $CANONICAL_STEPS
  --package-groups <csv|none>     $CANONICAL_GROUPS
  --ssh <skip|reuse|generate>     GitHub SSH-key provisioning choice
  --ssh-key <path>                Absolute key path (reuse requires it; generate defaults to ~/.ssh/id_ed25519)
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

The AI runbook is the supported user interface. \`inspect\` emits typed TSV for
agents and diagnostics; \`apply\` and \`reconcile\` never ask setup questions.
\`remove-blocks\` deletes only the two managed blocks from ~/.zshrc and ~/.zshenv,
leaving packages, plugins and credentials in place.

Node: preserve a compatible version by adopting it into fnm; otherwise use LTS.
Credentials: local creation is supported; GitHub registration and SSH identity
configuration are manual. Exit 3 means user action is required; resume using
reconcile --yes after completing the emitted manual-action record.
EOF
}

require_value() {
  [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

parse_args() {
  [[ $# -gt 0 ]] || { usage >&2; exit 2; }
  case $1 in
    inspect|apply|reconcile|remove-blocks) COMMAND=$1; shift ;;
    --target|--ref|--steps|--repair|--plan|--allow-mutable-ref)
      die "$1 belongs to the retired ref/target CLI; use the AI runbook with this local checkout" ;;
    --help|-h) usage; exit 0 ;;
    *) die "Expected inspect, apply, reconcile, or remove-blocks; the AI runbook is the setup interface" ;;
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
  local value=$1 allowed=$2 item seen=","
  [[ -n $value ]] || return 1
  [[ $value != ,* && $value != *, && $value != *,,* ]] || return 1
  local old_ifs=$IFS
  IFS=,
  for item in $value; do
    [[ ",$allowed," == *",$item,"* ]] || { IFS=$old_ifs; return 1; }
    # Reject repeats: a duplicated group would otherwise double every package in
    # collect_selected_packages and change the step signature, so an equivalent
    # normalized run would be treated as never done and repeat the step.
    [[ $seen != *",$item,"* ]] || { IFS=$old_ifs; return 1; }
    seen="$seen$item,"
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

order_selected_steps() {
  local canonical="$CANONICAL_STEPS"
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
  [[ -z $SELECTED_STEPS ]] || valid_csv "$SELECTED_STEPS" "$CANONICAL_STEPS" || die "Invalid --groups value"
  [[ -z $SELECTED_GROUPS ]] || valid_csv "$SELECTED_GROUPS" "$CANONICAL_GROUPS" || die "Invalid --package-groups value"
  [[ $SSH_MODE == skip || $SSH_MODE == reuse || $SSH_MODE == generate ]] || die "Invalid --ssh value"
  [[ $SSH_PASSPHRASE_MODE == empty || $SSH_PASSPHRASE_MODE == prompt ]] || die "Invalid --ssh-passphrase value"
  [[ $GPG_MODE == skip || $GPG_MODE == reuse || $GPG_MODE == generate ]] || die "Invalid --gpg value"
  [[ $GPG_PASSPHRASE_MODE == empty || $GPG_PASSPHRASE_MODE == prompt ]] || die "Invalid --gpg-passphrase value"
  [[ $INSTALL_FONTS == auto || $INSTALL_FONTS == yes || $INSTALL_FONTS == no ]] || die "Invalid --fonts value"
  [[ $CHANGE_DEFAULT_SHELL == auto || $CHANGE_DEFAULT_SHELL == yes || $CHANGE_DEFAULT_SHELL == no ]] || die "Invalid --default-shell value"
  [[ $SSH_MODE != reuse || -n $SSH_KEY_PATH ]] || die "--ssh reuse requires --ssh-key <private-key-path>"
  [[ $GPG_MODE != reuse || -n $GPG_KEY_ID ]] || die "--gpg reuse requires --gpg-key <fingerprint>"
  [[ $INSTALL_FONTS != yes || -n $FONT_NAME ]] || die "--fonts yes requires --font <name>"
  [[ -z $SSH_KEY_PATH || $SSH_KEY_PATH == /* ]] || die "--ssh-key must be an absolute path"
  [[ -z $FONT_NAME || $FONT_NAME =~ ^[A-Za-z0-9_-]+$ ]] || die "--font must be a Nerd Fonts directory name"
  [[ $NODE_POLICY == preserve-compatible ]] || die "Unsupported Node policy: $NODE_POLICY"
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

# shellcheck source=installer/state.sh
source "$SCRIPT_DIR/installer/state.sh"

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  [[ $DRY_RUN -eq 0 ]] || return 0
  if [[ $EUID -eq 0 && ${1:-} == sudo ]]; then shift; fi
  "$@"
}

# run_shell <description> <program> [args...]
# Extra args are passed to `bash -c` as $1..$n, so callers never have to
# interpolate values into the program text.
run_shell() {
  local description=$1 program=$2
  shift 2
  say "$description"
  [[ $DRY_RUN -eq 1 ]] || bash -c "$program" _ "$@"
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

sha256() { hash_text < "$1"; }

# Octal mode of a file, spelling around BSD vs GNU stat.
file_mode() {
  if [[ $(uname -s) == Darwin ]]; then
    /usr/bin/stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
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
  # --speed-limit/--speed-time rather than a flat --max-time: artifacts vary in
  # size, so abort on a stalled transfer (under 1 B/s for a minute) instead of
  # capping how long a legitimately slow download may take.
  curl_args=(--fail --location --proto '=https' --tlsv1.2 --retry 3
    --connect-timeout 15 --speed-limit 1 --speed-time 60
    --silent --show-error --output "$tmp")
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

# shellcheck source=installer/packages.sh
source "$SCRIPT_DIR/installer/packages.sh"

# shellcheck source=installer/tools.sh
source "$SCRIPT_DIR/installer/tools.sh"


# shellcheck source=installer/config.sh
source "$SCRIPT_DIR/installer/config.sh"

# shellcheck source=installer/credentials.sh
source "$SCRIPT_DIR/installer/credentials.sh"

# shellcheck source=installer/verification.sh
source "$SCRIPT_DIR/installer/verification.sh"

# shellcheck source=installer/signatures.sh
source "$SCRIPT_DIR/installer/signatures.sh"

run_step() {
  local step=$1 force_rerun=0
  # A full host upgrade always re-runs the packages step; it deliberately skips
  # the state/verify short-circuit rather than failing verification.
  [[ $step == packages && $FULL_UPGRADE -eq 1 ]] && force_rerun=1
  if [[ $force_rerun -eq 0 ]] && state_done "$step" && verify_step "$step"; then
    say "Skipping $step (recorded complete and verified)"
    return 0
  fi
  if [[ $force_rerun -eq 1 ]] && state_done "$step"; then
    say "Re-running $step (full host upgrade always re-runs the packages step)"
  elif state_done "$step"; then
    warn "$step was recorded complete but failed verification; repairing it"
  fi
  say "Running $step"
  local handler
  handler=$(component_handler "$step" install)
  "$handler"
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
  printf 'policy\tnode\t%s\n' "$NODE_POLICY"
  report_profile_migration
  printf 'channel\tai-cli-updates\t%s\n' "$AI_CLI_UPDATE_CHANNEL"
  printf 'group\tinternal\tbootstrap\tselected\n'
  local canonical="$CANONICAL_STEPS"
  local old_ifs=$IFS
  IFS=,
  for step in $canonical; do
    has_csv_item "$SELECTED_STEPS" "$step" || continue
    if has_csv_item "$REQUESTED_STEPS" "$step"; then origin=selected; else origin=implied; fi
    printf 'group\tcomponent\t%s\t%s\n' "$step" "$origin"
  done
  # IFS is still "," from the step loop above, so the CSV splits directly. Do not
  # rewrite this as a space-separated list: the global IFS has no space in it.
  for group in $CANONICAL_GROUPS; do
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
    if [[ $FULL_UPGRADE -eq 1 ]]; then printf 'irreversible\thost-upgrade\tin-release package-manager upgrades (never an OS release upgrade) are not automatically reversible\n'; fi
    if [[ $OS_FAMILY == macos ]] && has_csv_item "$SELECTED_GROUPS" network; then
      printf 'action\trepository\tHomebrew heroku/brew tap\n'
    fi
    if [[ $OS_FAMILY == fedora ]] && has_csv_item "$SELECTED_GROUPS" media; then
      printf 'action\trepository\tRPM Fusion free\n'
    fi
  fi
  if [[ $SSH_MODE != skip ]]; then
    printf 'action\tssh\tprepare explicit local key and verify manual GitHub registration\n'
    printf 'external\tgithub\tmanual SSH public-key registration and guided SSH/Git protocol configuration\n'
    printf 'file\tssh-known-hosts\t~/.ssh/known_hosts\n'
  fi
  if [[ $GPG_MODE != skip ]]; then
    printf 'action\tgpg\tverify GitHub email, manual public-key registration, and configure commit signing\n'
    printf 'external\tgithub\tverified-email query and manual GPG public-key registration\n'
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
    if resolve_node_version; then
      printf 'runtime\tnode\t%s\t%s\n' "$RESOLVED_NODE_VERSION" "$NODE_SELECTION"
    else printf 'runtime\tnode\tunresolved\tresolve-during-apply\n'; fi
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
  validate_component_registry
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
  # Touches only the two managed blocks, so it needs neither --yes nor the lock.
  if [[ $COMMAND == remove-blocks ]]; then
    remove_managed_blocks
    return 0
  fi
  [[ $ASSUME_YES -eq 1 ]] || die "Apply/reconcile requires --yes after the AI-presented plan is approved"
  # Capture the existing runtime before any bootstrap/package changes.
  if has_csv_item "$SELECTED_STEPS" fnm; then select_existing_node || true; fi
  acquire_lock
  report_profile_migration
  migrate_local_state
  if [[ $COMMAND == apply ]]; then
    if [[ $FULL_UPGRADE -eq 1 ]]; then SAVED_FULL_UPGRADE=yes; else SAVED_FULL_UPGRADE=no; fi
    write_profile
  fi
  bootstrap_tools
  if has_csv_item "$SELECTED_STEPS" fnm && [[ $DRY_RUN -eq 0 ]]; then
    resolve_node_version || die "Could not select a compatible Node version or resolve current LTS"
    say "Selected Node $RESOLVED_NODE_VERSION ($NODE_SELECTION)"
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
  if [[ $COMMAND == reconcile ]]; then
    say "Profile reconciliation complete. Restart the terminal; default-shell changes apply at next login."
  else
    say "Profile apply complete. Restart the terminal; default-shell changes apply at next login."
  fi
}

if [[ ${LEOS_PROFILES_INSTALL_LIB_ONLY:-0} != 1 ]]; then
  main "$@"
fi
