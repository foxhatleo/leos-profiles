if [ -d "$HOME/.opam" ]; then
  test -r $HOME/.opam/opam-init/init.zsh && . $HOME/.opam/opam-init/init.zsh > /dev/null 2> /dev/null || true
else
  if [ ! -f $HOME/.zp-noopam ]; then
    puts-err "opam is not installed. To silence, touch \$HOME/.zp-noopam.";
  fi
fi
