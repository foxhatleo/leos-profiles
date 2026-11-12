#!/usr/bin/env bash
# Verify that every mapped package is resolvable by a supported OS repository.
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

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

# Every package group, including the opt-in ones; heroku has members only on
# macOS (CI taps heroku/brew before this check). Every component too, for the
# OS packages a component needs (fnm's libatomic). dev-tools carries Ruby's
# build dependencies (autoconf, GMP, rustc for YJIT); there is no languages
# group since schema 4, so a system node, python or ruby is never mapped.
SELECTED_GROUPS=$CANONICAL_GROUPS
SELECTED_STEPS=$CANONICAL_STEPS
collect_selected_packages
case " ${SELECTED_PACKAGES[*]} " in
  *" nodejs "*|*" node "*|*" ruby "*|*" python-is-python3 "*|*" python-unversioned-command "*)
    printf 'A system runtime is mapped again: %s\n' "${SELECTED_PACKAGES[*]}" >&2
    exit 1 ;;
esac

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
