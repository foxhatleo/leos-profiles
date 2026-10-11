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
# Resolve the fixture physically: install.sh records its own `pwd -P` root, and
# macOS TMPDIR (/var/folders) and /tmp are symlinks into /private.
FIXTURE=$(CDPATH='' cd -- "$(mktemp -d "${TMPDIR:-/tmp}/leos-provisioning.XXXXXX")" && pwd -P)
# The session umask is deliberately inherited: Debian/Ubuntu sudo sessions use
# pam_umask 002 with user-private groups, which the runtime cache must accept.
collect_artifacts() {
  local dest=${LEOS_CI_ARTIFACTS:-}
  [[ -n $dest && -d $dest && -w $dest ]] || return 0
  dest="$dest/$(uname -s)-$(uname -m)-$$"
  mkdir -p -- "$dest" || return 0
  cp -- "$FIXTURE"/*.log "$dest/" 2>/dev/null || true
  cp -- "$PROFILE"/local/*.tsv "$dest/" 2>/dev/null || true
  { umask; id; ls -ldn -- "$FIXTURE" "$HOME" "$XDG_CACHE_HOME"; ls -laRn -- "$XDG_CACHE_HOME"; } \
    > "$dest/permissions.txt" 2>&1 || true
  zsh -ic 'print -r -- "PATH=$PATH"' > "$dest/interactive-shell.txt" 2>&1 || true
}
on_exit() {
  local rc=$?
  (( rc == 0 )) || collect_artifacts
  # Background shim rehashes started by the smoke shells can still be writing.
  rm -rf -- "$FIXTURE" 2>/dev/null || { sleep 3; rm -rf -- "$FIXTURE"; }
  return "$rc"
}
trap on_exit EXIT
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

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
apply() {
  bash "$PROFILE/install.sh" apply --yes --ssh skip --gpg skip --default-shell no "$@"
}
# Where the installer puts a tool: Homebrew's formula on macOS, the latest
# release in ~/.local/bin (npm tools: ~/.local/npm/bin) on Linux.
is_macos() { [[ $(uname -s) == Darwin ]]; }
tool_path() {
  if is_macos; then printf '%s/bin/%s\n' "$(brew --prefix)" "$1"; else printf '%s\n' "$HOME/.local/bin/$1"; fi
}
npm_tool_path() {
  if is_macos; then tool_path "$1"; else printf '%s\n' "$HOME/.local/npm/bin/$1"; fi
}
remove_tool() {
  if is_macos; then brew uninstall --formula --ignore-dependencies "$1"; else rm -- "$HOME/.local/bin/$1"; fi
}
verify_npm_tool() {
  local tool=$1 actual
  actual=$("$(tool_path fnm)" exec --using=default -- "$(npm_tool_path "$tool")" --version)
  [[ $actual =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "$tool reports no version: $actual"
}
verify_tool() {
  local tool=$1 first
  first=$("$(tool_path "$tool")" --version | sed -n '1p')
  [[ $first =~ [0-9]+\.[0-9]+\.[0-9]+ ]] || fail "$tool reports no version: $first"
}
real_shell_smoke() {
  EXPECTED_PROFILE="$PROFILE" SMOKE_PATH="$1" zsh -ic '
    smoke_fail() { print -u2 -r -- "FAIL: real shell smoke: $*"; exit 1; }
    [[ $LEOS_PROFILES == $EXPECTED_PROFILE ]] ||
      smoke_fail "LEOS_PROFILES=$LEOS_PROFILES, expected $EXPECTED_PROFILE"
    for tool in npm pnpm bun; do
      [[ -n ${_comps[$tool]:-} ]] || smoke_fail "missing real completion registration: $tool"
    done
    [[ -n $FNM_MULTISHELL_PATH ]] || smoke_fail "FNM_MULTISHELL_PATH is empty"
    print -r -- "$FNM_MULTISHELL_PATH" > "$SMOKE_PATH"
    zmodload zsh/stat || smoke_fail "cannot load zsh/stat"
    typeset -A info
    for directory in "$XDG_CACHE_HOME/leos-profiles" "$XDG_CACHE_HOME/leos-profiles/init"; do
      zstat -H info -- "$directory" || smoke_fail "missing cache directory $directory"
      (( (info[mode] & 8#777) == 8#700 )) ||
        smoke_fail "$directory has mode $(( [#8] info[mode] & 8#777 )), expected 700"
    done
    typeset -a cached
    cached=("$XDG_CACHE_HOME/leos-profiles/init/"*.zsh(N))
    (( ${#cached} > 0 )) || smoke_fail "no cached init scripts were written"
    for file in "$XDG_CACHE_HOME/leos-profiles/init/"*(N); do
      zstat -H info -- "$file" || smoke_fail "cannot stat $file"
      (( (info[mode] & 8#777) == 8#600 )) ||
        smoke_fail "$file has mode $(( [#8] info[mode] & 8#777 )), expected 600"
    done
  ' 2> >(tee -a "$FIXTURE/smoke-stderr.log" >&2)
}

printf '%s\n' '=== Minimal zsh-config selection on a fresh HOME ==='
apply --groups zsh-config --package-groups none --no-full-upgrade --fonts no
EXPECTED_PROFILE="$PROFILE" zsh -ic '[[ $LEOS_PROFILES == $EXPECTED_PROFILE ]]' ||
  fail "interactive LEOS_PROFILES does not match $PROFILE"

printf '%s\n' '=== pnpm-only selection must provision its Node dependency ==='
apply --groups pnpm --package-groups none --no-full-upgrade --fonts no
[[ -x $(tool_path fnm) ]] || fail 'pnpm-only selection did not install fnm'
verify_npm_tool pnpm

printf '%s\n' '=== Execute both installed npm package managers ==='
apply --groups yarn,pnpm --package-groups none --no-full-upgrade --fonts no
verify_npm_tool yarn
verify_npm_tool pnpm

printf '%s\n' '=== Recommended setup with the default full host upgrade ==='
# Force fonts on headless Linux too, so this tests their real install path.
# The default group/package selection and upgrade policy remain unchanged,
# except that LEOS_CI_FULL_UPGRADE=0 opts a runner out of the full host
# upgrade. CI keeps the full upgrade on one macOS runner and every Linux
# container; a full `brew upgrade` on each hosted macOS image mostly tests
# Homebrew and dominates the job time.
if [[ ${LEOS_CI_FULL_UPGRADE:-1} == 0 ]]; then
  printf '%s\n' 'LEOS_CI_FULL_UPGRADE=0: recommended setup without the full host upgrade'
  apply --fonts yes --font JetBrainsMono --no-full-upgrade
else
  apply --fonts yes --font JetBrainsMono
fi
verify_npm_tool yarn
verify_npm_tool pnpm
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

if ! is_macos; then
  printf '%s\n' '=== A full-upgrade reconcile re-runs the tools and finds them current ==='
  bash "$PROFILE/install.sh" reconcile --yes --full-upgrade | tee "$FIXTURE/full-upgrade.log"
  grep -Fq 'Re-running bun (a full upgrade brings it up to date)' "$FIXTURE/full-upgrade.log" ||
    fail 'a full upgrade did not re-run bun'
  grep -Fq 'is the latest release and already installed' "$FIXTURE/full-upgrade.log" ||
    fail 'a full upgrade downloaded a tool that was already current'
fi

printf '%s\n' '=== Reconcile must repair a deleted executable ==='
remove_tool bun
bash "$PROFILE/install.sh" reconcile --yes | tee "$FIXTURE/repair.log"
grep -Fq 'Running bun' "$FIXTURE/repair.log" || fail 'reconcile did not repair bun'
verify_tool bun

printf '%s\n' '=== Reconcile must repair Starship, a managed block, a plugin checkout and the font ==='
if [[ $(uname -s) == Darwin ]]; then
  FONT_DIR="$HOME/Library/Fonts/NerdFonts"
else
  FONT_DIR="$XDG_DATA_HOME/fonts/NerdFonts"
fi
PLUGIN="$PROFILE/zsh/plugins/zsh-autosuggestions"
remove_tool starship
awk '$0 == "# >>> leos-profiles environment >>>" { skip = 1; next }
     $0 == "# <<< leos-profiles environment <<<" { skip = 0; next }
     !skip { print }' "$HOME/.zshenv" > "$FIXTURE/zshenv" && cat "$FIXTURE/zshenv" > "$HOME/.zshenv"
! grep -q 'leos-profiles environment' "$HOME/.zshenv" || fail 'could not remove the .zshenv block'
# A detached checkout (another commit, clean, as the pinned installs left
# them) is moved back onto the default branch; a dirty one is refused, so
# local edits are never thrown away (checked below).
git -C "$PLUGIN" checkout --quiet --detach HEAD~1
# Every file of the family: verification only needs one of them.
find "$FONT_DIR" -type f -name 'JetBrainsMono*' -delete
[[ -z $(find "$FONT_DIR" -type f -name 'JetBrainsMono*') ]] || fail 'could not remove the font files'
bash "$PROFILE/install.sh" reconcile --yes | tee "$FIXTURE/repair-more.log"
for step in plugins zsh-config fonts; do
  grep -Fq "Running $step" "$FIXTURE/repair-more.log" || fail "reconcile did not repair $step"
done
verify_tool starship
grep -qxF '# >>> leos-profiles environment >>>' "$HOME/.zshenv" || fail 'the .zshenv block was not restored'
git -C "$PLUGIN" symbolic-ref --quiet HEAD >/dev/null || fail 'the plugin checkout is still detached'
[[ $(git -C "$PLUGIN" rev-parse HEAD) == "$(git -C "$PLUGIN" rev-parse refs/remotes/origin/HEAD)" ]] ||
  fail 'the plugin checkout is not at the head of its default branch'
[[ -n $(find "$FONT_DIR" -type f -name 'JetBrainsMonoNerdFont-*') ]] || fail 'the font was not reinstalled'

printf '%s\n' '=== Reconcile must refuse, not discard, a locally edited plugin ==='
printf '\n# local edit\n' >> "$PLUGIN/zsh-autosuggestions.zsh"
remove_tool starship
if bash "$PROFILE/install.sh" reconcile --yes > "$FIXTURE/dirty.log" 2>&1; then
  fail 'reconcile accepted a dirty plugin checkout'
fi
grep -Fq 'checkout has local changes' "$FIXTURE/dirty.log" || fail "dirty plugin refusal not explained: $(cat "$FIXTURE/dirty.log")"
git -C "$PLUGIN" checkout --quiet -- .
bash "$PROFILE/install.sh" reconcile --yes > "$FIXTURE/clean-again.log"
[[ -x $(tool_path starship) ]] || fail 'reconcile after restoring the plugin did not repair starship'
printf 'real provisioning (%s/%s): PASS\n' "$(uname -s)" "$(uname -m)"
