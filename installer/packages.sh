#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

ensure_sudo() {
  [[ $OS_FAMILY == macos ]] && return 0
  [[ $DRY_RUN -eq 1 || $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "Install sudo or run with package-manager privileges before setup"
  sudo -v
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

bootstrap_tools() {
  local -a missing=()
  local executable
  # macOS /usr/bin/git can be a CLT stub, so test execution, not just PATH.
  if ! command -v git >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then missing+=(git); fi
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  if [[ $OS_FAMILY == macos ]]; then
    ensure_brew
    if (( ${#missing[@]} )); then run brew install "${missing[@]}"; fi
    return 0
  fi
  for executable in unzip tar gzip; do
    command -v "$executable" >/dev/null 2>&1 || missing+=("$executable")
  done
  package_installed ca-certificates || missing+=(ca-certificates)
  if (( ${#missing[@]} == 0 )); then
    say "Git, curl, TLS certificates and archive tools are already present; skipping bootstrap"
    return 0
  fi
  ensure_sudo
  case $OS_FAMILY in
    apt)
      run sudo apt-get update
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
    fedora) run sudo dnf install -y "${missing[@]}" ;;
    arch) run sudo pacman -S --needed --noconfirm "${missing[@]}" ;;
  esac
}

package_list_for_group() {
  local group=$1
  case "$OS_FAMILY:$group" in
    macos:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils gnu-indent gnu-sed gnu-tar gnu-which grep gawk gzip less nano' ;;
    macos:shell) printf '%s\n' 'zsh' ;;
    macos:dev-tools) printf '%s\n' 'bat direnv eza fd fzf git pkg-config openssl@3 readline ripgrep sqlite3 tcl-tk vim xz zlib zoxide' ;;
    macos:languages) printf '%s\n' 'node python ruby' ;;
    macos:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    macos:network) printf '%s\n' 'wget rclone gnutls heroku ssh-copy-id' ;;
    macos:system) printf '%s\n' 'smartmontools' ;;
    apt:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    apt:shell) printf '%s\n' 'zsh' ;;
    apt:dev-tools) printf '%s\n' 'bat build-essential clang direnv fd-find fzf gcc git libbz2-dev libffi-dev liblzma-dev libncurses-dev libreadline-dev libsqlite3-dev libssl-dev libxml2-dev libxmlsec1-dev llvm ripgrep tk-dev vim xz-utils zlib1g-dev zoxide' ;;
    apt:languages) printf '%s\n' 'nodejs npm python-is-python3 ruby' ;;
    apt:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    apt:network) printf '%s\n' 'wget rclone' ;;
    apt:system) printf '%s\n' 'smartmontools' ;;
    fedora:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    fedora:shell) printf '%s\n' 'zsh' ;;
    fedora:dev-tools) printf '%s\n' 'bat bzip2 bzip2-devel direnv fd-find fzf gcc gdbm-libs git libffi-devel libnsl2 libuuid-devel make openssl-devel patch readline-devel ripgrep sqlite sqlite-devel tk-devel vim xz-devel zlib-devel zoxide' ;;
    fedora:languages) printf '%s\n' 'nodejs python-unversioned-command ruby' ;;
    fedora:media) printf '%s\n' 'ImageMagick ffmpeg yt-dlp' ;;
    fedora:network) printf '%s\n' 'wget rclone' ;;
    fedora:system) printf '%s\n' 'smartmontools' ;;
    arch:core-utils) printf '%s\n' 'bash coreutils diffutils ed findutils grep gawk gzip less nano' ;;
    arch:shell) printf '%s\n' 'zsh' ;;
    arch:dev-tools) printf '%s\n' 'base-devel bat direnv eza fd fzf git libffi openssl ripgrep tk vim xz zlib zoxide' ;;
    arch:languages) printf '%s\n' 'nodejs npm python ruby' ;;
    arch:media) printf '%s\n' 'ffmpeg imagemagick yt-dlp' ;;
    arch:network) printf '%s\n' 'wget rclone' ;;
    arch:system) printf '%s\n' 'smartmontools' ;;
  esac
}

collect_selected_packages() {
  local group package_list
  local -a group_packages
  local old_ifs=$IFS
  SELECTED_PACKAGES=()
  IFS=,
  for group in $SELECTED_GROUPS; do
    package_list=$(package_list_for_group "$group")
    IFS=' '
    read -r -a group_packages <<< "$package_list"
    SELECTED_PACKAGES+=("${group_packages[@]}")
    IFS=,
  done
  IFS=$old_ifs
}

package_installed() {
  local package=$1
  case $OS_FAMILY in
    macos) brew list --versions "$package" >/dev/null 2>&1 ;;
    apt) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed' ;;
    fedora) rpm -q --whatprovides "$package" >/dev/null 2>&1 ;;
    arch) pacman -Q "$package" >/dev/null 2>&1 ;;
  esac
}

selected_packages_installed() {
  local package installed_lines
  collect_selected_packages
  (( ${#SELECTED_PACKAGES[@]} > 0 )) || return 0
  if [[ $OS_FAMILY == macos ]]; then
    # One brew invocation: it prints one line per installed formula among
    # the arguments (aliases resolve to their real names).
    installed_lines=$(brew list --versions "${SELECTED_PACKAGES[@]}" 2>/dev/null | grep -c . || true)
    (( installed_lines == ${#SELECTED_PACKAGES[@]} ))
    return
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
      if has_csv_item "$SELECTED_GROUPS" network; then run brew tap heroku/brew; fi
      if [[ $FULL_UPGRADE -eq 1 ]]; then
        run brew update
        run brew upgrade
        run brew upgrade --cask
      fi
      run brew install "${requested[@]}" ;;
    apt)
      run sudo apt-get update
      [[ $FULL_UPGRADE -eq 0 ]] || run sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${requested[@]}"
      apt_compat_links ;;
    fedora)
      [[ $FULL_UPGRADE -eq 0 ]] || run sudo dnf upgrade -y
      if has_csv_item "$SELECTED_GROUPS" media; then
        if ! package_installed rpmfusion-free-release; then
          run sudo dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
        fi
        run sudo dnf install -y --allowerasing "${requested[@]}"
      else
        run sudo dnf install -y "${requested[@]}"
      fi ;;
    arch)
      [[ $FULL_UPGRADE -eq 0 ]] || run sudo pacman -Syu --noconfirm
      run sudo pacman -S --needed --noconfirm "${requested[@]}" ;;
  esac
}
