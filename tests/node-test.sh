#!/usr/bin/env bash
# Offline behavioral regressions for runtime selection, ordering and migration.
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2317,SC2329
set -Eeuo pipefail
if [[ ${LEOS_NODE_TEST_ISOLATED:-} != 1 ]]; then
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LEOS_NODE_TEST_ISOLATED=1 bash "$0"
fi
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export HOME="$FIXTURE/home" XDG_DATA_HOME="$FIXTURE/data"
mkdir -p "$HOME/.local/bin"
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
source "$ROOT/install.sh"
LOCAL_DIR="$FIXTURE/local"
PROFILE_FILE="$LOCAL_DIR/install-profile.tsv"
STATE_FILE="$LOCAL_DIR/install-state.tsv"
LOCK_DIR="$LOCAL_DIR/.install.lock"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
equal() { [[ $1 == "$2" ]] || fail "expected $2, got $1"; }
node() { [[ -n ${TEST_NODE:-} ]] && printf '%s\n' "$TEST_NODE"; }
curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\n%s\tx\tx\tx\tx\tx\tx\tx\tx\tLTS\n' "${TEST_LTS:-v24.2.0}"; }

SELECTED_STEPS=pnpm
SELECTED_GROUPS=""
normalise_dependencies
order_selected_steps
equal "$SELECTED_STEPS" packages,fnm,pnpm
equal "$SELECTED_GROUPS" languages
validate_component_registry
(
  unset -f signature_pnpm
  if (validate_component_registry) >/dev/null 2>&1; then fail 'missing signature handler accepted'; fi
)

# Exact package lower bounds, including the minor-version boundary.
! node_version_compatible v22.12.9 || fail 'pnpm accepted Node below 22.13'
node_version_compatible v22.13.0
node_version_compatible v24.0.0
! node_version_compatible v22.13.0-rc1 || fail 'prerelease version accepted'
(
  SELECTED_STEPS=yarn
  node_version_compatible v4.0.0
  ! node_version_compatible v3.9.9 || fail 'Yarn accepted unsupported Node'
)

TEST_NODE=v22.14.0
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v22.14.0
equal "$NODE_SELECTION" adopted-existing
TEST_NODE=v26.1.0
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v22.14.0 # one choice per run
RESOLVED_NODE_VERSION=""
TEST_NODE=v20.19.0
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v24.2.0
equal "$NODE_SELECTION" current-lts
RESOLVED_NODE_VERSION=""
TEST_NODE=""
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v24.2.0

# fnm must win over an unrelated newer PATH runtime, but only if executable.
cat > "$HOME/.local/bin/fnm" <<'FAKE'
#!/bin/sh
case "$1" in
  --version) printf 'fnm 1.39.0\n' ;;
  default) printf '%s\n' "${TEST_FNM_DEFAULT:-v22.14.0}" ;;
  exec)
    shift 3
    if [ "$1" = node ]; then
      printf '%s\n' "${TEST_FNM_ACTUAL:-v22.14.0}"
    else
      printf '%s\n' "$*" >> "$TEST_EXEC_LOG"
      case "$1" in */pnpm) printf '11.11.0\n' ;; */yarn) printf '1.22.22\n' ;; esac
    fi ;;
  env) printf ':\n' ;;
  install|use) printf '%s\n' "$*" >> "$TEST_EXEC_LOG" ;;
esac
FAKE
chmod +x "$HOME/.local/bin/fnm"
export TEST_EXEC_LOG="$FIXTURE/exec.log"
TEST_NODE=v26.1.0
RESOLVED_NODE_VERSION=""
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v22.14.0
equal "$NODE_SELECTION" preserved-fnm
verify_fnm
(
  export TEST_FNM_ACTUAL=v20.0.0
  RESOLVED_NODE_VERSION=""
  resolve_node_version
  equal "$RESOLVED_NODE_VERSION" v26.1.0
)

# Installing npm packages and checking them must use fnm, never ambient npm.
(
  DRY_RUN=0
  npm() { fail 'ambient npm was invoked'; }
  download_verified() { printf 'fixture archive' > "$3"; }
  install_locked_npm_package pnpm https://example.invalid/pnpm.tgz unused
  [[ $(cat "$TEST_EXEC_LOG") == *'npm install --global --prefix '* ]] || fail 'npm did not use selected fnm runtime'
  mkdir -p "$HOME/.local/npm/bin"
  touch "$HOME/.local/npm/bin/pnpm" "$HOME/.local/npm/bin/yarn"
  chmod +x "$HOME/.local/npm/bin/pnpm" "$HOME/.local/npm/bin/yarn"
  verify_pnpm
  verify_yarn
)

# APT optional compatibility tools are absent on a minimal shell selection.
(
  OS_FAMILY=apt
  SELECTED_GROUPS=shell
  DRY_RUN=0
  FULL_UPGRADE=0
  ensure_sudo() { :; }
  package_installed() { return 1; }
  command() {
    case ${2:-} in fd|fdfind|bat|batcat) return 1 ;; esac
    builtin command "$@"
  }
  run() { :; }
  install_os_packages
)

# Already-installed provider packages must still repair missing fd/bat aliases.
(
  OS_FAMILY=apt
  SELECTED_GROUPS=shell
  FULL_UPGRADE=0
  DRY_RUN=0
  mkdir -p "$FIXTURE/providers"
  printf '#!/bin/sh\nexit 0\n' > "$FIXTURE/providers/fdfind"
  cp "$FIXTURE/providers/fdfind" "$FIXTURE/providers/batcat"
  chmod +x "$FIXTURE/providers/"*
  command() {
    case ${2:-} in
      fd|bat) return 1 ;;
      fdfind|batcat) printf '%s\n' "$FIXTURE/providers/$2" ;;
      *) builtin command "$@" ;;
    esac
  }
  package_installed() { return 0; }
  ! apt_compat_links_valid || fail 'missing aliases accepted'
  install_os_packages
  apt_compat_links_valid
  rm "$HOME/.local/bin/bat"
  ! apt_compat_links_valid || fail 'deleted bat alias accepted'
  install_os_packages
  apt_compat_links_valid
)

# A no-upgrade repair sends only missing packages to every backend.
for family in apt macos fedora arch; do
  (
    OS_FAMILY=$family
    FULL_UPGRADE=0
    DRY_RUN=1
    SELECTED_GROUPS=shell
    collect_selected_packages() { SELECTED_PACKAGES=(present missing); }
    package_installed() { [[ $1 == present ]]; }
    ensure_sudo() { :; }
    ensure_brew() { :; }
    result=$(install_os_packages)
    [[ $result == *missing* && $result != *present* ]] || fail "$family repair installed an existing package"
    [[ $result != *' upgrade '* && $result != *' -Syu '* ]] || fail "$family performed a full upgrade"
  )
done

# Schema 1 inspection/migration must leave disk unchanged until an approved write.
DRY_RUN=0
write_profile
grep -qx $'schema\t2' "$PROFILE_FILE"
sed '/^node-policy	/d;s/^schema	2$/schema\t1/' "$PROFILE_FILE" > "$FIXTURE/schema1"
cp "$FIXTURE/schema1" "$PROFILE_FILE"
read_profile
equal "$PROFILE_SCHEMA" 1
equal "$NODE_POLICY" preserve-compatible
equal "$(report_profile_migration)" $'migration\tprofile-schema\t1\t2'
DRY_RUN=1
write_profile
cmp "$FIXTURE/schema1" "$PROFILE_FILE"
DRY_RUN=0
write_profile
grep -qx $'schema\t2' "$PROFILE_FILE"
grep -qx $'node-policy\tpreserve-compatible' "$PROFILE_FILE"
(
  printf 'schema\t2\nnode-policy\tpreserve-compatible\n' > "$FIXTURE/truncated-profile"
  PROFILE_FILE="$FIXTURE/truncated-profile"
  if (read_profile) >/dev/null 2>&1; then fail 'truncated profile inherited broad defaults'; fi
)

# State is a resume hint: missing artifact repairs once, healthy rerun skips.
(
  OS_FAMILY=macos
  DRY_RUN=0
  FULL_UPGRADE=0
  install_local_bins() { printf 'installed\n' >> "$FIXTURE/installs"; touch "$FIXTURE/tool"; }
  verify_bins() { [[ -f $FIXTURE/tool ]]; }
  mark_done bins
  run_step bins
  run_step bins
  equal "$(wc -l < "$FIXTURE/installs" | tr -d ' ')" 1
)
printf 'Node/package/migration tests: PASS\n'
