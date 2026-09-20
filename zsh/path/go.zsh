# Go (GOPATH may contain multiple colon-separated workspaces).
if (( $+commands[go] )); then
  # `go env GOPATH` boots the whole Go toolchain (~20ms per shell) just to
  # report a value that is almost always the documented default. Resolve it the
  # cheap way instead, following go's own precedence: $GOPATH, then go's env
  # file, then ~/go.
  _leos_gopath=${GOPATH:-}
  if [[ -z $_leos_gopath ]]; then
    if [[ $OSTYPE == darwin* ]]; then
      _leos_go_envfile=${GOENV:-$HOME/Library/Application Support/go/env}
    else
      _leos_go_envfile=${GOENV:-${XDG_CONFIG_HOME:-$HOME/.config}/go/env}
    fi
    if [[ -r $_leos_go_envfile ]]; then
      # $(<file) is read in-process by zsh, so this stays fork-free. Take the
      # last assignment, which is the one `go env -w` leaves in effect.
      _leos_go_lines=(${(M)${(f)"$(<$_leos_go_envfile)"}:#GOPATH=*})
      if (( $#_leos_go_lines )); then
        _leos_gopath=${_leos_go_lines[-1]#GOPATH=}
      fi
    fi
  fi
  : ${_leos_gopath:=$HOME/go}
  for _leos_go_workspace in ${(s.:.)_leos_gopath}; do
    add-path "$_leos_go_workspace/bin"
  done
  unset _leos_gopath _leos_go_workspace _leos_go_envfile _leos_go_lines
fi

:
