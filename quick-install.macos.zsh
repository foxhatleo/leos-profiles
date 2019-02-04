if [[ "$OSTYPE" == "darwin"* ]]; then
  /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
  brew install ack coreutils dark-mode findutils git git-lfs  gnu-sed moreutils node opam openssl postgresql python python3 rbenv rename ruby ruby-build sqlite ssh-copy-id thefuck trash vim wget yarn youtube-dl zsh
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
  rm -rf ~/.zshrc*
  echo "source $HOME/.zsh_profiles/start.zsh" >> ~/.zshrc
fi
