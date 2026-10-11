#!/usr/bin/env bash
# Exercise the full apply orchestration in dry-run mode: main() dispatch, the
# run_step loop, install_os_packages command construction, and every install_*
# step's dry-run path. This is the only test that runs the real entrypoint end
# to end. Dry-run performs no mutations and needs no network (every mutating
# command is echoed by run(), and resolve_node_version / downloads / git are all
# guarded), so it is safe on any CI runner for the detected OS family.
#
# It runs against a fixture HOME/XDG state and a temporary copy of the public
# checkout, never the developer's: install.sh keeps its state in local/ beside
# itself, and on an already-provisioned machine recorded, verified steps are
# skipped, so the assertions below would otherwise depend on that history.
# Package-manager queries still see the real host.
# shellcheck disable=SC2016
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# Physical path: install.sh records its own `pwd -P` root.
FIXTURE=$(CDPATH='' cd -- "$(mktemp -d "${TMPDIR:-/tmp}/leos-apply-dryrun.XXXXXX")" && pwd -P)
trap 'rm -rf -- "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/home" "$FIXTURE/profile"
# Only the public files install.sh reads. No local/ state, plugin clones,
# legacy private override or VCS metadata.
cp -R "$ROOT/install.sh" "$ROOT/installer" "$ROOT/zsh" "$ROOT/util" "$FIXTURE/profile/"
rm -rf -- "$FIXTURE/profile/zsh/plugins" "$FIXTURE/profile/zsh/_private.zsh"

# The interpreter running this test also runs the installer (macOS CI runs both
# under the system Bash 3.2). A developer's ZDOTDIR must not steer the plan.
unset ZDOTDIR
out=$(HOME="$FIXTURE/home" XDG_STATE_HOME="$FIXTURE/home/.local/state" \
  XDG_CONFIG_HOME="$FIXTURE/home/.config" XDG_CACHE_HOME="$FIXTURE/home/.cache" \
  XDG_DATA_HOME="$FIXTURE/home/.local/share" \
  "${BASH:-bash}" "$FIXTURE/profile/install.sh" apply --yes --dry-run)

fail() { printf '%s\n' "$out" >&2; printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# `apply` says "apply complete"; only `reconcile` reports a reconciliation.
grep -q 'Profile apply complete' <<< "$out" || fail "dry-run apply did not run to completion"

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
