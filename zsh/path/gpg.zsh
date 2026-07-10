# GPG
if [[ -o interactive ]]; then
  # Export GPG_TTY only when `tty` succeeds; leave it unset otherwise (mirrors fish).
  GPG_TTY="$(tty)" && export GPG_TTY || unset GPG_TTY
fi

:
