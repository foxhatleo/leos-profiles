#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

# SUDO: the prefix for every command that needs root, empty when the
# installer already runs as root (containers), so nothing there depends on a
# sudo binary (CQ-7). run_root and the /etc/shells edit in config.sh use it.
SUDO=sudo
[[ $EUID -ne 0 ]] || SUDO=""

# sudo resets the environment, which drops a proxy the package managers need
# behind a corporate or regional proxy (ONB-10). When any of these is set,
# run_root asks sudo to keep them all.
sudo_preserve_proxy_flag() {
  local name list=""
  for name in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY all_proxy; do
    list="${list:+$list,}$name"
  done
  for name in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY all_proxy; do
    if [[ -n ${!name-} ]]; then
      printf -- '--preserve-env=%s\n' "$list"
      return 0
    fi
  done
  return 1
}

# run_root <command...>: `run` with the root prefix.
run_root() {
  local preserve
  if [[ -z $SUDO ]]; then
    run "$@"
  elif preserve=$(sudo_preserve_proxy_flag); then
    run "$SUDO" "$preserve" "$@"
  else
    run "$SUDO" "$@"
  fi
}

# Homebrew through the USTC mirror: the same three variables as
# __leos_brew_china_export in zsh/path/brew.zsh, which a test keeps equal.
# `--brew-mirror china` applies them to this run (including a Homebrew
# bootstrap) and sets the runtime flag that brew.zsh reads; `none` clears it.
# Without the option, the existing flag decides, so reconcile follows it.
BREW_CHINA_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
BREW_CHINA_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
BREW_CHINA_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
brew_mirror_effective() {
  case $BREW_MIRROR in
    china|none) printf '%s\n' "$BREW_MIRROR" ;;
    *) if [[ -f $LOCAL_DIR/flags/brew-china ]]; then printf 'china\n'; else printf 'none\n'; fi ;;
  esac
}

apply_brew_mirror() {
  [[ $OS_FAMILY == macos ]] || return 0
  if [[ $BREW_MIRROR == china ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would set the Homebrew mirror flag $LOCAL_DIR/flags/brew-china"
    else
      prepare_local_dir
      : > "$LOCAL_DIR/flags/brew-china"
      chmod 600 "$LOCAL_DIR/flags/brew-china"
    fi
  elif [[ $BREW_MIRROR == none && -e $LOCAL_DIR/flags/brew-china ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would remove the Homebrew mirror flag $LOCAL_DIR/flags/brew-china"
    else
      rm -f -- "$LOCAL_DIR/flags/brew-china"
    fi
  fi
  if [[ $(brew_mirror_effective) == china ]]; then
    say "Using the USTC Homebrew mirror for brew.git, metadata and bottles"
    export HOMEBREW_BREW_GIT_REMOTE=$BREW_CHINA_GIT_REMOTE
    export HOMEBREW_BOTTLE_DOMAIN=$BREW_CHINA_BOTTLE_DOMAIN
    export HOMEBREW_API_DOMAIN=$BREW_CHINA_API_DOMAIN
  fi
}

ensure_sudo() {
  [[ $OS_FAMILY == macos ]] && return 0
  [[ $DRY_RUN -eq 1 || -z $SUDO ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "Install sudo or run with package-manager privileges before setup"
  sudo -v
}

# apt indexes are refreshed once per run, before the first apt-get operation.
APT_INDEX_UPDATED=0
apt_update_once() {
  [[ $APT_INDEX_UPDATED -eq 0 ]] || return 0
  run_root apt-get update
  APT_INDEX_UPDATED=1
}

# apt_get <arguments...>: apt-get as root, never stopping at a prompt. A
# changed configuration file keeps the local version unless the package's
# default is to replace an unmodified one (BP-7), as unattended upgrades do.
apt_get() {
  run_root env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# pkg_install <packages...>: install packages with the host package manager.
# The bootstrap, the packages step and the credential prerequisites all use
# this one definition (CQ-3).
#
# Arch never installs against a stale sync database: Arch does not support
# partial upgrades, and an old database names package versions the mirrors no
# longer carry. Whenever anything is missing it syncs and upgrades the whole
# system in the same transaction (BP-8); inspect discloses this.
pkg_install() {
  (( $# )) || return 0
  case $OS_FAMILY in
    macos)
      ensure_brew
      run brew install "$@" ;;
    apt)
      apt_update_once
      apt_get install -y "$@" ;;
    fedora) run_root dnf install -y "$@" ;;
    arch) run_root pacman -Syu --needed --noconfirm "$@" ;;
    *) die "Unsupported package family: $OS_FAMILY" ;;
  esac
}

# Fedora ships ffmpeg-free; the media group's full ffmpeg comes from RPM
# Fusion. Everything else installs normally. ffmpeg alone then replaces
# ffmpeg-free with `dnf swap ... --allowerasing`, RPM Fusion's documented
# method, so package removal is scoped to that swap (SEC-4).
FEDORA_FFMPEG_SWAP=(dnf swap -y ffmpeg-free ffmpeg --allowerasing)
fedora_install_media() {
  local package
  local -a others=()
  for package in "$@"; do
    [[ $package == ffmpeg ]] || others+=("$package")
  done
  if ! package_installed rpmfusion-free-release; then
    run_root dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
  fi
  pkg_install ${others[@]+"${others[@]}"}
  # The RPM Fusion package is named ffmpeg; Fedora's is ffmpeg-free.
  if [[ $DRY_RUN -eq 1 ]] || ! rpm -q ffmpeg >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]] || rpm -q ffmpeg-free >/dev/null 2>&1; then
      run_root "${FEDORA_FFMPEG_SWAP[@]}"
    else
      run_root dnf install -y ffmpeg
    fi
  fi
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  local installer candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x $candidate ]]; then
      eval "$("$candidate" shellenv bash)"
      return 0
    fi
  done
  if [[ $DRY_RUN -eq 0 ]] && ! xcode-select -p >/dev/null 2>&1; then
    die "Install macOS Command Line Tools with xcode-select --install, then retry setup"
  fi
  installer=$(mktemp "${TMPDIR:-/tmp}/leos-homebrew-install.XXXXXX")
  track_temp "$installer"
  say "Installing Homebrew from a pinned, SHA-256-verified script"
  download_verified "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$installer"
  run /bin/bash "$installer"
  [[ $DRY_RUN -eq 0 ]] || return 0
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x $candidate ]]; then
      eval "$("$candidate" shellenv bash)"
      break
    fi
  done
  command -v brew >/dev/null 2>&1 || die "Homebrew installation did not put brew on PATH"
}

# bootstrap_missing: the bootstrap packages this host lacks, space-separated.
bootstrap_missing() {
  local executable missing=""
  # macOS /usr/bin/git can be a CLT stub, so test execution, not just PATH.
  if ! command -v git >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then missing+=" git"; fi
  command -v curl >/dev/null 2>&1 || missing+=" curl"
  if [[ $OS_FAMILY != macos ]]; then
    for executable in unzip tar gzip; do
      command -v "$executable" >/dev/null 2>&1 || missing+=" $executable"
    done
    # GNU tar runs xz for the Nerd Fonts .tar.xz archives.
    if ! command -v xz >/dev/null 2>&1; then
      if [[ $OS_FAMILY == apt ]]; then missing+=" xz-utils"; else missing+=" xz"; fi
    fi
    package_installed ca-certificates || missing+=" ca-certificates"
  fi
  printf '%s' "${missing# }"
}

bootstrap_tools() {
  local -a missing=()
  IFS=' ' read -r -a missing <<< "$(bootstrap_missing)"
  if [[ $OS_FAMILY == macos ]]; then
    ensure_brew
    pkg_install ${missing[@]+"${missing[@]}"}
    return 0
  fi
  if (( ${#missing[@]} == 0 )); then
    say "Git, curl, TLS certificates and archive tools are already present; skipping bootstrap"
    return 0
  fi
  ensure_sudo
  pkg_install "${missing[@]}"
}

# dev-tools carries the GitHub CLI and jq on every family (MI-8), and every
# build dependency ruby-build's suggested build environment lists for Ruby 3
# (openssl, readline, zlib, libyaml for psych, libffi), so `rbenv install`
# works without extra packages (ONB-3); macOS takes libffi from the SDK.
#
# macOS names are canonical Homebrew formula names, not aliases: `brew list
# --formula` prints those, and an alias can move. pkgconf and sqlite are what
# the pkg-config and sqlite3 aliases resolve to. python is the versioned
# formula on purpose: the `python`/`python3` aliases follow Homebrew's newest
# minor release, so each move made reconcile install another Python next to
# the old one. Change python@3.15 here deliberately.
# heroku is a macOS-only group (the CLI comes from Heroku's Homebrew tap); it
# has no members elsewhere, and main() refuses it there.
package_list_for_group() {
  local group=$1
  case "$OS_FAMILY:$group" in
    macos:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils gnu-indent gnu-sed gnu-tar gnu-which grep gawk gzip less nano' ;;
    macos:shell) printf '%s\n' 'zsh' ;;
    macos:dev-tools) printf '%s\n' 'bat direnv eza fd fzf gh git jq libyaml pkgconf openssl@3 readline ripgrep sqlite tcl-tk vim xz zlib zoxide' ;;
    macos:languages) printf '%s\n' 'node python@3.15 ruby' ;;
    macos:python) printf '%s\n' 'python@3.15' ;;
    macos:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    macos:network) printf '%s\n' 'wget rclone gnutls ssh-copy-id' ;;
    macos:heroku) printf '%s\n' 'heroku' ;;
    macos:system) printf '%s\n' 'smartmontools' ;;
    apt:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    apt:shell) printf '%s\n' 'zsh' ;;
    apt:dev-tools) printf '%s\n' 'bat build-essential clang direnv fd-find fzf gcc gh git jq libbz2-dev libffi-dev liblzma-dev libncurses-dev libreadline-dev libsqlite3-dev libssl-dev libxml2-dev libxmlsec1-dev libyaml-dev llvm ripgrep tk-dev vim xz-utils zlib1g-dev zoxide' ;;
    apt:languages) printf '%s\n' 'nodejs npm python-is-python3 ruby' ;;
    apt:python) printf '%s\n' 'python3' ;;
    apt:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    apt:network) printf '%s\n' 'wget rclone' ;;
    apt:system) printf '%s\n' 'smartmontools' ;;
    fedora:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    fedora:shell) printf '%s\n' 'zsh' ;;
    fedora:dev-tools) printf '%s\n' 'bat bzip2 bzip2-devel direnv fd-find fzf gcc gdbm-libs gh git jq libffi-devel libnsl2 libuuid-devel libyaml-devel make openssl-devel patch readline-devel ripgrep sqlite sqlite-devel tk-devel vim xz-devel zlib-devel zoxide' ;;
    fedora:languages) printf '%s\n' 'nodejs python-unversioned-command ruby' ;;
    fedora:python) printf '%s\n' 'python3' ;;
    fedora:media) printf '%s\n' 'ImageMagick ffmpeg yt-dlp' ;;
    fedora:network) printf '%s\n' 'wget rclone' ;;
    fedora:system) printf '%s\n' 'smartmontools' ;;
    arch:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    arch:shell) printf '%s\n' 'zsh' ;;
    arch:dev-tools) printf '%s\n' 'base-devel bat direnv eza fd fzf git github-cli jq libffi libyaml openssl readline ripgrep tk vim xz zlib zoxide' ;;
    arch:languages) printf '%s\n' 'nodejs npm python ruby' ;;
    arch:python) printf '%s\n' 'python' ;;
    arch:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    arch:network) printf '%s\n' 'wget rclone' ;;
    arch:system) printf '%s\n' 'smartmontools' ;;
  esac
}

# SELECTED_PACKAGES: every member of the selected groups, in group order, each
# package once (two groups may share a member, such as python and languages).
collect_selected_packages() {
  local group package seen=" "
  local -a groups=() group_packages=()
  SELECTED_PACKAGES=()
  csv_split groups "$SELECTED_GROUPS"
  for group in ${groups[@]+"${groups[@]}"}; do
    IFS=' ' read -r -a group_packages <<< "$(package_list_for_group "$group")"
    for package in ${group_packages[@]+"${group_packages[@]}"}; do
      [[ $seen != *" $package "* ]] || continue
      seen="$seen$package "
      SELECTED_PACKAGES+=("$package")
    done
  done
}

package_installed() {
  local package=$1
  case $OS_FAMILY in
    macos)
      # One `brew list --formula -1` answers every check (see
      # load_brew_formulae); callers clear BREW_FORMULAE after installing.
      [[ -n $BREW_FORMULAE ]] || load_brew_formulae || return 1
      brew_formula_installed "$package" ;;
    apt) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed' ;;
    fedora) rpm -q --whatprovides "$package" >/dev/null 2>&1 ;;
    arch) pacman -Q "$package" >/dev/null 2>&1 ;;
  esac
}

# macOS: every selected package is checked against one `brew list --formula -1`
# call (about 0.3 s) instead of a `brew list --versions` per package (about
# 0.25 s each). The package map uses canonical formula names, which that list
# prints. A name that is not in it can still be an alias or an old name of an
# installed formula: Homebrew keeps an opt/<name> link for each of those, so
# that link counts as installed. Asking brew to resolve the alias instead
# would follow wherever the alias points today (`python` moving to a new minor
# version) rather than what is installed. Casks are not consulted: the map
# holds formulae only.
BREW_FORMULAE=""
BREW_FORMULAE_PREFIX=""
load_brew_formulae() {
  local listed
  listed=$(brew list --formula -1 2>/dev/null) || return 1
  BREW_FORMULAE=$'\n'"$listed"$'\n'
  BREW_FORMULAE_PREFIX=${HOMEBREW_PREFIX:-}
  [[ -n $BREW_FORMULAE_PREFIX ]] || BREW_FORMULAE_PREFIX=$(brew --prefix 2>/dev/null) || BREW_FORMULAE_PREFIX=""
  return 0
}

brew_formula_installed() {
  local package=$1
  case $BREW_FORMULAE in
    *$'\n'"$package"$'\n'*) return 0 ;;
  esac
  [[ -n $BREW_FORMULAE_PREFIX && $package != */* && -d $BREW_FORMULAE_PREFIX/opt/$package ]]
}

selected_packages_installed() {
  local package
  collect_selected_packages
  (( ${#SELECTED_PACKAGES[@]} > 0 )) || return 0
  if [[ $OS_FAMILY == macos ]]; then
    load_brew_formulae || return 1
    for package in "${SELECTED_PACKAGES[@]}"; do
      brew_formula_installed "$package" || return 1
    done
    return 0
  fi
  for package in "${SELECTED_PACKAGES[@]}"; do
    package_installed "$package" || return 1
  done
}

apt_compat_links() {
  [[ $OS_FAMILY == apt ]] || return 0
  local pair name provider
  for pair in fd:fdfind bat:batcat; do
    name=${pair%:*}; provider=${pair#*:}
    if ! command -v "$name" >/dev/null 2>&1 && command -v "$provider" >/dev/null 2>&1; then
      run mkdir -p "$HOME/.local/bin"
      run ln -sf "$(command -v "$provider")" "$HOME/.local/bin/$name"
    fi
  done
}

apt_compat_links_valid() {
  [[ $OS_FAMILY == apt ]] || return 0
  local pair name provider
  for pair in fd:fdfind bat:batcat; do
    name=${pair%:*}; provider=${pair#*:}
    if ! command -v "$name" >/dev/null 2>&1 && command -v "$provider" >/dev/null 2>&1; then
      [[ -L $HOME/.local/bin/$name && $(readlink "$HOME/.local/bin/$name") == "$(command -v "$provider")" ]] || return 1
    fi
  done
}

install_os_packages() {
  collect_selected_packages
  (( ${#SELECTED_PACKAGES[@]} > 0 )) || return 0
  local package
  local -a requested=()
  # Start from a fresh formula list (macOS); without a usable brew every
  # package is requested.
  BREW_FORMULAE=""
  for package in "${SELECTED_PACKAGES[@]}"; do
    if [[ $FULL_UPGRADE -eq 1 ]] || ! package_installed "$package"; then requested+=("$package"); fi
  done
  if [[ $FULL_UPGRADE -eq 0 && ${#requested[@]} -eq 0 ]]; then
    say "All selected packages are installed"
    apt_compat_links
    return 0
  fi
  ensure_sudo
  # Full upgrades stay within the configured OS release/repositories.
  case $OS_FAMILY in
    macos)
      ensure_brew
      # Heroku's third-party tap is trusted only when its group is selected.
      if has_csv_item "$SELECTED_GROUPS" heroku; then run brew tap heroku/brew; fi
      if [[ $FULL_UPGRADE -eq 1 ]]; then
        run brew update
        run brew upgrade
        run brew upgrade --cask
      fi
      pkg_install "${requested[@]}"
      BREW_FORMULAE="" ;;
    apt)
      apt_update_once
      [[ $FULL_UPGRADE -eq 0 ]] || apt_get upgrade -y
      pkg_install "${requested[@]}"
      apt_compat_links ;;
    fedora)
      [[ $FULL_UPGRADE -eq 0 ]] || run_root dnf upgrade -y
      if has_csv_item "$SELECTED_GROUPS" media; then
        fedora_install_media "${requested[@]}"
      else
        pkg_install "${requested[@]}"
      fi ;;
    arch)
      # pkg_install's -Syu is the full upgrade too: with FULL_UPGRADE every
      # selected package is requested, so there is always something to pass.
      pkg_install "${requested[@]}" ;;
  esac
}
