export ZSH="$HOME/.oh-my-zsh"
if [ -d $ZSH ]; then
  if [ -z "$OMZ_DISABLED" ]; then
    [ -z "$ZSH_THEME" ] && ZSH_THEME="agnoster"
    DEFAULT_USER="leoliang"
    plugins=(
      1password
      brew
      bundler
      capistrano
      command-not-found
      common-aliases
      debian
      dnf
      dotenv
      gem
      git
      github
      gradle
      heroku
      node
      npm
      macos
      pip
      pyenv
      python
      postgres
      rails
      rake
      rbenv
      ruby
      sudo
      systemd
      ubuntu
      ufw
      vscode
      yarn
      zsh-syntax-highlighting
      zsh-autosuggestions
      zsh-completions
    )
    unset SSH_CLIENT
    source $ZSH/oh-my-zsh.sh
  fi
else
  puts-err "Oh my zsh is not installed!"
fi
