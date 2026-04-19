#!/usr/bin/env bash
#
# Leo's Profiles — Quick install bootstrap entrypoint
#
# Install:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"
# Use HTTPS instead of SSH: USE_HTTPS=1 /bin/bash -c "$(curl -fsSL ...)"
#

set -e

REPO_RAW_BASE="https://raw.githubusercontent.com/foxhatleo/leos-profiles/master"
BOOTSTRAP_PATH="util/quick-install.sh"

delegate_local_bootstrap() {
  local script_dir bootstrap_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bootstrap_script="$script_dir/$BOOTSTRAP_PATH"

  if [ -f "$bootstrap_script" ]; then
    exec /bin/bash "$bootstrap_script" "$@"
  fi

  return 1
}

fetch_remote_bootstrap() {
  local bootstrap_url
  bootstrap_url="$REPO_RAW_BASE/$BOOTSTRAP_PATH"

  if command -v curl >/dev/null 2>&1; then
    exec /bin/bash -c "$(curl -fsSL "$bootstrap_url")" -- "$@"
  elif command -v wget >/dev/null 2>&1; then
    exec /bin/bash -c "$(wget -qO- "$bootstrap_url")" -- "$@"
  else
    echo "Error: curl or wget is required to fetch the quick-install bootstrap script."
    exit 1
  fi
}

delegate_local_bootstrap "$@" || fetch_remote_bootstrap "$@"
