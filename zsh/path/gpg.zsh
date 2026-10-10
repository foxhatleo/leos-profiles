# GPG
if [[ -o interactive ]]; then
  # $TTY is zsh's own record of the terminal, so this needs no `tty` fork.
  # Without a terminal, drop an inherited GPG_TTY: it names another session's
  # terminal, and a curses pinentry would prompt there.
  if [[ -n ${TTY:-} ]]; then
    export GPG_TTY=$TTY
  else
    unset GPG_TTY
  fi
fi

:
