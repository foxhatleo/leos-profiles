#!/usr/bin/env bash
# Download and verify every non-Git locked artifact for this runner platform.
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

if [[ ${LEOS_ARTIFACT_TEST_ISOLATED:-} != 1 ]]; then
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LEOS_ARTIFACT_TEST_ISOLATED=1 bash "$0"
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

download_verified "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$TEST_HOME/homebrew-install.sh"
download_verified "$YARN_URL" "$YARN_SHA256" "$TEST_HOME/yarn.tgz"
download_verified "$PNPM_URL" "$PNPM_SHA256" "$TEST_HOME/pnpm.tgz"
# Every direct artifact in the registry: download, verify the digest, install
# and check the reported version (artifact_install dies on a mismatch).
while IFS= read -r artifact; do
  artifact_install "$artifact" "$TEST_HOME/bin"
  printf 'verified %s\n' "$artifact"
done < <(artifact_names)

"$TEST_HOME/bin/rpatool" --help >/dev/null
[[ $("$TEST_HOME/bin/bun" --version) == "$BUN_VERSION" ]]
[[ $("$TEST_HOME/bin/fnm" --version) == "fnm $FNM_VERSION" ]]
[[ $("$TEST_HOME/bin/starship" --version | sed -n '1p') == "starship $STARSHIP_VERSION" ]]
[[ $("$TEST_HOME/bin/uv" --version) == "uv $UV_VERSION"* ]]
[[ $("$TEST_HOME/bin/uvx" --version) == "uvx $UV_VERSION"* ]]

# Check declared runtime requirements against the *verified* package manifests.
# Changing a lock requires updating the supported engine evaluator as necessary.
for package in yarn pnpm; do
  if [[ $package == yarn ]]; then expected=$YARN_NODE_ENGINE; else expected=$PNPM_NODE_ENGINE; fi
  declared=$(tar -xOf "$TEST_HOME/$package.tgz" package/package.json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["engines"]["node"])')
  [[ $declared == "$expected" ]] || die "$package Node engine changed: $declared (expected $expected)"
done

# Actually execute both npm tools on a disposable managed runtime. A digest-only
# check misses Node compatibility, package layout, and installer-order failures.
SELECTED_STEPS=fnm,yarn,pnpm
resolve_node_lts
mkdir -p "$HOME/.local/bin"
cp "$TEST_HOME/bin/fnm" "$HOME/.local/bin/fnm"
eval "$("$HOME/.local/bin/fnm" env --shell bash)"
"$HOME/.local/bin/fnm" install "$RESOLVED_NODE_VERSION"
"$HOME/.local/bin/fnm" default "$RESOLVED_NODE_VERSION"
"$HOME/.local/bin/fnm" use "$RESOLVED_NODE_VERSION"
fnm_exec npm install --global --prefix "$HOME/.local/npm" "$TEST_HOME/yarn.tgz" "$TEST_HOME/pnpm.tgz"
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

printf 'locked artifacts (%s/%s): PASS\n' "$OS_FAMILY" "$(machine_arch)"
