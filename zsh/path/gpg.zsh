# GPG
if [[ -o interactive ]]; then
  # $TTY is zsh's own record of the terminal, so this needs no `tty` fork.
  # Leave GPG_TTY unset when there is no terminal (mirrors fish).
  if [[ -n ${TTY:-} ]]; then
    export GPG_TTY=$TTY
  else
    unset GPG_TTY
  fi
fi

:
