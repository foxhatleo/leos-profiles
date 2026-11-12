#!/usr/bin/env bash
# The destructive macOS migrations in installer/tools.sh, in a fixture HOME:
# remove_legacy_local_copy (old ~/.local/bin copies of tools Homebrew now
# owns) and remove_legacy_npm_copy (old ~/.local/npm copies of Yarn and pnpm).
# Each must remove exactly the legacy copy, leave every other file alone,
# never follow a link out of HOME, and refuse a name that is not one of its
# tools. Offline; runs under the system Bash 3.2 on macOS CI.
# shellcheck disable=SC1091,SC2034

set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
export LEOS_PROFILES_INSTALL_LIB_ONLY=1
# Nothing from the caller's environment may relocate the paths under test.
unset ZDOTDIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME HOMEBREW_PREFIX
# shellcheck source=../install.sh
source "$ROOT/install.sh"

CURRENT_TEST=""
fail() { printf '%s\n' "FAIL [${CURRENT_TEST:-?}]: $*" >&2; exit 1; }
assert_equals() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "expected '$1' to contain '$2'"; }
assert_absent() { [[ ! -e $1 && ! -L $1 ]] || fail "$1 was not removed"; }
assert_present() { [[ -e $1 || -L $1 ]] || fail "$1 was removed"; }

# Each test gets FIXTURE with a HOME inside it and an OUTSIDE directory beside
# HOME, which no migration may change. The HOME name has a space and a glob
# character, and a sibling shares its prefix, so an unquoted or prefix-matched
# path would show up as damage outside HOME.
setup_fixture() {
  FIXTURE=$(CDPATH='' cd -- "$(mktemp -d "${TMPDIR:-/tmp}/leos-migration.XXXXXX")" && pwd -P)
  export HOME="$FIXTURE/my home*"
  OUTSIDE="$FIXTURE/outside"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/npm/bin" "$HOME/.local/npm/lib/node_modules" \
    "$OUTSIDE" "$FIXTURE/my"
  printf 'sibling\n' > "$FIXTURE/my/keep"
  OS_FAMILY=macos
  DRY_RUN=0
}

cleanup() { [[ -z ${FIXTURE:-} ]] || rm -rf -- "$FIXTURE"; }

# fake_tool <path> <first line of --version>
fake_tool() {
  mkdir -p "$(dirname -- "$1")"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$1"
  chmod 755 "$1"
}

# listing <dir>: every path below it (links shown with their targets), sorted.
listing() {
  local path
  find "$1" -print | LC_ALL=C sort | while IFS= read -r path; do
    if [[ -L $path ]]; then
      printf '%s -> %s\n' "$path" "$(readlink "$path")"
    else
      printf '%s\n' "$path"
    fi
  done
}

outside_snapshot() { listing "$OUTSIDE"; listing "$FIXTURE/my"; }

# --- remove_legacy_local_copy -------------------------------------------------

test_local_copy_removes_every_executable_of_the_tool() {
  local before
  fake_tool "$HOME/.local/bin/uv" "uv 0.9.1"
  fake_tool "$HOME/.local/bin/uvx" "uvx 0.9.1"
  fake_tool "$HOME/.local/bin/starship" "starship 1.23.0"
  fake_tool "$HOME/.local/bin/unrelated" "unrelated 1.0"
  fake_tool "$OUTSIDE/uv" "uv 0.9.1"
  before=$(outside_snapshot)
  remove_legacy_local_copy uv >/dev/null
  assert_absent "$HOME/.local/bin/uv"
  assert_absent "$HOME/.local/bin/uvx"
  assert_present "$HOME/.local/bin/starship"
  assert_present "$HOME/.local/bin/unrelated"
  assert_equals "$(outside_snapshot)" "$before"
}

test_local_copy_keeps_an_unrelated_file_of_the_same_name() {
  fake_tool "$HOME/.local/bin/uv" "not the uv you are looking for"
  fake_tool "$HOME/.local/bin/uvx" "uvx 0.9.1"
  printf 'data\n' > "$HOME/.local/bin/fnm"           # not executable at all
  remove_legacy_local_copy uv >/dev/null
  remove_legacy_local_copy fnm >/dev/null
  assert_present "$HOME/.local/bin/uv"
  assert_present "$HOME/.local/bin/uvx"
  assert_present "$HOME/.local/bin/fnm"
}

test_local_copy_removes_a_link_but_not_its_target_outside_home() {
  local before
  fake_tool "$OUTSIDE/starship" "starship 1.23.0"
  ln -s "$OUTSIDE/starship" "$HOME/.local/bin/starship"
  before=$(outside_snapshot)
  remove_legacy_local_copy starship >/dev/null
  assert_absent "$HOME/.local/bin/starship"
  assert_present "$OUTSIDE/starship"
  assert_equals "$(outside_snapshot)" "$before"
}

test_local_copy_is_macos_only() {
  local family
  fake_tool "$HOME/.local/bin/uv" "uv 0.9.1"
  fake_tool "$HOME/.local/bin/uvx" "uvx 0.9.1"
  for family in apt fedora arch; do
    OS_FAMILY=$family
    assert_equals "$(remove_legacy_local_copy uv)" ""
  done
  assert_present "$HOME/.local/bin/uv"
  assert_present "$HOME/.local/bin/uvx"
}

# rpatool is a pinned file, installed into ~/.local/bin on every platform.
test_local_copy_never_removes_a_pinned_artifact() {
  printf '#!/bin/sh\n' > "$HOME/.local/bin/rpatool"
  chmod 755 "$HOME/.local/bin/rpatool"
  assert_equals "$(remove_legacy_local_copy rpatool)" ""
  assert_present "$HOME/.local/bin/rpatool"
}

test_local_copy_dry_run_only_reports() {
  local out
  fake_tool "$HOME/.local/bin/uv" "uv 0.9.1"
  fake_tool "$HOME/.local/bin/uvx" "uvx 0.9.1"
  DRY_RUN=1
  out=$(remove_legacy_local_copy uv)
  assert_contains "$out" "+ rm -f -- $(printf '%q' "$HOME/.local/bin/uv")"
  assert_contains "$out" "+ rm -f -- $(printf '%q' "$HOME/.local/bin/uvx")"
  assert_present "$HOME/.local/bin/uv"
  assert_present "$HOME/.local/bin/uvx"
}

# The name selects a registry row; anything else (a path, a traversal) is an
# unknown artifact and removes nothing.
test_local_copy_refuses_names_outside_the_registry() {
  local name before
  fake_tool "$OUTSIDE/uv" "uv 0.9.1"
  fake_tool "$HOME/.local/bin/uv" "uv 0.9.1"
  before=$(outside_snapshot)
  for name in ../../../outside/uv "$OUTSIDE/uv" '*' ''; do
    (remove_legacy_local_copy "$name") >/dev/null 2>&1 || true
  done
  assert_present "$HOME/.local/bin/uv"
  assert_equals "$(outside_snapshot)" "$before"
}

# --- remove_legacy_npm_copy ---------------------------------------------------

# npm_fixture <prefix>: Yarn and pnpm as `npm install --global --prefix` lays
# them out, plus another global package that must survive.
npm_fixture() {
  local prefix=$1 package
  for package in yarn pnpm left-pad; do
    mkdir -p "$prefix/lib/node_modules/$package/bin"
    printf '{}\n' > "$prefix/lib/node_modules/$package/package.json"
  done
  ln -s ../lib/node_modules/yarn/bin/yarn.js "$prefix/bin/yarn"
  ln -s ../lib/node_modules/yarn/bin/yarn.js "$prefix/bin/yarnpkg"
  ln -s ../lib/node_modules/pnpm/bin/pnpm.cjs "$prefix/bin/pnpm"
  ln -s ../lib/node_modules/pnpm/bin/pnpx.cjs "$prefix/bin/pnpx"
  ln -s ../lib/node_modules/left-pad/bin/cli.js "$prefix/bin/left-pad"
}

test_npm_copy_removes_only_yarn() {
  local prefix="$HOME/.local/npm"
  npm_fixture "$prefix"
  remove_legacy_npm_copy yarn >/dev/null
  assert_absent "$prefix/lib/node_modules/yarn"
  assert_absent "$prefix/bin/yarn"
  assert_absent "$prefix/bin/yarnpkg"
  assert_present "$prefix/lib/node_modules/pnpm/package.json"
  assert_present "$prefix/lib/node_modules/left-pad/package.json"
  assert_present "$prefix/bin/pnpm"
  assert_present "$prefix/bin/pnpx"
  assert_present "$prefix/bin/left-pad"
}

test_npm_copy_removes_only_pnpm() {
  local prefix="$HOME/.local/npm"
  npm_fixture "$prefix"
  remove_legacy_npm_copy pnpm >/dev/null
  assert_absent "$prefix/lib/node_modules/pnpm"
  assert_absent "$prefix/bin/pnpm"
  assert_absent "$prefix/bin/pnpx"
  assert_present "$prefix/lib/node_modules/yarn/package.json"
  assert_present "$prefix/bin/yarn"
  assert_present "$prefix/bin/yarnpkg"
  assert_present "$prefix/bin/left-pad"
}

test_npm_copy_does_not_follow_links_out_of_home() {
  local prefix="$HOME/.local/npm" before
  mkdir -p "$OUTSIDE/yarn-checkout/bin"
  printf 'keep\n' > "$OUTSIDE/yarn-checkout/bin/yarn.js"
  printf 'keep\n' > "$OUTSIDE/yarnpkg"
  ln -s "$OUTSIDE/yarn-checkout" "$prefix/lib/node_modules/yarn"
  ln -s "$OUTSIDE/yarn-checkout/bin/yarn.js" "$prefix/bin/yarn"
  ln -s "$OUTSIDE/yarnpkg" "$prefix/bin/yarnpkg"
  before=$(outside_snapshot)
  remove_legacy_npm_copy yarn >/dev/null
  assert_absent "$prefix/lib/node_modules/yarn"
  assert_absent "$prefix/bin/yarn"
  assert_absent "$prefix/bin/yarnpkg"
  assert_equals "$(outside_snapshot)" "$before"
}

test_npm_copy_removes_dangling_links() {
  local prefix="$HOME/.local/npm"
  mkdir -p "$prefix/lib/node_modules/pnpm"
  ln -s ../lib/node_modules/pnpm/missing "$prefix/bin/pnpm"
  ln -s ../lib/node_modules/pnpm/missing "$prefix/bin/pnpx"
  remove_legacy_npm_copy pnpm >/dev/null
  assert_absent "$prefix/bin/pnpm"
  assert_absent "$prefix/bin/pnpx"
  assert_absent "$prefix/lib/node_modules/pnpm"
}

# Without the package itself, a stray command of the same family stays.
test_npm_copy_is_a_no_op_without_the_package() {
  local prefix="$HOME/.local/npm"
  printf 'user file\n' > "$prefix/bin/yarnpkg"
  assert_equals "$(remove_legacy_npm_copy yarn)" ""
  assert_equals "$(remove_legacy_npm_copy pnpm)" ""
  assert_present "$prefix/bin/yarnpkg"
}

test_npm_copy_dry_run_only_reports() {
  local prefix="$HOME/.local/npm" out
  npm_fixture "$prefix"
  DRY_RUN=1
  out=$(remove_legacy_npm_copy yarn)
  assert_contains "$out" "+ rm -rf -- $(printf '%q' "$prefix/lib/node_modules/yarn")"
  assert_contains "$out" "+ rm -f -- $(printf '%q' "$prefix/bin/yarnpkg")"
  assert_present "$prefix/lib/node_modules/yarn/package.json"
  assert_present "$prefix/bin/yarn"
  assert_present "$prefix/bin/yarnpkg"
}

# The name becomes part of an `rm -rf` path: a traversal, another package or
# an empty name must be refused before anything is removed.
test_npm_copy_refuses_other_names() {
  local prefix="$HOME/.local/npm" name before
  npm_fixture "$prefix"
  mkdir -p "$OUTSIDE/victim"
  printf 'keep\n' > "$OUTSIDE/victim/file"
  printf 'keep\n' > "$HOME/keep"
  ln -s "$OUTSIDE/victim" "$prefix/bin/victim"
  before=$(outside_snapshot)
  for name in ../../../../../outside/victim ../../../.. left-pad victim '' '*'; do
    if (remove_legacy_npm_copy "$name") >/dev/null 2>&1; then
      fail "remove_legacy_npm_copy accepted '$name'"
    fi
  done
  assert_equals "$(outside_snapshot)" "$before"
  assert_present "$HOME/keep"
  assert_present "$prefix/lib/node_modules/left-pad/package.json"
  assert_present "$prefix/lib/node_modules/yarn/package.json"
  assert_present "$prefix/lib/node_modules/pnpm/package.json"
  assert_present "$prefix/bin/victim"
}

TESTS=(
  test_local_copy_removes_every_executable_of_the_tool
  test_local_copy_keeps_an_unrelated_file_of_the_same_name
  test_local_copy_removes_a_link_but_not_its_target_outside_home
  test_local_copy_is_macos_only
  test_local_copy_never_removes_a_pinned_artifact
  test_local_copy_dry_run_only_reports
  test_local_copy_refuses_names_outside_the_registry
  test_npm_copy_removes_only_yarn
  test_npm_copy_removes_only_pnpm
  test_npm_copy_does_not_follow_links_out_of_home
  test_npm_copy_removes_dangling_links
  test_npm_copy_is_a_no_op_without_the_package
  test_npm_copy_dry_run_only_reports
  test_npm_copy_refuses_other_names
)
failed=()
for CURRENT_TEST in "${TESTS[@]}"; do
  # set +e here and set -e inside: a subshell used as an `if` condition would
  # run with errexit disabled, hiding failures the tests rely on errexit for.
  set +e
  (
    set -e
    trap cleanup EXIT
    setup_fixture
    "$CURRENT_TEST"
  )
  status=$?
  set -e
  if (( status != 0 )); then
    printf 'FAILED: %s (exit %s)\n' "$CURRENT_TEST" "$status" >&2
    failed+=("$CURRENT_TEST")
  fi
done
if (( ${#failed[@]} > 0 )); then
  printf 'migration tests: %s of %s failed:\n' "${#failed[@]}" "${#TESTS[@]}" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
printf 'migration tests: PASS (%s tests)\n' "${#TESTS[@]}"
