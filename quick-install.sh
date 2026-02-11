#!/usr/bin/env bash
#
# Leo's Profiles — Quick install script
#
# Install:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"
# Use HTTPS instead of SSH: USE_HTTPS=1 /bin/bash -c "$(curl -fsSL ...)"
#

# -----------------------------------------------------------------------------
# Terminal colors (only if connected to a TTY that supports them)
# -----------------------------------------------------------------------------
if which tput >/dev/null 2>&1; then
  ncolors=$(tput colors)
fi
if [ -t 1 ] && [ -n "${ncolors:-}" ] && [ "$ncolors" -ge 8 ]; then
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"
  BOLD="$(tput bold)"
  NORMAL="$(tput sgr0)"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  BOLD=""
  NORMAL=""
fi

# Exit on error (after non-critical color setup)
set -e

# Insecure umask can cause compinit/compdef errors; restrict group/other write
umask g-w,o-w

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
: "${PF:=$HOME/.leos-profiles}"
# Set USE_HTTPS=1 to skip SSH and clone via HTTPS (e.g. in CI or if you prefer)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Print path of first existing SSH public key (id_ed25519, id_rsa, id_ecdsa, etc.)
find_ssh_public_key() {
  local key
  for key in id_ed25519 id_rsa id_ecdsa id_ecdsa_sk id_ed25519_sk; do
    if [ -f "$HOME/.ssh/${key}.pub" ]; then
      echo "$HOME/.ssh/${key}.pub"
      return 0
    fi
  done
  return 1
}

# Ensure ~/.ssh exists and user has at least one SSH public key; create one if not.
# Prefers ed25519, falls back to RSA for older ssh-keygen.
ensure_ssh_key() {
  local keypath="$HOME/.ssh/id_ed25519"
  find_ssh_public_key >/dev/null && return 0

  printf "${BLUE}No SSH public key found. Generating one...${NORMAL}\n"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if ssh-keygen -t ed25519 -f "$keypath" -N "" -q 2>/dev/null; then
    return 0
  fi

  keypath="$HOME/.ssh/id_rsa"
  printf "${YELLOW}ed25519 not available, generating RSA 4096 key.${NORMAL}\n"
  ssh-keygen -t rsa -b 4096 -f "$keypath" -N "" -q
}

# Print public key and ask user to add it to GitHub, then wait for Enter (if interactive).
prompt_ssh_key_added_to_github() {
  local pubkey
  pubkey=$(find_ssh_public_key) || return 1
  printf "\n${BOLD}Add this SSH key to GitHub (https://github.com/settings/keys):${NORMAL}\n\n"
  cat "$pubkey"
  printf "\n${BLUE}Then press Enter to continue (or set USE_HTTPS=1 and re-run to clone via HTTPS instead).${NORMAL}\n"
  [ -t 0 ] && read -r
}

apply_fish_config() {
  printf "${BLUE}Installing fish config...${NORMAL}\n"
  FISH_CONFIG_PATH="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$FISH_CONFIG_PATH")"
  cat << EOF > "$FISH_CONFIG_PATH"
if status is-interactive
    source "$HOME/.leos-profiles/start.fish"
    set fish_greeting
end
EOF
}

# Clone repo. Pass use_ssh=1 for SSH, 0 for HTTPS.
clone_repo() {
  local use_ssh="${1:-1}"
  if [ -d "$PF" ]; then
    printf "${YELLOW}You already have Leo's Profiles cloned.${NORMAL}\n"
    return 0
  fi
  command -v git >/dev/null 2>&1 || {
    echo "Error: git is not installed"
    exit 1
  }
  if [ "$use_ssh" = "1" ]; then
    printf "${BLUE}Cloning Leo's Profiles (SSH)...${NORMAL}\n"
    env git clone git@github.com:foxhatleo/leos-profiles.git "$PF" || {
      printf "Error: git clone via SSH failed. Try again or run with USE_HTTPS=1 to use HTTPS.\n"
      exit 1
    }
  else
    printf "${BLUE}Cloning Leo's Profiles (HTTPS)...${NORMAL}\n"
    env git clone https://github.com/foxhatleo/leos-profiles "$PF" || {
      printf "Error: git clone of Leo's Profiles repo failed\n"
      exit 1
    }
  fi
}

# Ensure SSH key exists, prompt user to add to GitHub, then clone. Or use HTTPS if skipped.
prepare_and_clone_repo() {
  local use_ssh=1
  if [ -d "$PF" ]; then
    clone_repo 1
    return 0
  fi

  if [ -n "${USE_HTTPS:-}" ]; then
    use_ssh=0
  elif [ -t 0 ]; then
    printf "${BLUE}Clone with SSH? (recommended; requires this machine's SSH key on GitHub) [Y/n]: ${NORMAL}"
    read -r answer
    case "$answer" in
      n|N|no|NO) use_ssh=0 ;;
    esac
  else
    use_ssh=0
  fi

  if [ "$use_ssh" = "1" ]; then
    ensure_ssh_key
    prompt_ssh_key_added_to_github
  fi

  clone_repo "$use_ssh"
}

install_local_bins() {
  printf "${BLUE}Install local bins...${NORMAL}\n"
  mkdir -p "$HOME/.local/bin"
  curl -o "$HOME/.local/bin/rpatool" https://raw.githubusercontent.com/shizmob/rpatool/master/rpatool
  chmod u+x "$HOME/.local/bin/rpatool"
  cp "$PF/libs/sync-cloud" "$HOME/.local/bin/sync-cloud"
  chmod u+x "$HOME/.local/bin/sync-cloud"
}

install_packages_macos() {
  printf "${BLUE}You are on macOS!${NORMAL}\n"
  printf "${BLUE}Installing Homebrew...${NORMAL}\n"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  export PATH="/opt/homebrew/bin:$PATH"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  brew tap heroku/brew
  brew install bash coreutils diffutils ed ffmpeg findutils fish heroku \
    imagemagick git gnu-indent gnu-sed gnu-tar gnu-which gnutls grep gawk \
    gzip less nano node python rclone ruby smartmontools ssh-copy-id tldr \
    vim wget yt-dlp zsh
}

install_packages_apt() {
  printf "${BLUE}You are on Debian-based!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo apt -y update
  sudo apt -y upgrade
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
  sudo apt -y install bash coreutils diffutils ed ffmpeg findutils fish \
    imagemagick git grep gawk gzip less nano nodejs python-is-python3 rclone \
    ruby smartmontools tldr vim wget yt-dlp zsh
}

install_packages_dnf() {
  printf "${BLUE}You are on Fedora or RHEL-based!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo dnf -y update
  sudo dnf -y group install "development-tools"
  curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
  sudo dnf -y install bash coreutils diffutils ed ffmpeg findutils fish \
    ImageMagick git grep gawk gzip less nano nodejs python-is-python3 rclone \
    ruby smartmontools tldr vim wget yt-dlp zsh
}

install_packages_pacman() {
  printf "${BLUE}You are on Arch Linux!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo pacman -Syu --noconfirm
  sudo pacman -S --noconfirm base-devel bash coreutils diffutils ed ffmpeg \
    findutils fish imagemagick git grep gawk gzip less nano nodejs npm python \
    rclone ruby smartmontools tldr vim wget yt-dlp zsh
}

install_os_packages() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    install_packages_macos
  elif command -v apt-get &>/dev/null; then
    install_packages_apt
  elif command -v dnf &>/dev/null; then
    install_packages_dnf
  elif command -v pacman &>/dev/null; then
    install_packages_pacman
  fi
}

install_pyenv() {
  printf "${BLUE}Installing pyenv...${NORMAL}\n"
  if [ -d "$HOME/.pyenv" ]; then
    printf "${YELLOW}You already have pyenv cloned.${NORMAL}\n"
  else
    git clone https://github.com/pyenv/pyenv.git "$HOME/.pyenv"
    (cd "$HOME/.pyenv" && src/configure && make -C src)
  fi
  cd "$HOME"
}

install_rbenv() {
  printf "${BLUE}Installing rbenv...${NORMAL}\n"
  if [ -d "$HOME/.rbenv" ]; then
    printf "${YELLOW}You already have rbenv cloned.${NORMAL}\n"
  else
    git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
    mkdir -p "$("$HOME/.rbenv/bin/rbenv" root)"/plugins
    git clone https://github.com/rbenv/ruby-build.git "$("$HOME/.rbenv/bin/rbenv" root)/plugins/ruby-build"
  fi
}

install_bun() {
  printf "${BLUE}Installing bun...${NORMAL}\n"
  curl -fsSL https://bun.com/install | bash
}

install_yarn() {
  printf "${BLUE}Installing yarn...${NORMAL}\n"
  npm install --global yarn
}

setup_fish() {
  printf "${BLUE}Setting up fish...${NORMAL}\n"
  fish -c "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher"
  fish -c "fisher install PatrickF1/fzf.fish"
  fish -c "fisher install franciscolourenco/done"
  fish -c "fisher install decors/fish-colored-man"
  fish -c "fisher install gazorby/fish-abbreviation-tips"
  fish -c "fisher install jorgebucaran/autopair.fish"
  fish -c "fisher install IlanCosman/tide@v6"
  fish -c "fisher install jorgebucaran/nvm.fish"
  fish -c "fisher install lgathy/google-cloud-sdk-fish-completion"
  fish -c "tide configure --auto --style=Rainbow --prompt_colors='True color' --show_time=No --rainbow_prompt_separators=Angled --powerline_prompt_heads=Sharp --powerline_prompt_tails=Flat --powerline_prompt_style='Two lines, character' --prompt_connection=Dotted --powerline_right_prompt_frame=No --prompt_connection_andor_frame_color=Light --prompt_spacing=Sparse --icons='Few icons' --transient=No"
  fish -c "fish_update_completions"
  curl -LsS https://iterm2.com/shell_integration/fish -o "$HOME/.iterm2_shell_integration.fish"
  # Reduce Tide icons that conflict with IntelliJ terminals
  fish -c "set -U tide_distrobox_icon"
  fish -c "set -U tide_gcloud_icon"
  fish -c "set -U tide_kubectl_icon"
  fish -c "set -U tide_private_mode_icon"
  fish -c "set -U tide_python_icon"
  fish -c "set -U tide_terraform_icon"
  fish -c "set -U tide_right_prompt_items status cmd_duration context jobs direnv node python rustc java php ruby go"
}

# True if we're on a desktop (macOS or Linux with X/Wayland/DE). Skip nerd fonts on servers.
is_desktop_environment() {
  [[ "$OSTYPE" == "darwin"* ]] && return 0
  [[ -n "${DISPLAY:-}" ]] && return 0
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && return 0
  [[ -n "${XDG_CURRENT_DESKTOP:-}" ]] && return 0
  return 1
}

install_nerd_fonts() {
  if [ -n "${NO_FONTS:-}" ]; then
    printf "${YELLOW}Skipping nerd font install because NO_FONTS is set.${NORMAL}\n"
    return 0
  fi
  if ! is_desktop_environment; then
    printf "${YELLOW}Skipping nerd font install (server/no desktop detected).${NORMAL}\n"
    return 0
  fi
  printf "${BLUE}Installing nerd fonts...${NORMAL}\n"
  git clone https://github.com/ryanoasis/nerd-fonts.git --depth=1
  (cd nerd-fonts && ./install.sh)
  rm -rf nerd-fonts fonts
}

set_default_shell_fish() {
  FISH_PATH=$(which fish 2>/dev/null || true)
  if [ -z "$FISH_PATH" ]; then
    echo "Fish shell is not installed. Exiting."
    exit 1
  fi
  if ! grep -qxFe "$FISH_PATH" /etc/shells 2>/dev/null; then
    echo "Adding $FISH_PATH to /etc/shells"
    echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
  else
    echo "Fish shell is already listed in /etc/shells."
  fi
  echo "Changing default shell to Fish..."
  chsh -s "$FISH_PATH"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  cd "$HOME"
  prepare_and_clone_repo
  install_local_bins
  install_os_packages
  install_pyenv
  install_rbenv
  install_bun
  install_yarn
  setup_fish
  install_nerd_fonts
  set_default_shell_fish
  apply_fish_config

  printf "${BLUE}Installation finished.${NORMAL}\n"
  printf "${BLUE}Now please configure your rbenv, opam, etc.${NORMAL}\n"
  printf "${BLUE}sync-cloud is installed but it is not in crontab. Configure rclone first!${NORMAL}\n"
}

main "$@"
