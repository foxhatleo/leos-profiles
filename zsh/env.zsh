# Leo's Profiles — terminal environment (zsh)

# Respect an existing locale/editor preference. A deterministic UTF-8 fallback
# is useful on minimal machines, but forcing LC_ALL changes every child tool.
if [[ -z ${LANG:-} ]]; then
  if locale -a 2>/dev/null | command grep -qEi '^C\.(UTF-8|utf8)$'; then
    export LANG=C.UTF-8
  elif locale -a 2>/dev/null | command grep -qEi '^en_US\.(UTF-8|utf8)$'; then
    export LANG=en_US.UTF-8
  else
    export LANG=C
  fi
fi

# Term colors. Inherited values win, as LANG and EDITOR do: a palette from
# dircolors, vivid or the user's own environment is not replaced.
export CLICOLOR=1
: ${LSCOLORS:=gxBxhxDxfxhxhxhxhxcxcx}
: ${LS_COLORS:='di=36:ln=1;31:so=37:pi=1;33:ex=35:bd=37:cd=37:su=37:sg=37:tw=32:ow=32'}
export LSCOLORS LS_COLORS

# Editor
export EDITOR="${EDITOR:-nano}"

# Which ls this is decides its colour flag: GNU (Linux, or coreutils' gnubin on
# macOS) takes --color, BSD takes -G. Also used by the fzf-tab preview below.
typeset -ga __leos_ls_color=()
if command ls --color=auto -d . >/dev/null 2>&1; then
  __leos_ls_color=(--color=auto)
elif [[ $OSTYPE == darwin* ]]; then
  __leos_ls_color=(-G)
fi

# __leos_ls_eza_compatible <ls arguments...>
# Succeeds when eza would read every argument the way ls does, so the `ls`
# wrapper below can hand the command to eza. Routing table:
#
#   eza   operands (including `-` and everything after `--`)
#   eza   short options built only from -1 -l -a -A -d -R, in any combination
#         (`-la`, `-1A`), which mean the same in eza and POSIX/GNU/BSD ls
#   eza   long options that only eza has (--git, --tree, --icons, --header,
#         --long, ...), or that GNU ls spells and means the same way (--all,
#         --almost-all, --reverse, --inode, --numeric, --group-directories-first,
#         --color=WHEN, --colour=WHEN, --width=N)
#   ls    every other short option: -t -r -S -u -c -h -n -o -g -F -p -q -i -k
#         -s -T -U -f -m -x -C -L -H and the rest are POSIX/GNU/BSD-only or
#         mean something else in eza (`-t` takes a field, `-h` is --header,
#         `-G` is the grid, `-T` the tree, `-L` the tree level, ...)
#   ls    every other long option, including those whose values or arity
#         differ (--sort, --time, --time-style, --classify, --dereference,
#         --hyperlink, a bare --color) and --help/--version, which should
#         describe ls itself
#
# So `ls -ltr` and `ls -lh` run the real ls, `ls -la` and `ls --git` run eza.
__leos_ls_eza_compatible() {
  emulate -L zsh
  local arg
  while (( $# )); do
    arg=$1
    shift
    case $arg in
      --) return 0 ;;
      --all|--almost-all|--reverse|--inode|--numeric|--group-directories-first) ;;
      --color=*|--colour=*|--width=*) ;;
      --long|--oneline|--grid|--across|--tree|--recurse|--level|--level=*) ;;
      --list-dirs|--only-dirs|--only-files|--group-directories-last) ;;
      --treat-dirs-as-files|--ignore-glob|--ignore-glob=*) ;;
      --git|--git-ignore|--git-repos|--git-repos-no-status|--no-git) ;;
      --icons|--icons=*|--no-icons|--header|--links|--binary|--bytes) ;;
      --smart-group|--modified|--accessed|--created|--changed|--blocksize) ;;
      --total-size|--octal-permissions|--extended|--flags|--mounts) ;;
      --no-permissions|--no-filesize|--no-user|--no-time|--no-quotes) ;;
      --absolute|--absolute=*|--follow-symlinks|--show-symlinks|--no-symlinks) ;;
      --color-scale|--color-scale=*|--colour-scale|--colour-scale=*) ;;
      --color-scale-mode=*|--colour-scale-mode=*) ;;
      --*) return 1 ;;
      -) ;;
      -*) [[ ${arg#-} != *[^1laAdR]* ]] || return 1 ;;
    esac
  done
  return 0
}

# Colourful command wrappers. Set LEOS_DISABLE_ALIASES=1 for scripts, recovery
# shells, or users who prefer the underlying commands unchanged; to drop one of
# them on a single machine, `unfunction ls` (or cat) in local/private.zsh.
#
# `function name { }` rather than `name() { }`: a system zshrc that already
# aliases ls would otherwise expand that alias inside the definition.
if [[ ${LEOS_DISABLE_ALIASES:-0} != 1 ]]; then
  (( ! ${+aliases[ls]} )) || unalias ls
  (( ! ${+aliases[cat]} )) || unalias cat
  if command -v eza >/dev/null 2>&1; then
    function ls {
      if __leos_ls_eza_compatible "$@"; then
        command eza --color=auto --group-directories-first "$@"
      else
        command ls "${__leos_ls_color[@]}" "$@"
      fi
    }
  elif (( $#__leos_ls_color )); then
    function ls { command ls "${__leos_ls_color[@]}" "$@"; }
  fi
  if command -v bat >/dev/null 2>&1; then
    # bat only where it is a drop-in: a terminal reading plain file operands.
    # Any option (`cat -v`, `cat -n`, `cat --`) and any pipe or redirection
    # gets the real cat, so scripts and muscle memory keep POSIX behaviour.
    function cat {
      if [[ -t 1 ]] && (( ! ${argv[(I)-?*]} )); then
        command bat --style=plain --paging=never "$@"
      else
        command cat "$@"
      fi
    }
    # Colorized man pages from the same pager. `col -bx` strips the overstrike
    # sequences groff emits, which bat would otherwise render literally.
    # MANROFFOPT keeps groff from re-adding those sequences. A pager the user
    # already chose wins.
    if [[ -z ${MANPAGER:-} ]]; then
      export MANPAGER="sh -c 'col -bx | bat -l man -p'"
      : ${MANROFFOPT:=-c}
      export MANROFFOPT
    fi
  fi
  if command grep --color=auto '' /dev/null >/dev/null 2>&1 || [[ $? == 1 ]]; then
    alias grep='grep --color=auto'
    # egrep/fgrep are obsolescent: GNU grep 3.8+ warns on every call.
    alias fgrep='grep -F --color=auto'
    alias egrep='grep -E --color=auto'
  fi
fi

# History — shared, dedup, trimmed
HISTFILE=$HOME/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
# SHARE_HISTORY already implies incremental appending (plus import from other
# shells), and the manual advises picking one of SHARE_HISTORY /
# INC_APPEND_HISTORY / INC_APPEND_HISTORY_TIME rather than combining them.
# HIST_FCNTL_LOCK uses the kernel's locking for the shared file, which is more
# reliable than zsh's own lock files when many shells write at once.
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY EXTENDED_HISTORY HIST_FCNTL_LOCK

# Interactive behavior
setopt AUTO_CD EXTENDED_GLOB INTERACTIVE_COMMENTS NO_BEEP NO_CASE_GLOB NUMERIC_GLOB_SORT
# EXTENDED_GLOB makes `^` a negation operator, so `git reset HEAD^` fails with
# "no matches found". Keep the rest of extended globbing and drop only `^`
# (`~` still excludes). Functions running under `emulate -L zsh`, which
# includes the completion system and the plugins, get every pattern back.
disable -p '^'

# Completion styling (compinit itself runs in interactive.zsh)
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
# `menu no`, not `menu select`: fzf-tab provides the menu UI and its README asks
# for this so it can capture the unambiguous prefix before opening the finder.
zstyle ':completion:*' menu no
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}        # colorize menu; also picked up by fzf-tab
zstyle ':completion:*:descriptions' format '[%d]'            # fzf-tab uses these as group headers
# Directory preview in fzf-tab's finder, matching the eza/bat aesthetic above.
# Without eza (it is not packaged on every distribution) the real ls draws it;
# BSD ls only colours a terminal unless CLICOLOR_FORCE is set.
if command -v eza >/dev/null 2>&1; then
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
elif [[ ${__leos_ls_color[1]-} == --color=auto ]]; then
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'command ls -1 --color=always $realpath'
elif [[ ${__leos_ls_color[1]-} == -G ]]; then
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'CLICOLOR_FORCE=1 command ls -1 -G $realpath'
else
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'command ls -1 $realpath'
fi
zstyle ':completion:*' rehash true                           # find newly-installed executables without a restart
zstyle ':completion:*' accept-exact '*(N)'
# The completion cache lives beside the init cache in the same validated,
# private root. If that storage is unsafe, completion caching stays off rather
# than creating directories with the caller's umask.
if __leos_cache_dir; then
  _leos_zcompcache=${REPLY:h}/zcompcache
  if [[ ! -e $_leos_zcompcache ]]; then
    mkdir -m 700 -- "$_leos_zcompcache" 2>/dev/null
  fi
  if [[ -d $_leos_zcompcache && ! -L $_leos_zcompcache && -O $_leos_zcompcache ]]; then
    zstyle ':completion:*' use-cache on
    zstyle ':completion:*' cache-path "$_leos_zcompcache"
  fi
  unset _leos_zcompcache
fi

# iTerm2 integration is deliberately opt-in: it is external shell code and is
# no longer downloaded by the installer. Install it through iTerm2, then set
# LEOS_ENABLE_ITERM2_INTEGRATION=1 if you want this profile to source it.
[[ ${LEOS_ENABLE_ITERM2_INTEGRATION:-0} == 1 && -r $HOME/.iterm2_shell_integration.zsh ]] && \
  source "$HOME/.iterm2_shell_integration.zsh"

:
