# TO INSTALL:
# $ /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/foxhatleo/leos-profiles/master/quick-install.sh)"

# Use colors, but only if connected to a terminal, and that terminal
# supports them.
if which tput >/dev/null 2>&1; then
    ncolors=$(tput colors)
fi
if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
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

# Only enable exit-on-error after the non-critical colorization stuff,
# which may fail on systems lacking tput or terminfo
set -e

# Prevent the cloned repository from having insecure permissions. Failing to do
# so causes compinit() calls to fail with "command not found: compdef" errors
# for users with insecure umasks (e.g., "002", allowing group writability). Note
# that this will be ignored under Cygwin by default, as Windows ACLs take
# precedence over umasks except for filesystems mounted with option "noacl".
umask g-w,o-w

if [ ! -n "$PF" ]; then
  PF=$HOME/.leos-profiles
fi

apply-fish-config() {
  printf "${BLUE}Installing fish config...${NORMAL}\n"
  # Define the path to the Fish configuration file
  FISH_CONFIG_PATH="$HOME/.config/fish/config.fish"
  # Ensure the configuration directory exists
  mkdir -p "$(dirname "$FISH_CONFIG_PATH")"
  # Set the content to the config.fish file
  cat << EOF > "$FISH_CONFIG_PATH"
if status is-interactive
    source "$HOME/.leos-profiles/start.fish"
    set fish_greeting
end
EOF
}

main() {
  if [ -d "$PF" ]; then
    printf "${YELLOW}You already have Leo's Profiles cloned.${NORMAL}\n"

  else
    printf "${BLUE}Cloning Leo's Profiles...${NORMAL}\n"
    command -v git >/dev/null 2>&1 || {
      echo "Error: git is not installed"
        exit 1
    }

    env git clone https://github.com/foxhatleo/leos-profiles "$PF" || {
      printf "Error: git clone of Leo's Profiles repo failed\n"
      exit 1
    }
  fi

  printf "${BLUE}Install local bins...${NORMAL}\n"
  mkdir -p "$HOME/.local/bin"
  curl -o "$HOME/.local/bin/rpatool" https://raw.githubusercontent.com/shizmob/rpatool/master/rpatool
  chmod u+x "$HOME/.local/bin/rpatool"
  cp "$PF/libs/sync-cloud" "$HOME/.local/bin/sync-cloud"
  chmod u+x "$HOME/.local/bin/sync-cloud"

  if [[ "$OSTYPE" == "darwin"* ]]; then
    printf "${BLUE}You are on macOS!${NORMAL}\n"
    printf "${BLUE}Installing home brew...${NORMAL}\n"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    export PATH="/opt/homebrew/bin:$PATH"
    printf "${BLUE}Installing packages...${NORMAL}\n"
    brew tap heroku/brew
    brew install bash \
      coreutils \
      diffutils \
      ed \
      ffmpeg \
      findutils \
      fish \
      heroku \
      imagemagick \
      git \
      gnu-indent \
      gnu-sed \
      gnu-tar \
      gnu-which \
      gnutls \
      grep \
      gawk \
      gzip \
      less \
      nano \
      node \
      python \
      rclone \
      ruby \
      smartmontools \
      ssh-copy-id \
      thefuck \
      tldr \
      wget \
      yarn \
      yt-dlp \
      zsh
  elif command -v apt-get &> /dev/null; then
    printf "${BLUE}You are on Debian-based!${NORMAL}\n"
    printf "${BLUE}Installing packages...${NORMAL}\n"
    sudo apt -y update
    sudo apt -y upgrade
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash - 
    sudo apt -y install \
      bash \
      coreutils \
      diffutils \
      ed \
      ffmpeg \
      findutils \
      fish \
      imagemagick \
      git \
      grep \
      gawk \
      gzip \
      less \
      nano \
      nodejs \
      python-is-python3 \
      rclone \
      ruby \
      smartmontools \
      thefuck \
      tldr \
      wget \
      yarn \
      yt-dlp \
      zsh
  elif command -v dnf &> /dev/null; then
    printf "${BLUE}You are on Fedora or RHEL-based!${NORMAL}\n"
    printf "${BLUE}Installing packages...${NORMAL}\n"
    sudo dnf -y update
    sudo dnf -y groupinstall "Development Tools" "Development Libraries"
    curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
    sudo dnf -y install \
      bash \
      coreutils \
      diffutils \
      ed \
      ffmpeg-free \
      findutils \
      fish \
      ImageMagick \
      git \
      grep \
      gawk \
      gzip \
      less \
      nano \
      nodejs \
      python-is-python3 \
      rclone \
      ruby \
      smartmontools \
      thefuck \
      tldr \
      wget \
      yarnpkg \
      yt-dlp \
      zsh
  elif command -v pacman &> /dev/null; then
    printf "${BLUE}You are on Arch Linux!${NORMAL}\n"
    printf "${BLUE}Installing packages...${NORMAL}\n"
    sudo pacman -Syu --noconfirm
    curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
    sudo pacman -S --noconfirm \
      base-devel\
      bash \
      coreutils \
      diffutils \
      ed \
      ffmpeg \
      findutils \
      fish \
      imagemagick \
      git \
      grep \
      gawk \
      gzip \
      less \
      nano \
      nodejs \
      python \
      rclone \
      ruby \
      smartmontools \
      thefuck \
      tldr \
      wget \
      yarn \
      yt-dlp \
      zsh
  fi

  printf "${BLUE}Installing pyenv...${NORMAL}\n"
  if [ -d "$HOME/.pyenv" ]; then
    printf "${YELLOW}You already have pyenv cloned.${NORMAL}\n"
  else
    git clone https://github.com/pyenv/pyenv.git $HOME/.pyenv
    cd $HOME/.pyenv && src/configure && make -C src
  fi

  printf "${BLUE}Installing rbenv...${NORMAL}\n"
  if [ -d "$HOME/.rbenv" ]; then
    printf "${YELLOW}You already have rbenv cloned.${NORMAL}\n"
  else
    git clone https://github.com/rbenv/rbenv.git $HOME/.rbenv
    mkdir -p "$($HOME/.rbenv/bin/rbenv root)"/plugins
    git clone https://github.com/rbenv/ruby-build.git "$($HOME/.rbenv/bin/rbenv root)"/plugins/ruby-build
  fi

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
  curl -L https://iterm2.com/shell_integration/fish -o ~/.iterm2_shell_integration.fish
  # Remove a few Tide icons that conflict with Intellij terminals.
  fish -c "set -U tide_distrobox_icon"
  fish -c "set -U tide_gcloud_icon"
  fish -c "set -U tide_kubectl_icon"
  fish -c "set -U tide_private_mode_icon"
  fish -c "set -U tide_python_icon"
  fish -c "set -U tide_terraform_icon"
  fish -c "set -U tide_right_prompt_items status cmd_duration context jobs direnv node python rustc java php java php ruby go"

  if [ -z "$NO_FONTS" ]; then
    printf "${BLUE}Installing nerd fonts...${NORMAL}\n"
    git clone https://github.com/ryanoasis/nerd-fonts.git --depth=1
    cd nerd-fonts
    ./install.sh
    cd ..
    rm -rf fonts
  else
    printf "${YELLOW}Skipping nerd font install because NO_FONTS is set.${NORMAL}\n"
  fi

  FISH_PATH=$(which fish)
  # Check if Fish is installed
  if [ -z "$FISH_PATH" ]; then
      echo "Fish shell is not installed. Exiting."
      exit 1
  fi
  # Check if Fish path is already in /etc/shells
  if ! grep -qxFe "$FISH_PATH" /etc/shells; then
      echo "Adding $FISH_PATH to /etc/shells"
      echo "$FISH_PATH" | sudo tee -a /etc/shells > /dev/null
  else
      echo "Fish shell is already listed in /etc/shells."
  fi
  # Change the default shell to Fish
  echo "Changing default shell to Fish..."
  chsh -s "$FISH_PATH"

  apply-fish-config

  printf "${BLUE}Installation finished.${NORMAL}\n"
  printf "${BLUE}Now please configure your rbenv, opam, etc.${NORMAL}\n"
  printf "${BLUE}sync-cloud is installed but it is not in crontab. Configure rclone first!${NORMAL}\n"
}

main
