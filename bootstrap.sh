#!/usr/bin/env bash
# Leo's Profiles bootstrap:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/bootstrap.sh)"
#
# Installs Git when it is missing, clones the profile into ~/.leos-profiles
# (or LEOS_PROFILES_HOME) or fast-forwards a clean existing checkout of it,
# then starts the interactive setup on the terminal. Arguments are passed on
# to `install.sh setup` (bash -c "..." _ --dry-run).
#
# Every statement runs inside main, called on the last line: a download cut
# short defines some functions at most and runs nothing. Bash 3.2 compatible
# (a new Mac's /bin/bash).

bs_say() { printf '==> %s\n' "$*"; }
bs_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# bs_os: BS_OS becomes macos, apt, fedora, arch or unknown.
bs_os() {
  [[ -z ${BS_OS:-} ]] || return 0
  case $(uname -s) in
    Darwin) BS_OS=macos ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then BS_OS=apt
      elif command -v dnf >/dev/null 2>&1; then BS_OS=fedora
      elif command -v pacman >/dev/null 2>&1; then BS_OS=arch
      else BS_OS=unknown
      fi ;;
    *) BS_OS=unknown ;;
  esac
}

# bs_root <command...>: as root, through sudo unless already root.
bs_root() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || bs_die "Installing Git needs root: install sudo, or run this as root"
    sudo "$@"
  fi
}

# bs_git_works: a Git that runs. On macOS /usr/bin/git is a stub until the
# Command Line Tools are installed, and running it opens their installer, so
# ask xcode-select first.
bs_git_works() {
  if [[ $BS_OS == macos ]] && ! xcode-select -p >/dev/null 2>&1; then return 1; fi
  command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1
}

bs_install_git() {
  local polls=0
  if bs_git_works; then return 0; fi
  case $BS_OS in
    macos)
      bs_say "Git comes with Apple's Command Line Tools. macOS opens their installer now: choose Install, and this waits until it finishes."
      xcode-select --install >/dev/null 2>&1 || true
      until bs_git_works; do
        if (( polls >= BS_POLL_LIMIT )); then
          bs_die "The Command Line Tools are still not installed. Finish their installer (or run xcode-select --install), then run this command again."
        fi
        sleep "$BS_POLL_SECONDS"
        polls=$((polls + 1))
      done ;;
    apt)
      bs_say "Installing Git"
      bs_root apt-get update
      bs_root env DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates ;;
    fedora)
      bs_say "Installing Git"
      bs_root dnf install -y git ca-certificates ;;
    arch)
      # Arch has no partial upgrades: installing syncs and upgrades the system.
      bs_say "Installing Git (pacman -Syu: Arch upgrades the whole system with it)"
      bs_root pacman -Syu --needed --noconfirm git ca-certificates ;;
    *)
      bs_die "Unsupported platform (expected macOS, Debian/Ubuntu, Fedora or Arch Linux). Install Git yourself, then rerun." ;;
  esac
  bs_git_works || bs_die "Git is still not available after installing it"
}

# bs_origin_ok <url>: the URL names the profile's GitHub repository, over
# HTTPS or SSH, with or without .git.
bs_origin_ok() {
  local url
  url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  url=${url%/}
  url=${url%.git}
  case $url in
    https://github.com/foxhatleo/leos-profiles|git@github.com:foxhatleo/leos-profiles|ssh://git@github.com/foxhatleo/leos-profiles) return 0 ;;
    *) return 1 ;;
  esac
}

# bs_checkout <dir>: clone the profile into <dir>, or fast-forward the clean
# checkout of it already there. Anything else there is left alone.
bs_checkout() {
  local dir=$1 origin
  if [[ ! -e $dir && ! -L $dir ]]; then
    bs_say "Cloning Leo's Profiles into $dir"
    mkdir -p "$(dirname -- "$dir")"
    git clone "$BS_REPOSITORY" "$dir"
    return 0
  fi
  [[ -d $dir/.git ]] ||
    bs_die "$dir exists but is not a Git checkout. Move it away (or set LEOS_PROFILES_HOME to another directory), then rerun."
  origin=$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)
  bs_origin_ok "$origin" ||
    bs_die "$dir is a checkout of ${origin:-a repository without an origin}, not $BS_REPOSITORY. Move it away (or set LEOS_PROFILES_HOME to another directory), then rerun."
  if [[ -n $(git -C "$dir" status --porcelain) ]]; then
    bs_die "$dir has local changes (see git -C $dir status). Commit or remove them, then rerun: the update must not mix with uncommitted work."
  fi
  bs_say "Updating the existing checkout in $dir (fast-forward only)"
  git -C "$dir" pull --ff-only ||
    bs_die "Could not fast-forward $dir (a diverged branch, or no branch checked out). Update it yourself, then rerun."
}

# bs_start_setup <dir> [setup arguments...]: replace this process with the
# checkout's setup, reading the terminal even when this script's stdin is a
# pipe.
bs_start_setup() {
  local dir=$1
  shift
  if ! { : </dev/tty; } 2>/dev/null; then
    bs_die "No terminal to ask the setup questions on. Run bash $dir/install.sh setup in a terminal, or, unattended, bash $dir/install.sh apply --yes"
  fi
  exec bash "$dir/install.sh" setup "$@" </dev/tty
}

main() {
  set -euo pipefail
  local dir
  BS_REPOSITORY=https://github.com/foxhatleo/leos-profiles.git
  BS_POLL_SECONDS=${BS_POLL_SECONDS:-5}
  BS_POLL_LIMIT=${BS_POLL_LIMIT:-720}
  dir=${LEOS_PROFILES_HOME:-$HOME/.leos-profiles}
  [[ $dir == /* ]] || bs_die "LEOS_PROFILES_HOME must be an absolute path: $dir"
  bs_os
  bs_install_git
  bs_checkout "$dir"
  bs_start_setup "$dir" "$@"
}

[[ ${LEOS_BOOTSTRAP_LIB_ONLY:-0} == 1 ]] || main "$@"
