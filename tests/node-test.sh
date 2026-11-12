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
curl() { printf 'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\n%s\t2025-01-01\tx\tx\tx\tx\tx\tx\tx\tLTS\n' "${TEST_LTS:-v24.2.0}"; }

SELECTED_STEPS=corepack
SELECTED_GROUPS=""
normalise_dependencies
order_selected_steps
equal "$SELECTED_STEPS" packages,fnm,corepack
# Corepack's pnpm and Yarn run on fnm's Node: no OS runtime group is implied (MI-4).
equal "$SELECTED_GROUPS" ""
validate_component_registry
(
  unset -f signature_corepack
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
    if [ "$1" = env ]; then
      shift
      while [ "${1#*=}" != "$1" ]; do shift; done
    fi
    case "$1" in
      node) printf '%s\n' "${TEST_FNM_ACTUAL:-v22.14.0}" ;;
      npm)
        # What `npm install --global --prefix <p> corepack@latest` lays out:
        # the package, and a link for each command in its package.json
        # (corepack, and pnpm/pnpx/yarn/yarnpkg); npm refuses (EEXIST) to
        # replace a command another package installed.
        prefix=$5
        [ "$6" = corepack@latest ] || exit 1
        mkdir -p "$prefix/bin" "$prefix/lib/node_modules/corepack/dist"
        for command in corepack pnpm pnpx yarn yarnpkg; do
          if [ -e "$prefix/bin/$command" ] || [ -L "$prefix/bin/$command" ]; then
            case $(readlink "$prefix/bin/$command") in *corepack*) ;; *) echo "npm error EEXIST: $prefix/bin/$command" >&2; exit 1 ;; esac
          fi
          printf '#!/bin/sh\necho 11.11.0\n' > "$prefix/lib/node_modules/corepack/dist/$command.js"
          chmod +x "$prefix/lib/node_modules/corepack/dist/$command.js"
          ln -sf "../lib/node_modules/corepack/dist/$command.js" "$prefix/bin/$command"
        done ;;
      */corepack)
        if [ "$2" = enable ]; then
          [ "$3" = --install-directory ] || exit 1
          for command in pnpm pnpx yarn yarnpkg; do
            ln -sf "../lib/node_modules/corepack/dist/$command.js" "$4/$command"
          done
        fi ;;
      */pnpm|*/yarn) "$1" "$2" ;;
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
  equal "$(cat "$TEST_EXEC_LOG")" $'install v24.2.0\ndefault v24.2.0\nuse v24.2.0\nexec --using=default -- node --version'
)

# Corepack, on every OS: npm's latest Corepack, installed with fnm's default
# Node into ~/.local/npm (never an ambient npm, nor Homebrew's corepack, which
# would pull in Homebrew's node), its pnpm and Yarn shims there, and pnpm's
# latest and Yarn's stable release installed for use outside projects. The
# retired yarn component's npm package, in the way of the shims, goes first.
npm_prefix="$HOME/.local/npm"
# legacy_npm_copy <package> <commands...>: what the retired yarn or pnpm
# component's `npm install --global --prefix ~/.local/npm` linked.
legacy_npm_copy() {
  local package=$1 command
  shift
  for command in "$@"; do
    mkdir -p "$npm_prefix/bin" "$npm_prefix/lib/node_modules/$package/bin"
    : > "$npm_prefix/lib/node_modules/$package/bin/$command.js"
    ln -sf "../lib/node_modules/$package/bin/$command.js" "$npm_prefix/bin/$command"
  done
}
(
  OS_FAMILY=apt
  DRY_RUN=0
  npm() { fail 'ambient npm was invoked'; }
  brew() { fail 'brew was invoked on Linux'; }
  legacy_npm_copy yarn yarn yarnpkg
  legacy_npm_copy left-pad left-pad
  ! verify_corepack || fail 'Corepack verified before it was installed'
  : > "$TEST_EXEC_LOG"
  out=$(install_corepack)
  equal "$(grep -c -- '--prefix' "$TEST_EXEC_LOG")" 1
  grep -qxF -- "exec --using=default -- npm install --global --prefix $npm_prefix corepack@latest" "$TEST_EXEC_LOG" ||
    fail "Corepack was not installed with fnm's default Node: $(cat "$TEST_EXEC_LOG")"
  grep -qxF -- "exec --using=default -- $npm_prefix/bin/corepack enable --install-directory $npm_prefix/bin" "$TEST_EXEC_LOG" ||
    fail "Corepack's shims were not enabled in the npm prefix: $(cat "$TEST_EXEC_LOG")"
  grep -qxF -- "exec --using=default -- env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 $npm_prefix/bin/corepack install --global pnpm@latest yarn@stable" "$TEST_EXEC_LOG" ||
    fail "pnpm@latest and yarn@stable were not installed without a prompt: $(cat "$TEST_EXEC_LOG")"
  # The retired yarn package is gone, and only it.
  [[ ! -e $npm_prefix/lib/node_modules/yarn ]] || fail 'the legacy npm-prefix yarn package was left'
  [[ -e $npm_prefix/lib/node_modules/left-pad && -L $npm_prefix/bin/left-pad ]] || fail 'another global npm package was removed'
  for tool in pnpm pnpx yarn yarnpkg corepack; do
    [[ $(readlink "$npm_prefix/bin/$tool") == ../lib/node_modules/corepack/dist/$tool.js ]] ||
      fail "$tool is not Corepack's shim: $(readlink "$npm_prefix/bin/$tool")"
  done
  # Verification runs each shim on fnm's default Node, offline.
  : > "$TEST_EXEC_LOG"
  verify_corepack || fail "Corepack's shims did not verify"
  grep -qxF -- "exec --using=default -- env COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 $npm_prefix/bin/yarn --version" "$TEST_EXEC_LOG" ||
    fail "yarn was not verified through fnm's Node without network: $(cat "$TEST_EXEC_LOG")"
  equal "$(signature_corepack)" "|npm|corepack@latest|$npm_prefix|pnpm@latest yarn@stable"
  # A rerun keeps Corepack's own shims: they are no legacy copy.
  out=$(install_corepack)
  [[ $out != *'rm '* ]] || fail "a rerun removed Corepack's shims: $out"
  verify_corepack
  # A shim that does not run, or a missing one, fails verification.
  ln -sf ../lib/node_modules/corepack/dist/missing.js "$npm_prefix/bin/pnpm"
  ! verify_corepack || fail 'a broken pnpm shim verified'
  rm "$npm_prefix/bin/yarn"
  ! verify_corepack || fail 'a missing yarn shim verified'
  rm -rf "$npm_prefix"
)

# macOS: the same npm install (no Corepack formula), and the yarn and pnpm
# formulae the retired components installed are uninstalled: only those the
# state file shows the profile installed; then their rows go.
(
  OS_FAMILY=macos
  DRY_RUN=0
  FULL_UPGRADE=0
  export HOMEBREW_PREFIX="$FIXTURE/brew"
  export BREW_LOG="$FIXTURE/brew.log"
  mkdir -p "$HOMEBREW_PREFIX/bin" "$LOCAL_DIR"
  : > "$BREW_LOG"
  printf 'yarn\npnpm\nfnm\n' > "$FIXTURE/brew-installed"
  ensure_brew() { :; }
  brew() {
    printf '%s\n' "$*" >> "$BREW_LOG"
    case $1 in
      list) cat "$FIXTURE/brew-installed"; return 0 ;;
      uninstall) grep -vx "$3" "$FIXTURE/brew-installed" > "$FIXTURE/brew-left"; mv "$FIXTURE/brew-left" "$FIXTURE/brew-installed" ;;
    esac
  }
  cp "$HOME/.local/bin/fnm" "$HOMEBREW_PREFIX/bin/fnm"
  equal "$(fnm_path)" "$HOMEBREW_PREFIX/bin/fnm"
  printf '%s\tsig\t2026-01-01T00:00:00Z\t\n' packages yarn fnm > "$STATE_FILE"
  legacy_npm_copy pnpm pnpm pnpx
  SELECTED_STEPS=corepack
  migrations=$(report_tool_migrations)
  [[ $migrations == *$'migration\thomebrew-formula\t'"$HOMEBREW_PREFIX/opt/yarn"* ]] || fail "the yarn formula's removal was not disclosed: $migrations"
  [[ $migrations == *$'migration\tnpm-prefix\t'"$npm_prefix/bin/pnpm"* ]] || fail "the npm-prefix pnpm's removal was not disclosed: $migrations"
  : > "$TEST_EXEC_LOG"
  install_corepack >/dev/null
  equal "$(grep -c '^uninstall' "$BREW_LOG")" 1
  grep -qx 'uninstall --formula yarn' "$BREW_LOG" || fail "the profile's yarn formula was not uninstalled: $(cat "$BREW_LOG")"
  ! grep -q '^install' "$BREW_LOG" || fail 'Corepack came from Homebrew'
  grep -qxF -- "exec --using=default -- npm install --global --prefix $npm_prefix corepack@latest" "$TEST_EXEC_LOG" ||
    fail "macOS did not install Corepack from npm: $(cat "$TEST_EXEC_LOG")"
  [[ ! -e $npm_prefix/lib/node_modules/pnpm ]] || fail 'the legacy npm-prefix pnpm was left'
  equal "$(cut -f1 "$STATE_FILE" | paste -sd, -)" packages,fnm
  verify_corepack
  # Nothing left to remove: no second uninstall.
  install_corepack >/dev/null
  equal "$(grep -c '^uninstall' "$BREW_LOG")" 1
  rm -rf "$HOMEBREW_PREFIX" "$FIXTURE/brew-installed" "$npm_prefix" "$STATE_FILE"
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
SELECTED_STEPS=packages,fnm,corepack
write_profile
grep -qx $'schema\t4' "$PROFILE_FILE"
grep -qx $'node-policy\tcurrent-lts' "$PROFILE_FILE"
sed $'/^node-policy\t/d;s/^schema\t4$/schema\t1/' "$PROFILE_FILE" > "$FIXTURE/schema1"
sed $'s/^schema\t4$/schema\t2/;s/^node-policy\tcurrent-lts$/node-policy\tpreserve-compatible/' "$PROFILE_FILE" > "$FIXTURE/schema2"
grep -qx $'node-policy\tpreserve-compatible' "$FIXTURE/schema2"
for schema in 1 2; do
  cp "$FIXTURE/schema$schema" "$PROFILE_FILE"
  NODE_POLICY=""
  read_profile
  equal "$PROFILE_SCHEMA" "$schema"
  equal "$NODE_POLICY" current-lts
  validate_options
  equal "$(report_profile_migration)" $'migration\tprofile-schema\t'"$schema"$'\t4'
  DRY_RUN=1
  write_profile
  cmp "$FIXTURE/schema$schema" "$PROFILE_FILE"
  DRY_RUN=0
  write_profile
  grep -qx $'schema\t4' "$PROFILE_FILE"
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
  sed $'/^node-policy\t/d;s/^schema\t2$/schema\t4/' "$FIXTURE/schema2" > "$FIXTURE/schema4-incomplete"
  PROFILE_FILE="$FIXTURE/schema4-incomplete"
  if (read_profile) >/dev/null 2>&1; then fail 'schema 4 without node-policy accepted'; fi
  sed $'s/^schema\t1$/schema\t5/' "$FIXTURE/schema1" > "$FIXTURE/schema5"
  PROFILE_FILE="$FIXTURE/schema5"
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
