# Leo's zsh Profiles
# Oh my zsh
#
# This script loads oh my zsh and configures it properly.

export ZSH="$HOME/.oh-my-zsh"
if [ -d $ZSH ]; then
  if [ -z "$OMZ_DISABLED" ]; then
    [ -z "$ZSH_THEME" ] && ZSH_THEME="agnoster"
    if [[ $(hostname) == FHL-Mac* ]]; then
      DEFAULT_USER="leoliang"
    fi
    plugins=(
      1password
      adb
      alias-finder
      aliases
      aws
      brew
      bundler
      capistrano
      command-not-found
      common-aliases
      copybuffer
      copyfile
      copypath
      cp
      debian
      dirhistory
      dnf
      docker
      docker-compose
      dotenv
      dotnet
      emoji
      encode64
      extract
      flutter
      gem
      git
      git-auto-fetch
      git-lfs
      github
      gitignore
      golang
      gpg-agent
      gradle
      heroku
      macos
      man
      node
      npm
      nvm
      perl
      pip
      postgres
      pylint
      python
      rails
      rake
      rbenv
      react-native
      ruby
      rvm
      shrink-path
      sudo
      systemd
      ubuntu
      ufw
      vagrant
      vscode
      web-search
      xcode
      yarn
      zsh-interactive-cd
    )
    unset SSH_CLIENT
    source $ZSH/oh-my-zsh.sh
  fi
else
  puts-err "Oh my zsh! is not installed!"
fi
