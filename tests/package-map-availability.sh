#!/usr/bin/env bash
# Verify that every mapped package is resolvable by a supported OS repository.
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
[[ $# == 1 ]] || { printf 'Usage: %s <macos|apt|fedora|arch>\n' "$0" >&2; exit 2; }
PACKAGE_MAP_FAMILY=$1
set --
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

OS_FAMILY=$PACKAGE_MAP_FAMILY
[[ $OS_FAMILY == macos || $OS_FAMILY == apt || $OS_FAMILY == fedora || $OS_FAMILY == arch ]] || {
  printf 'Unsupported package-map family: %s\n' "$OS_FAMILY" >&2
  exit 2
}

SELECTED_GROUPS="core-utils,shell,dev-tools,languages,media,network,system"
collect_selected_packages

failures=0
for package in "${SELECTED_PACKAGES[@]}"; do
  case $OS_FAMILY in
    macos) brew info "$package" >/dev/null 2>&1 ;;
    apt) apt-cache show "$package" >/dev/null 2>&1 ;;
    fedora) [[ -n $(dnf -q repoquery --whatprovides "$package" 2>/dev/null) ]] ;;
    arch) pacman -Si "$package" >/dev/null 2>&1 ;;
  esac || { printf 'Unavailable %s package: %s\n' "$OS_FAMILY" "$package" >&2; failures=1; }
done

(( failures == 0 )) || exit 1
printf 'package map (%s): PASS (%d packages)\n' "$OS_FAMILY" "${#SELECTED_PACKAGES[@]}"
