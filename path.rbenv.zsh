if type "rbenv" > /dev/null; then
  eval "$(rbenv init -)";
else
  if [ ! -f $HOME/.zp-norbenv ]; then
    puts-err "rbenv is not installed. To silence, touch \$HOME/.zp-norbenv.";
  fi
fi
