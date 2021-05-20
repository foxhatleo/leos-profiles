if [ -d "$HOME/.opam" ]; then
  test -r $HOME/.opam/opam-init/init.zsh && . $HOME/.opam/opam-init/init.zsh > /dev/null 2> /dev/null || true
# else
#   if [ ! -f $HOME/.lp-noopam ]; then
#     puts-err "opam is not installed or you need to run opam init. To silence, touch \$HOME/.lp-noopam.";
#   fi
fi

if type "ocp-indent" > /dev/null; then
  # ocp-indent a file.
  ocpind () { ocp-indent $1 > __test.ml; rm $1; mv __test.ml $1 }
fi
