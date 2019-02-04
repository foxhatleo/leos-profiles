export ZSH="$HOME/.oh-my-zsh"
if [ -d $ZSH ]; then
  [ -z "$ZSH_THEME" ] && ZSH_THEME="agnoster"
  DEFAULT_USER="leoliang"
  plugins=(
    brew
    bundler
    capistrano
    coffee
    django
    gem
    git
    github
    node
    npm
    osx
    pip
    pyenv
    python
    postgres
    rails
    rake
    ruby
    sudo
    yarn
    zsh-autosuggestions
  )
  source $ZSH/oh-my-zsh.sh
else
  puts-err "Oh my zsh is not installed!"
fi
