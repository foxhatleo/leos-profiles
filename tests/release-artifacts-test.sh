#!/usr/bin/env bash
# Resolve, download and run the tools the installer takes from upstream, for
# this runner's platform: on Linux the latest GitHub releases (checked against
# GitHub's digests) and npm's latest Yarn and pnpm; on macOS, that every
# Homebrew formula exists. Also the two pinned files and the latest Nerd Fonts
# release. Needs network; set GITHUB_TOKEN to avoid the API's anonymous limit.
# shellcheck disable=SC1091,SC2034,SC2329

set -Eeuo pipefail

if [[ ${LEOS_ARTIFACT_TEST_ISOLATED:-} != 1 ]]; then
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    LEOS_ARTIFACT_TEST_ISOLATED=1 bash "$0"
fi
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME=$TEST_HOME
export XDG_CONFIG_HOME="$TEST_HOME/config" XDG_CACHE_HOME="$TEST_HOME/cache"
export XDG_DATA_HOME="$TEST_HOME/data" XDG_STATE_HOME="$TEST_HOME/state"
export FNM_DIR="$TEST_HOME/fnm"
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

DRY_RUN=0
detect_os

# Pinned files: the reviewed digests still match.
download_verified "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$TEST_HOME/homebrew-install.sh"
artifact_install rpatool "$TEST_HOME/bin"
"$TEST_HOME/bin/rpatool" --help >/dev/null
printf 'verified pinned rpatool and Homebrew installer\n'

# Every release asset the registry names, for both Linux CPUs, exists in its
# project's latest release with a GitHub digest (from any host, so a renamed
# asset shows up on the macOS runners too).
while IFS= read -r artifact; do
  [[ $(OS_FAMILY=apt artifact_source "$artifact") == release ]] || continue
  for FAKE_MACHINE in aarch64 x86_64; do
    uname() { if [[ ${1:-} == -m ]]; then printf '%s\n' "$FAKE_MACHINE"; else command uname "$@"; fi; }
    record=$(artifact_release_asset "$artifact")
    unset -f uname
    IFS=$'\t' read -r repository asset <<< "$record"
    record=$(github_latest_asset "$repository" "$asset")
    IFS=$'\t' read -r tag url digest <<< "$record"
    printf 'resolved %s %s (%s)\n' "$artifact" "$(release_version "$tag")" "$asset"
  done
done < <(artifact_names)

if [[ $OS_FAMILY == macos ]]; then
  # Homebrew owns these on macOS; installing them is the provisioning test's job.
  ensure_brew
  while IFS= read -r artifact; do
    artifact_row "$artifact"
    [[ -z $ARTIFACT_FORMULA ]] || brew info --formula "$ARTIFACT_FORMULA" >/dev/null ||
      die "Homebrew has no $ARTIFACT_FORMULA formula"
  done < <(artifact_names)
  for formula in yarn pnpm; do
    brew info --formula "$formula" >/dev/null || die "Homebrew has no $formula formula"
  done
  printf 'Homebrew formulae present\n'
else
  # Install each release, check the version it reports and its other
  # executables; a second install finds it current and downloads nothing.
  while IFS= read -r artifact; do
    [[ $(artifact_source "$artifact") == release ]] || continue
    artifact_install "$artifact" "$TEST_HOME/bin"
    out=$(artifact_install "$artifact" "$TEST_HOME/bin")
    [[ $out == *"is the latest release and already installed"* ]] || die "$artifact was downloaded again: $out"
    printf 'installed %s\n' "$("$TEST_HOME/bin/$artifact" --version | sed -n '1p')"
  done < <(artifact_names)
  "$TEST_HOME/bin/uvx" --version >/dev/null

  # Yarn and pnpm from npm, on the current LTS installed by fnm.
  mkdir -p "$HOME/.local/bin"
  cp "$TEST_HOME/bin/fnm" "$HOME/.local/bin/fnm"
  resolve_node_version
  eval "$("$HOME/.local/bin/fnm" env --shell bash)"
  "$HOME/.local/bin/fnm" install "$RESOLVED_NODE_VERSION"
  "$HOME/.local/bin/fnm" default "$RESOLVED_NODE_VERSION"
  [[ $(fnm_default_node) == "$RESOLVED_NODE_VERSION" ]] || die "fnm's default is not $RESOLVED_NODE_VERSION"
  install_yarn
  install_pnpm
  verify_yarn
  verify_pnpm
  fnm_exec npm completion > "$TEST_HOME/npm-completion.zsh"
  fnm_exec "$HOME/.local/npm/bin/pnpm" completion zsh > "$TEST_HOME/pnpm-completion.zsh"
  SHELL=zsh "$TEST_HOME/bin/bun" completions > "$TEST_HOME/bun-completion.zsh"
  "$TEST_HOME/bin/uv" generate-shell-completion zsh > "$TEST_HOME/uv-completion.zsh"
  "$TEST_HOME/bin/uvx" --generate-shell-completion zsh > "$TEST_HOME/uvx-completion.zsh"
  for package in npm pnpm bun uv uvx; do
    [[ -s $TEST_HOME/$package-completion.zsh ]] || die "$package emitted no completion script"
    zsh -n "$TEST_HOME/$package-completion.zsh"
  done
fi

# Nerd Fonts: the latest release's checksum list, a real font archive verified
# against it, and an unknown name rejected before any archive download.
install_nerd_font JetBrainsMono
FONT_NAME=JetBrainsMono INSTALL_FONTS=yes verify_fonts
if (install_nerd_font NoSuchNerdFont) 2>/dev/null; then die "an unknown Nerd Font name was accepted"; fi

printf 'release artifacts (%s/%s): PASS\n' "$OS_FAMILY" "$(machine_arch)"
