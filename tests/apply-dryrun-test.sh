#!/usr/bin/env bash
# Exercise the full apply orchestration in dry-run mode: main() dispatch, the
# run_step loop, install_os_packages command construction, and every install_*
# step's dry-run path. This is the only test that runs the real entrypoint end
# to end. Dry-run performs no mutations and needs no network (every mutating
# command is echoed by run(), and resolve_node_lts / downloads / git are all
# guarded), so it is safe on any CI runner for the detected OS family.
# shellcheck disable=SC2016
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

out=$(bash "$ROOT/install.sh" apply --yes --dry-run)

fail() { printf '%s\n' "$out" >&2; printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -q 'Profile reconciliation complete' <<< "$out" || fail "dry-run apply did not run to completion"

# Recommended defaults must construct a package install for the detected family.
case $(uname -s) in
  Darwin) grep -Eq '^\+ brew install ' <<< "$out" || fail "no 'brew install' line in the dry-run" ;;
  *) grep -Eq '^\+ (sudo )?(apt-get|dnf|pacman) ' <<< "$out" || fail "no package-manager line in the dry-run" ;;
esac

# The zsh loader step and default-shell step must be reached.
grep -q 'Running zsh-config' <<< "$out" || fail "zsh-config step was not reached"

# Even with full-upgrade defaults, no OS release-upgrade tooling may appear.
if grep -Eq 'do-release-upgrade|dnf[[:space:]]+system-upgrade|apt(-get)?[[:space:]]+(dist-upgrade|full-upgrade)' <<< "$out"; then
  fail "dry-run emitted OS release-upgrade tooling"
fi

printf 'apply dry-run (%s): PASS\n' "$(uname -s)"
