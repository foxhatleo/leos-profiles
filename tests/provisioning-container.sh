#!/usr/bin/env bash
# Root entrypoint for a disposable Linux container, not a host provisioning tool.
set -Eeuo pipefail
IFS=$'\n\t'

if [[ ${GITHUB_ACTIONS:-} != true && ! -f /.leos-disposable-ci-container ]]; then
  printf '%s\n' 'Refusing real provisioning outside disposable CI.' >&2
  exit 2
fi
[[ -f /.dockerenv || -f /run/.containerenv ]] || {
  printf '%s\n' 'This entrypoint requires a disposable container.' >&2; exit 2;
}
[[ $(id -u) == 0 ]] || { printf '%s\n' 'Container bootstrap requires root.' >&2; exit 2; }

# Only bootstrap tools required to create/run the test user. The installer must
# supply its own application dependencies, archive tools, and language runtimes.
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y sudo git ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y sudo git shadow-utils tar gzip findutils ca-certificates
elif command -v pacman >/dev/null 2>&1; then
  pacman -Syu --noconfirm --needed sudo git tar gzip ca-certificates
else
  printf '%s\n' 'Unsupported container package manager.' >&2
  exit 2
fi

useradd --create-home --shell /bin/bash leos-ci
printf '%s\n' 'leos-ci ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/leos-ci
chmod 440 /etc/sudoers.d/leos-ci
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
exec sudo --preserve-env=GITHUB_ACTIONS -H -u leos-ci bash "$ROOT/tests/provisioning-test.sh"
