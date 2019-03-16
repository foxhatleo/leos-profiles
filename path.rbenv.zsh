if [ -d "$HOME/.rbenv" ]; then
  export PATH="$HOME/.rbenv/bin:$PATH";
  eval "$(rbenv init -)";
else
  if [ ! -f $HOME/.zp-norbenv ]; then
    puts-err "rbenv is not installed. To silence, touch \$HOME/.zp-norbenv.";
  fi
fi
