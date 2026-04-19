#!/usr/bin/env bash
#
# Leo's Profiles — Quick install implementation
#
# Public entrypoint:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"
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
: "${QUICK_INSTALL_STATE_FILE:=$PF/quick-install.state}"
# Set USE_HTTPS=1 to skip SSH and clone via HTTPS (e.g. in CI or if you prefer)

STEP_IDS=(
  prepare_and_clone_repo
  install_local_bins
  install_os_packages
  install_pyenv
  install_rbenv
  install_bun
  install_yarn
  setup_nvm_default_node
  setup_fish
  install_nerd_fonts
  apply_fish_config
  set_default_shell_fish
)

STATE_ENABLED_STEPS=""
STATE_COMPLETED_STEPS=""
STATE_SKIPPED_STEPS=""
STATE_CURRENT_STEP=""
STATE_LAST_FAILED_STEP=""
STATE_LAST_STATUS=""
STATE_RUN_STARTED_AT=""
STATE_UPDATED_AT=""
INSTALLED_NVM_VERSION=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

contains_word() {
  local needle="$1"
  shift
  local item
  for item in $*; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

append_unique_word() {
  local var_name="$1"
  local value="$2"
  local current
  eval "current=\${$var_name}"
  if contains_word "$value" "$current"; then
    return 0
  fi
  if [ -n "$current" ]; then
    eval "$var_name=\"\$current $value\""
  else
    eval "$var_name=\"$value\""
  fi
}

remove_word() {
  local var_name="$1"
  local value="$2"
  local current updated item
  eval "current=\${$var_name}"
  updated=""
  for item in $current; do
    if [ "$item" = "$value" ]; then
      continue
    fi
    if [ -n "$updated" ]; then
      updated="$updated $item"
    else
      updated="$item"
    fi
  done
  eval "$var_name=\"\$updated\""
}

reset_state_tracking() {
  STATE_ENABLED_STEPS=""
  STATE_COMPLETED_STEPS=""
  STATE_SKIPPED_STEPS=""
  STATE_CURRENT_STEP=""
  STATE_LAST_FAILED_STEP=""
  STATE_LAST_STATUS=""
  STATE_RUN_STARTED_AT=""
  STATE_UPDATED_AT=""
}

state_persistence_available() {
  [ -d "$PF" ]
}

save_state_file() {
  if ! state_persistence_available; then
    return 0
  fi
  STATE_UPDATED_AT=$(date +%s)
  cat > "$QUICK_INSTALL_STATE_FILE" <<EOF
STATE_ENABLED_STEPS="$STATE_ENABLED_STEPS"
STATE_COMPLETED_STEPS="$STATE_COMPLETED_STEPS"
STATE_SKIPPED_STEPS="$STATE_SKIPPED_STEPS"
STATE_CURRENT_STEP="$STATE_CURRENT_STEP"
STATE_LAST_FAILED_STEP="$STATE_LAST_FAILED_STEP"
STATE_LAST_STATUS="$STATE_LAST_STATUS"
STATE_RUN_STARTED_AT="$STATE_RUN_STARTED_AT"
STATE_UPDATED_AT="$STATE_UPDATED_AT"
EOF
}

load_state_file() {
  if state_persistence_available && [ -f "$QUICK_INSTALL_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$QUICK_INSTALL_STATE_FILE"
    return 0
  fi
  return 1
}

clear_state_file() {
  if state_persistence_available; then
    rm -f "$QUICK_INSTALL_STATE_FILE"
  fi
}

record_interrupted_run() {
  if [ -n "$STATE_CURRENT_STEP" ]; then
    STATE_LAST_FAILED_STEP="$STATE_CURRENT_STEP"
    STATE_CURRENT_STEP=""
    STATE_LAST_STATUS="failed"
    save_state_file
  fi
  exit 130
}

step_label() {
  case "$1" in
    prepare_and_clone_repo) echo "Prepare and clone repo" ;;
    install_local_bins) echo "Install local bins" ;;
    install_os_packages) echo "Install OS packages" ;;
    install_pyenv) echo "Install pyenv" ;;
    install_rbenv) echo "Install rbenv" ;;
    install_bun) echo "Install bun" ;;
    install_yarn) echo "Install yarn" ;;
    setup_fish) echo "Set up fish plugins and prompt" ;;
    setup_nvm_default_node) echo "Install latest Node.js LTS with nvm" ;;
    install_nerd_fonts) echo "Install nerd fonts" ;;
    set_default_shell_fish) echo "Set default shell to fish" ;;
    apply_fish_config) echo "Write fish config" ;;
    *) echo "$1" ;;
  esac
}

step_dependencies() {
  case "$1" in
    install_local_bins) echo "prepare_and_clone_repo" ;;
    install_yarn) echo "install_os_packages" ;;
    setup_fish) echo "install_os_packages" ;;
    setup_nvm_default_node) echo "install_os_packages" ;;
    set_default_shell_fish) echo "install_os_packages" ;;
    apply_fish_config) echo "prepare_and_clone_repo" ;;
  esac
}

step_default_enabled() {
  case "$1" in
    install_nerd_fonts)
      if [ -n "${NO_FONTS:-}" ]; then
        return 1
      fi
      is_desktop_environment
      return $?
      ;;
    *)
      return 0
      ;;
  esac
}

prompt_yes_no() {
  local message="$1"
  local default_answer="$2"
  local prompt answer

  if ! [ -t 0 ]; then
    [ "$default_answer" = "yes" ]
    return $?
  fi

  if [ "$default_answer" = "yes" ]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi

  while true; do
    printf "%s %s: " "$message" "$prompt"
    if ! read -r answer; then
      answer=""
    fi
    case "$answer" in
      "")
        [ "$default_answer" = "yes" ]
        return $?
        ;;
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
    esac
  done
}

configure_steps_interactively() {
  local step_id default answer

  printf "${BOLD}Select quick-install steps.${NORMAL}\n"
  printf "${BLUE}Press Enter to accept the default for each step.${NORMAL}\n"

  STATE_ENABLED_STEPS=""
  STATE_SKIPPED_STEPS=""

  for step_id in "${STEP_IDS[@]}"; do
    if step_default_enabled "$step_id"; then
      default="yes"
    else
      default="no"
    fi

    if prompt_yes_no "Run step: $(step_label "$step_id")" "$default"; then
      append_unique_word STATE_ENABLED_STEPS "$step_id"
    else
      append_unique_word STATE_SKIPPED_STEPS "$step_id"
    fi
  done
}

ensure_step_dependencies_selected() {
  local changed=1 step_id dep
  while [ "$changed" -eq 1 ]; do
    changed=0
    for step_id in $STATE_ENABLED_STEPS; do
      for dep in $(step_dependencies "$step_id"); do
        if contains_word "$dep" "$STATE_ENABLED_STEPS"; then
          continue
        fi
        append_unique_word STATE_ENABLED_STEPS "$dep"
        remove_word STATE_SKIPPED_STEPS "$dep"
        printf "${YELLOW}Enabling prerequisite step: %s${NORMAL}\n" "$(step_label "$dep")"
        changed=1
      done
    done
  done
}

start_new_run() {
  reset_state_tracking
  STATE_RUN_STARTED_AT=$(date +%s)
  INSTALLED_NVM_VERSION=""
  if [ -t 0 ]; then
    configure_steps_interactively
    ensure_step_dependencies_selected
  else
    local step_id
    for step_id in "${STEP_IDS[@]}"; do
      if step_default_enabled "$step_id"; then
        append_unique_word STATE_ENABLED_STEPS "$step_id"
      else
        append_unique_word STATE_SKIPPED_STEPS "$step_id"
      fi
    done
  fi
  STATE_LAST_STATUS="pending"
  save_state_file
}

prepare_run_plan() {
  if load_state_file && [ "$STATE_LAST_STATUS" = "running" ] && [ -n "$STATE_CURRENT_STEP" ]; then
    STATE_LAST_FAILED_STEP="$STATE_CURRENT_STEP"
    STATE_CURRENT_STEP=""
    STATE_LAST_STATUS="failed"
    save_state_file
  fi

  if load_state_file && [ "$STATE_LAST_STATUS" = "failed" ] && [ -n "$STATE_LAST_FAILED_STEP" ]; then
    printf "${YELLOW}A previous quick-install run failed at: %s${NORMAL}\n" "$(step_label "$STATE_LAST_FAILED_STEP")"
    if prompt_yes_no "Continue from that failed step" "yes"; then
      return 0
    fi
    printf "${BLUE}Starting a fresh quick-install run.${NORMAL}\n"
  fi

  start_new_run
}

mark_step_skipped() {
  local step_id="$1"
  append_unique_word STATE_SKIPPED_STEPS "$step_id"
  remove_word STATE_COMPLETED_STEPS "$step_id"
}

run_step() {
  local step_id="$1"

  if contains_word "$step_id" "$STATE_COMPLETED_STEPS"; then
    printf "${GREEN}Skipping completed step: %s${NORMAL}\n" "$(step_label "$step_id")"
    return 0
  fi

  if ! contains_word "$step_id" "$STATE_ENABLED_STEPS"; then
    printf "${YELLOW}Skipping disabled step: %s${NORMAL}\n" "$(step_label "$step_id")"
    mark_step_skipped "$step_id"
    save_state_file
    return 0
  fi

  printf "${BOLD}Running step: %s${NORMAL}\n" "$(step_label "$step_id")"
  STATE_CURRENT_STEP="$step_id"
  STATE_LAST_STATUS="running"
  save_state_file

  if "$step_id"; then
    append_unique_word STATE_COMPLETED_STEPS "$step_id"
    remove_word STATE_SKIPPED_STEPS "$step_id"
    STATE_CURRENT_STEP=""
    STATE_LAST_FAILED_STEP=""
    STATE_LAST_STATUS="running"
    save_state_file
    return 0
  fi

  STATE_CURRENT_STEP=""
  STATE_LAST_FAILED_STEP="$step_id"
  STATE_LAST_STATUS="failed"
  save_state_file
  printf "${RED}Step failed: %s${NORMAL}\n" "$(step_label "$step_id")"
  printf "${YELLOW}Re-run quick-install to continue from this point.${NORMAL}\n"
  return 1
}

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

find_brew_bin() {
  local brew_bin

  if brew_bin=$(command -v brew 2>/dev/null); then
    printf '%s\n' "$brew_bin"
    return 0
  fi

  for brew_bin in \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew \
    "$HOME/.linuxbrew/bin/brew" \
    /home/linuxbrew/.linuxbrew/bin/brew; do
    if [ -x "$brew_bin" ]; then
      printf '%s\n' "$brew_bin"
      return 0
    fi
  done

  return 1
}

setup_brew_env() {
  local brew_bin

  brew_bin=$(find_brew_bin) || {
    echo "Error: Homebrew was not found after installation"
    exit 1
  }

  eval "$("$brew_bin" shellenv)"
}

apply_fish_config() {
  printf "${BLUE}Installing fish config...${NORMAL}\n"
  FISH_CONFIG_PATH="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$FISH_CONFIG_PATH")"
  cat << EOF > "$FISH_CONFIG_PATH"
if status is-interactive
    source "$HOME/.leos-profiles/fish/start.fish"
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
}

install_packages_macos() {
  printf "${BLUE}You are on macOS!${NORMAL}\n"
  printf "${BLUE}Installing Homebrew...${NORMAL}\n"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  setup_brew_env
  printf "${BLUE}Installing packages...${NORMAL}\n"
  brew tap heroku/brew
  brew install bash coreutils diffutils ed ffmpeg findutils fish heroku \
    imagemagick git gnu-indent gnu-sed gnu-tar gnu-which gnutls grep gawk \
    gzip less nano node python rclone ruby smartmontools ssh-copy-id \
    vim wget yt-dlp zsh
}

install_packages_apt() {
  printf "${BLUE}You are on Debian-based!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo apt -y update
  sudo apt -y upgrade
  sudo apt -y install bash build-essential clang coreutils diffutils ed ffmpeg \
    findutils fish imagemagick gcc git grep gawk gzip less nano nodejs \
    python-is-python3 rclone ruby smartmontools vim wget yt-dlp zsh
}

install_packages_fedora() {
  printf "${BLUE}You are on Fedora!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo dnf -y update
  sudo dnf -y group install "development-tools"
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    sudo dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
  fi
  sudo dnf -y install bash coreutils diffutils ed findutils fish \
    ImageMagick git grep gawk gzip less nano nodejs python-is-python3 rclone \
    ruby smartmontools vim wget yt-dlp zsh
  if rpm -q ffmpeg-free >/dev/null 2>&1; then
    sudo dnf -y swap ffmpeg-free ffmpeg --allowerasing
  else
    sudo dnf -y install ffmpeg
  fi
}

install_packages_pacman() {
  printf "${BLUE}You are on Arch Linux!${NORMAL}\n"
  printf "${BLUE}Installing packages...${NORMAL}\n"
  sudo pacman -Syu --noconfirm
  sudo pacman -S --noconfirm base-devel bash coreutils diffutils ed ffmpeg \
    findutils fish imagemagick git grep gawk gzip less nano nodejs npm python \
    rclone ruby smartmontools vim wget yt-dlp zsh
}

is_fedora() {
  [ -r /etc/os-release ] || return 1
  grep -Eq '^ID="?fedora"?$' /etc/os-release
}

install_os_packages() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    install_packages_macos
  elif command -v apt-get &>/dev/null; then
    install_packages_apt
  elif command -v dnf &>/dev/null && is_fedora; then
    install_packages_fedora
  elif command -v pacman &>/dev/null; then
    install_packages_pacman
  else
    printf "${RED}Unsupported OS for quick-install package bootstrap.${NORMAL}\n"
    exit 1
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

ensure_fisher_and_nvm_fish() {
  fish -c "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher"
  fish -c "fisher install jorgebucaran/nvm.fish"
}

setup_fish() {
  printf "${BLUE}Setting up fish...${NORMAL}\n"
  ensure_fisher_and_nvm_fish
  fish -c "fisher install PatrickF1/fzf.fish"
  fish -c "fisher install franciscolourenco/done"
  fish -c "fisher install decors/fish-colored-man"
  fish -c "fisher install gazorby/fish-abbreviation-tips"
  fish -c "fisher install jorgebucaran/autopair.fish"
  fish -c "fisher install IlanCosman/tide@v6"
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
  fish -c "set -U fish_key_bindings fish_default_key_bindings"

  if [ -n "$INSTALLED_NVM_VERSION" ]; then
    fish -c "set -U nvm_default_version $INSTALLED_NVM_VERSION"
  else
    fish -c "if set -l current_version (nvm current 2>/dev/null); and test -n \"$current_version\"; and test \"$current_version\" != \"none\"; set -U nvm_default_version $current_version; else; set -Ue nvm_default_version; end"
  fi
}

setup_nvm_default_node() {
  printf "${BLUE}Installing latest Node.js LTS with nvm...${NORMAL}\n"
  ensure_fisher_and_nvm_fish
  INSTALLED_NVM_VERSION=$(fish -c 'nvm install lts >/dev/null; set -l current_version (nvm current 2>/dev/null); if test -n "$current_version"; and test "$current_version" != "none"; printf "%s\n" "$current_version"; end' | tr -d '[:space:]')
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
  local step_id

  cd "$HOME"
  prepare_run_plan

  for step_id in "${STEP_IDS[@]}"; do
    run_step "$step_id"
  done

  clear_state_file

  printf "${BLUE}Installation finished.${NORMAL}\n"
  printf "${BLUE}Now please configure your rbenv, opam, etc.${NORMAL}\n"
}

trap record_interrupted_run INT TERM

main "$@"
