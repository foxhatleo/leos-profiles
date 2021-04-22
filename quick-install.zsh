main() {
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

  if [ -d "$PF" ]; then
    printf "${YELLOW}You already have Leo's Profiles cloned.${NORMAL}\n"
  else
    printf "${BLUE}Cloning Leo's Profiles...${NORMAL}\n";
    command -v git >/dev/null 2>&1 || {
      echo "Error: git is not installed"
        exit 1
    };
    env git clone https://github.com/foxhatleo/leos-profiles "$PF" || {
      printf "Error: git clone of Leo's Profiles repo failed\n"
      exit 1
    }
  fi

  printf "${BLUE}Looking for an existing zsh config...${NORMAL}\n"
  if [ -f $HOME/.zshrc ] || [ -h $HOME/.zshrc ]; then
    printf "${YELLOW}Found ~/.zshrc.${NORMAL} ${GREEN}Backing up to ~/.zshrc.pre-leo${NORMAL}\n";
    mv $HOME/.zshrc $HOME/.zshrc.pre-leo;
    rm $HOME/.zshrc;
  fi
  
  echo "source $PF/start.zsh" >> $HOME/.zshrc;

  if [[ "$OSTYPE" == "darwin"* ]]; then
    printf "${BLUE}You are on macOS!${NORMAL}\n"
    printf "${BLUE}Installing home brew...${NORMAL}\n"
    /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
    printf "${BLUE}Installing packages...${NORMAL}\n"
    brew install coreutils findutils gnu-sed gradle maven node openjdk perl python rbenv ruby ruby-build ssh-copy-id thefuck vim wget yarn youtube-dl zsh
  fi

  printf "${BLUE}Installing oh my zsh...${NORMAL}\n"
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
  if [ -f $HOME/.zshrc.pre-oh-my-zsh ] || [ -h $HOME/.zshrc.pre-oh-my-zsh ]; then
    rm $HOME/.zshrc.pre-oh-my-zsh
    mv $HOME/.zshrc.pre-oh-my-zsh $HOME/.zshrc
  fi

  printf "${BLUE}Installing Powerline fonts...${NORMAL}\n"
  git clone https://github.com/powerline/fonts.git --depth=1
  cd fonts
  ./install.sh
  cd ..
  rm -rf fonts

  printf "${BLUE}Installation finished.${NORMAL}\n"
  printf "${BLUE}Now please configure your rbenv, opam, etc.${NORMAL}\n"
}

main
