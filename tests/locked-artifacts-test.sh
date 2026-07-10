#!/usr/bin/env bash
# Download and verify every non-Git locked artifact for this runner platform.
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME=$TEST_HOME
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

DRY_RUN=0
detect_os

download_verified "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$TEST_HOME/homebrew-install.sh"
download_verified "$RPATOOL_URL" "$RPATOOL_SHA256" "$TEST_HOME/bin/rpatool"
download_verified "$YARN_URL" "$YARN_SHA256" "$TEST_HOME/yarn.tgz"
download_verified "$PNPM_URL" "$PNPM_SHA256" "$TEST_HOME/pnpm.tgz"
install_locked_archive_binary bun zip "$TEST_HOME/bin/bun"
install_locked_archive_binary fnm zip "$TEST_HOME/bin/fnm"
install_locked_archive_binary starship tar.gz "$TEST_HOME/bin/starship"

"$TEST_HOME/bin/rpatool" --help >/dev/null
[[ $("$TEST_HOME/bin/bun" --version) == "$BUN_VERSION" ]]
[[ $("$TEST_HOME/bin/fnm" --version) == "fnm $FNM_VERSION" ]]
[[ $("$TEST_HOME/bin/starship" --version | sed -n '1p') == "starship $STARSHIP_VERSION" ]]

printf 'locked artifacts (%s/%s): PASS\n' "$OS_FAMILY" "$(machine_arch)"
