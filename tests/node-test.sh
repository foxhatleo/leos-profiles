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
# pnpm runs on fnm's Node: no OS runtime group is implied (MI-4).
equal "$SELECTED_GROUPS" ""
validate_component_registry
(
  unset -f signature_pnpm
  if (validate_component_registry) >/dev/null 2>&1; then fail 'missing signature handler accepted'; fi
)


# Node follows the current LTS: the host's own Node is never adopted.
TEST_NODE=v22.14.0
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v24.2.0
equal "$NODE_SELECTION" current-lts
TEST_LTS=v26.1.0
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v24.2.0 # one choice per run
RESOLVED_NODE_VERSION=""
resolve_node_version
equal "$RESOLVED_NODE_VERSION" v26.1.0
TEST_LTS=v24.2.0

# fnm stands in at its Linux path (OS_FAMILY is unset, so not Homebrew's).
equal "$(fnm_path)" "$HOME/.local/bin/fnm"
cat > "$HOME/.local/bin/fnm" <<'FAKE'
#!/bin/sh
case "$1" in
  --version) printf 'fnm 1.39.0\n' ;;
  default)
    if [ -n "${2:-}" ]; then printf '%s\n' "$*" >> "$TEST_EXEC_LOG"; else printf '%s\n' "${TEST_FNM_DEFAULT:-v22.14.0}"; fi ;;
  list-remote) printf 'v22.20.0 (Jod)\nv24.9.0 (Krypton)\n' ;;
  exec)
    printf '%s\n' "$*" >> "$TEST_EXEC_LOG"
    shift 3
    case "$1" in
      node) printf '%s\n' "${TEST_FNM_ACTUAL:-v22.14.0}" ;;
      npm)
        prefix=$5
        package=${6%@latest}
        mkdir -p "$prefix/bin"
        printf '#!/bin/sh\nexit 0\n' > "$prefix/bin/$package"
        chmod +x "$prefix/bin/$package" ;;
      */pnpm) printf '11.11.0\n' ;;
      */yarn) printf '1.22.22\n' ;;
    esac ;;
  env) printf ':\n' ;;
  install|use) printf '%s\n' "$*" >> "$TEST_EXEC_LOG" ;;
esac
FAKE
chmod +x "$HOME/.local/bin/fnm"
export TEST_EXEC_LOG="$FIXTURE/exec.log"
: > "$TEST_EXEC_LOG"

# Without the release index, fnm's own LTS list answers (its last entry).
(
  curl() { return 7; }
  RESOLVED_NODE_VERSION=""
  resolve_node_version
  equal "$RESOLVED_NODE_VERSION" v24.9.0
  fnm() { return 1; }
  HOME="$FIXTURE/no-fnm"
  RESOLVED_NODE_VERSION=""
  if resolve_node_version; then fail 'an unresolvable LTS was reported resolved'; fi
  equal "$RESOLVED_NODE_VERSION" ""
)

# fnm verifies with any fnm version, and a default Node that really runs.
equal "$(fnm_default_node)" v22.14.0
verify_fnm
grep -q -- '--using=default -- node --version' "$TEST_EXEC_LOG" || fail 'the default Node was not run through fnm'
(
  export TEST_FNM_ACTUAL=v20.0.0
  ! fnm_default_node >/dev/null || fail 'a default that runs another Node was accepted'
  ! verify_fnm || fail 'fnm verified with a broken default Node'
)
(
  export TEST_FNM_DEFAULT=none
  ! verify_fnm || fail 'fnm verified without a default Node'
)

# install_fnm installs the resolved LTS and makes it the default.
(
  DRY_RUN=0
  artifact_install() { :; }
  RESOLVED_NODE_VERSION=""
  : > "$TEST_EXEC_LOG"
  install_fnm >/dev/null
  equal "$(cat "$TEST_EXEC_LOG")" $'install v24.2.0\ndefault v24.2.0\nuse v24.2.0'
)

# Linux: yarn and pnpm are npm's latest release, installed with fnm's default
# Node into ~/.local/npm, never with an ambient npm.
(
  OS_FAMILY=apt
  DRY_RUN=0
  npm() { fail 'ambient npm was invoked'; }
  : > "$TEST_EXEC_LOG"
  install_pnpm
  grep -qxF -- "exec --using=default -- npm install --global --prefix $HOME/.local/npm pnpm@latest" "$TEST_EXEC_LOG" ||
    fail "pnpm was not installed with fnm's default Node: $(cat "$TEST_EXEC_LOG")"
  verify_pnpm
  install_yarn
  verify_yarn
  equal "$(signature_yarn)" "|npm|yarn@latest|$HOME/.local/npm"
  rm "$HOME/.local/npm/bin/yarn"
  ! verify_yarn || fail 'a missing yarn verified'
  rm -rf "$HOME/.local/npm"
)

# macOS: yarn and pnpm are Homebrew formulae, and the npm-prefix copies older
# installs left in ~/.local/npm (ahead of Homebrew on PATH) are removed.
(
  OS_FAMILY=macos
  DRY_RUN=0
  FULL_UPGRADE=0
  export HOMEBREW_PREFIX="$FIXTURE/brew"
  export BREW_LOG="$FIXTURE/brew.log"
  mkdir -p "$HOMEBREW_PREFIX/bin"
  : > "$BREW_LOG"
  ensure_brew() { :; }
  brew() {
    printf '%s\n' "$*" >> "$BREW_LOG"
    case $1 in
      list) [[ -f $FIXTURE/brew-installed ]] && cat "$FIXTURE/brew-installed"; return 0 ;;
      install) printf '%s\n' "$2" >> "$FIXTURE/brew-installed"
        printf '#!/bin/sh\nexit 0\n' > "$HOMEBREW_PREFIX/bin/$2"; chmod +x "$HOMEBREW_PREFIX/bin/$2" ;;
    esac
  }
  npm_prefix="$HOME/.local/npm"
  cp "$HOME/.local/bin/fnm" "$HOMEBREW_PREFIX/bin/fnm"
  equal "$(fnm_path)" "$HOMEBREW_PREFIX/bin/fnm"
  # What `npm install --global --prefix ~/.local/npm` linked: each command is
  # a symlink into the package.
  legacy_npm_copy() {
    local command
    for command in "$@"; do
      mkdir -p "$npm_prefix/bin" "$npm_prefix/lib/node_modules/$1/bin"
      : > "$npm_prefix/lib/node_modules/$1/bin/$command.js"
      ln -sf "../lib/node_modules/$1/bin/$command.js" "$npm_prefix/bin/$command"
    done
  }
  legacy_npm_copy yarn yarnpkg
  legacy_npm_copy pnpm pnpx
  equal "$(npm_tool_path pnpm)" "$HOMEBREW_PREFIX/bin/pnpm"
  # An installed formula does not verify while the legacy copy shadows it.
  printf 'pnpm\n' >> "$FIXTURE/brew-installed"
  printf '#!/bin/sh\nexit 0\n' > "$HOMEBREW_PREFIX/bin/pnpm"
  chmod +x "$HOMEBREW_PREFIX/bin/pnpm"
  ! verify_pnpm || fail 'pnpm verified with the legacy npm copy ahead of the formula'
  equal "$(signature_pnpm)" '|formula|pnpm'
  install_pnpm >/dev/null
  ! grep -q '^install' "$BREW_LOG" || fail 'an installed formula was installed again'
  [[ ! -e $npm_prefix/lib/node_modules/pnpm && ! -L $npm_prefix/bin/pnpm && ! -L $npm_prefix/bin/pnpx ]] ||
    fail 'the legacy npm-prefix pnpm was left in front of the formula'
  [[ -e $npm_prefix/bin/yarn && -e $npm_prefix/bin/yarnpkg ]] || fail 'removing the legacy pnpm touched yarn'
  verify_pnpm
  legacy_npm_copy pnpm pnpx
  install_yarn >/dev/null
  grep -qx 'install yarn' "$BREW_LOG" || fail 'yarn was not installed from Homebrew'
  [[ ! -e $npm_prefix/lib/node_modules/yarn && ! -L $npm_prefix/bin/yarn && ! -L $npm_prefix/bin/yarnpkg ]] ||
    fail 'the legacy npm-prefix yarn was left in front of the formula'
  [[ -e $npm_prefix/bin/pnpm && -e $npm_prefix/bin/pnpx ]] || fail 'removing the legacy yarn touched pnpm'
  verify_yarn
  rm -rf "$HOMEBREW_PREFIX" "$FIXTURE/brew-installed" "$npm_prefix"
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
    if [[ $family == arch ]]; then
      # Arch has no partial upgrades: installing what is missing syncs and
      # upgrades in the same transaction (BP-8), and only then.
      [[ $result == *' pacman -Syu --needed --noconfirm missing '* ]] || fail "arch installed against a stale database: $result"
    else
      [[ $result != *' upgrade '* && $result != *' -Syu '* ]] || fail "$family performed a full upgrade"
    fi
  )
done

# Schema 1 and 2 profiles still read, move to the current-lts policy, and
# inspection/migration leaves disk unchanged until an approved write.
DRY_RUN=0
write_profile
grep -qx $'schema\t3' "$PROFILE_FILE"
grep -qx $'node-policy\tcurrent-lts' "$PROFILE_FILE"
sed $'/^node-policy\t/d;s/^schema\t3$/schema\t1/' "$PROFILE_FILE" > "$FIXTURE/schema1"
sed $'s/^schema\t3$/schema\t2/;s/^node-policy\tcurrent-lts$/node-policy\tpreserve-compatible/' "$PROFILE_FILE" > "$FIXTURE/schema2"
grep -qx $'node-policy\tpreserve-compatible' "$FIXTURE/schema2"
for schema in 1 2; do
  cp "$FIXTURE/schema$schema" "$PROFILE_FILE"
  NODE_POLICY=""
  read_profile
  equal "$PROFILE_SCHEMA" "$schema"
  equal "$NODE_POLICY" current-lts
  validate_options
  equal "$(report_profile_migration)" $'migration\tprofile-schema\t'"$schema"$'\t3'
  DRY_RUN=1
  write_profile
  cmp "$FIXTURE/schema$schema" "$PROFILE_FILE"
  DRY_RUN=0
  write_profile
  grep -qx $'schema\t3' "$PROFILE_FILE"
  grep -qx $'node-policy\tcurrent-lts' "$PROFILE_FILE"
  equal "$(report_profile_migration)" ""
done
(
  # A schema 2 profile without its node-policy row is malformed.
  sed $'/^node-policy\t/d' "$FIXTURE/schema2" > "$FIXTURE/schema2-incomplete"
  PROFILE_FILE="$FIXTURE/schema2-incomplete"
  if (read_profile) >/dev/null 2>&1; then fail 'schema 2 without node-policy accepted'; fi
  sed $'/^node-policy\t/d;s/^schema\t2$/schema\t3/' "$FIXTURE/schema2" > "$FIXTURE/schema3-incomplete"
  PROFILE_FILE="$FIXTURE/schema3-incomplete"
  if (read_profile) >/dev/null 2>&1; then fail 'schema 3 without node-policy accepted'; fi
  sed $'s/^schema\t1$/schema\t4/' "$FIXTURE/schema1" > "$FIXTURE/schema4"
  PROFILE_FILE="$FIXTURE/schema4"
  if (read_profile) >/dev/null 2>&1; then fail 'an unknown profile schema accepted'; fi
  printf 'schema\t3\nnode-policy\tcurrent-lts\n' > "$FIXTURE/truncated-profile"
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
