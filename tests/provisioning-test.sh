#!/usr/bin/env bash
# REAL provisioning: only run on disposable CI hosts/containers. This changes
# system packages (including full upgrades); HOME isolation is not a sandbox.
# macOS uses a fresh HOME on an existing hosted runner, not a factory-fresh OS.
# Credentials and login-shell mutation are excluded; their unit tests exercise
# those paths without contacting GitHub or changing the CI account's shell.
# shellcheck disable=SC2016
set -Eeuo pipefail
IFS=$'\n\t'

if [[ ${GITHUB_ACTIONS:-} != true && ! -f /.leos-disposable-ci-container ]]; then
  printf '%s\n' 'Refusing real provisioning outside disposable CI.' >&2
  exit 2
fi
[[ $(id -u) != 0 ]] || { printf '%s\n' 'Run this test as a disposable non-root user.' >&2; exit 2; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/leos-provisioning.XXXXXX")
trap 'rm -rf -- "$FIXTURE"' EXIT
export HOME="$FIXTURE/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export FNM_DIR="$XDG_DATA_HOME/fnm"
export PYENV_ROOT="$HOME/.pyenv"
export RBENV_ROOT="$HOME/.rbenv"
unset LEOS_PROFILES_INSTALL_LIB_ONLY LEOS_PROFILES_HOME ZDOTDIR
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
PROFILE="$HOME/.leos-profiles"
mkdir -p "$PROFILE"
# Copy only the committed checkout, never a developer's local/ or plugin clones.
git -c safe.directory="$ROOT" -C "$ROOT" archive HEAD | tar -x -C "$PROFILE"
# shellcheck source=installer/lock.sh
source "$PROFILE/installer/lock.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
apply() {
  bash "$PROFILE/install.sh" apply --yes --ssh skip --gpg skip --default-shell no "$@"
}
verify_npm_tool() {
  local tool=$1 expected=$2 selected actual
  selected=$("$HOME/.local/bin/fnm" default)
  actual=$("$HOME/.local/bin/fnm" exec --using="$selected" -- "$HOME/.local/npm/bin/$tool" --version)
  [[ $actual == "$expected" ]] || fail "$tool version: expected $expected, got $actual"
}
real_shell_smoke() {
  EXPECTED_PROFILE="$PROFILE" SMOKE_PATH="$1" zsh -ic '
    [[ $LEOS_PROFILES == $EXPECTED_PROFILE ]] || exit 1
    for tool in npm pnpm bun; do
      [[ -n ${_comps[$tool]:-} ]] || {
        print -u2 "Missing real completion registration: $tool"; exit 1
      }
    done
    [[ -n $FNM_MULTISHELL_PATH ]] || exit 1
    print -r -- "$FNM_MULTISHELL_PATH" > "$SMOKE_PATH"
    zmodload zsh/stat || exit 1
    typeset -A info
    for directory in "$XDG_CACHE_HOME/leos-profiles" "$XDG_CACHE_HOME/leos-profiles/init"; do
      zstat -H info -- "$directory" || exit 1
      (( (info[mode] & 8#777) == 8#700 )) || exit 1
    done
    typeset -a cached
    cached=("$XDG_CACHE_HOME/leos-profiles/init/"*.zsh(N))
    (( ${#cached} > 0 )) || exit 1
    for file in "$XDG_CACHE_HOME/leos-profiles/init/"*(N); do
      zstat -H info -- "$file" || exit 1
      (( (info[mode] & 8#777) == 8#600 )) || exit 1
    done
  '
}

printf '%s\n' '=== Minimal zsh-config selection on a fresh HOME ==='
apply --groups zsh-config --package-groups none --no-full-upgrade --fonts no
EXPECTED_PROFILE="$PROFILE" zsh -ic '[[ $LEOS_PROFILES == $EXPECTED_PROFILE ]]'

printf '%s\n' '=== pnpm-only selection must provision its Node dependency ==='
apply --groups pnpm --package-groups none --no-full-upgrade --fonts no
[[ -x $HOME/.local/bin/fnm ]] || fail 'pnpm-only selection did not install fnm'
verify_npm_tool pnpm "$PNPM_VERSION"

printf '%s\n' '=== Execute both installed npm package managers ==='
apply --groups yarn,pnpm --package-groups none --no-full-upgrade --fonts no
verify_npm_tool yarn "$YARN_VERSION"
verify_npm_tool pnpm "$PNPM_VERSION"

printf '%s\n' '=== Recommended setup with the default full host upgrade ==='
# Force fonts on headless Linux too, so this tests their real install path.
# The default group/package selection and upgrade policy remain unchanged.
apply --fonts yes --font JetBrainsMono
verify_npm_tool yarn "$YARN_VERSION"
verify_npm_tool pnpm "$PNPM_VERSION"
real_shell_smoke "$FIXTURE/first-shell"
real_shell_smoke "$FIXTURE/second-shell"
[[ $(cat "$FIXTURE/first-shell") != "$(cat "$FIXTURE/second-shell")" ]] ||
  fail 'separate interactive shells reused the fnm multishell path'

printf '%s\n' '=== Reconcile must verify and skip already-complete steps ==='
bash "$PROFILE/install.sh" reconcile --yes | tee "$FIXTURE/reconcile.log"
while IFS=$'\t' read -r step _rest; do
  [[ -n $step ]] || continue
  grep -Fq "Skipping $step (recorded complete and verified)" "$FIXTURE/reconcile.log" ||
    fail "reconcile did not skip completed step $step"
done < "$PROFILE/local/install-state.tsv"

printf '%s\n' '=== Reconcile must repair a deleted locked executable ==='
rm -- "$HOME/.local/bin/bun"
bash "$PROFILE/install.sh" reconcile --yes | tee "$FIXTURE/repair.log"
grep -Fq 'Running bun' "$FIXTURE/repair.log" || fail 'reconcile did not repair bun'
[[ $("$HOME/.local/bin/bun" --version) == "$BUN_VERSION" ]] || fail 'repaired bun version differs'
printf 'real provisioning (%s/%s): PASS\n' "$(uname -s)" "$(uname -m)"
