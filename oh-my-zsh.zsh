export ZSH="$HOME/.oh-my-zsh"
if [ -d $ZSH ]; then
  if [ -z "$OMZ_DISABLED" ]; then
    [ -z "$ZSH_THEME" ] && ZSH_THEME="agnoster"
    DEFAULT_USER="leoliang"
    plugins=(
      brew
      bundler
      capistrano
      dnf
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
      vscode
      yarn
      zsh-syntax-highlighting
      zsh-autosuggestions
      zsh-completions
    )
    source $ZSH/oh-my-zsh.sh
  fi
else
  puts-err "Oh my zsh is not installed!"
fi
