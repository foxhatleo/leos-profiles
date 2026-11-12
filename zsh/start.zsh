# Leo's Profiles — starting point (zsh)
# Defines helper functions, then loads the PATH/environment layer
# (zsh/entries.zsh), local/private.zsh, the interactive layer
# (zsh/interactive.zsh) and local/private-interactive.zsh, in that order.

# Load once per shell. A machine set up by the pre-installer instructions can
# carry both a legacy unmarked loader and the managed block in ~/.zshrc (the
# installer migrates that, but only on its next apply); a second pass would
# double startup time and re-run every init. Not exported, so a nested shell
# still loads its own copy.
(( ${+__leos_profile_loaded} )) && return 0
typeset -g __leos_profile_loaded=1

# A root shell that kept the invoking user's HOME (`sudo -s`, `sudo -E`) must
# not run the profile: compinit, the init cache and history would leave
# root-owned files in that HOME and break the user's own later shells.
if (( EUID == 0 )) && [[ ! -O $HOME ]]; then
  return 0
fi

# Helpers. The profile's own code calls only these private __leos_* names; the
# short public names are defined further down, for the override files only.
__leos_puts()     { print -Pn "%B%F{blue}===>%f%b "; print -r -- "$*"; }
__leos_puts_err() { print -Pn "%B%F{red}===>%f%b " >&2; print -r -- "$*" >&2; }

# Prepend $1 to PATH (dedup, move-to-front) if it is a real dir.
# __leos_add_path <dir> [required]  — with "required", warn + return 1 when missing.
__leos_add_path() {
  local dir=$1 mode=${2:-}
  if [[ -d $dir ]]; then
    # (b) escapes pattern metacharacters in $dir. Belt and braces rather than a
    # live bug: zsh only reinterprets an expanded value as a pattern under
    # GLOB_SUBST, which is off by default and never set here — verified that
    # without it a dir named `a[1]` does not evict `a1`, and with it the plain
    # form wipes the array. This keeps the dedup correct either way.
    path=("$dir" ${path:#${(b)dir}})
    typeset -gU path
    return 0
  elif [[ $mode == required ]]; then
    __leos_puts_err "$dir is not found."
    return 1
  fi
  return 0
}

# REPLY: the brew executable, from PATH or a standard prefix. Returned in REPLY
# rather than printed, so the caller needs no command substitution: that forked
# a subshell on every startup, even on machines without Homebrew.
__leos_brew_bin() {
  if whence -p brew >/dev/null; then REPLY=$commands[brew]; return 0; fi
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew "$HOME/.linuxbrew/bin/brew" /home/linuxbrew/.linuxbrew/bin/brew; do
    if [[ -x $b && ! -d $b ]]; then REPLY=$b; return 0; fi
  done
  return 1
}

__leos_brew_prefix() {
  __leos_brew_bin || return 1
  "$REPLY" --prefix
}

# Shell-internal: not exported into child environments. Prefer an explicit
# override, otherwise derive the root from this sourced file. This keeps
# ~/.leos-profiles as the installer default without requiring it.
typeset -g __leos_start_file="${(%):-%N}"
typeset -g LEOS_PROFILES="${LEOS_PROFILES_HOME:-${__leos_start_file:A:h:h}}"
typeset -g LEOS_PROFILES_ZSH=$LEOS_PROFILES/zsh

# Source zsh/<name>.zsh; warn unless mode is "optional".
__leos_entry() {
  local name=$1 mode=${2:-}
  if [[ -e $LEOS_PROFILES_ZSH/$name.zsh ]]; then
    source "$LEOS_PROFILES_ZSH/$name.zsh"
  elif [[ $mode != optional ]]; then
    __leos_puts_err "$name is not found. Check $LEOS_PROFILES_ZSH/entries.zsh."
  fi
}

# The short public names exist only while the profile loads, so
# local/private.zsh and local/private-interactive.zsh can still call them.
# __leos_drop_public_helpers removes them at the end of this file, so generic
# names like `puts` and `entry` do not leak into every shell. A function
# that needs one at run time should call the __leos_* name, or plain `print`.
puts()     { __leos_puts "$@"; }
puts-err() { __leos_puts_err "$@"; }
add-path() { __leos_add_path "$@"; }
entry()    { __leos_entry "$@"; }
typeset -gA __leos_public_helpers=(
  puts "$functions[puts]" puts-err "$functions[puts-err]"
  add-path "$functions[add-path]" entry "$functions[entry]"
)

# Remove the public names again, except one an override file redefined: that
# definition is the user's to keep.
__leos_drop_public_helpers() {
  local name
  for name in ${(k)__leos_public_helpers}; do
    if [[ ${functions[$name]-} == "$__leos_public_helpers[$name]" ]]; then
      unfunction -- "$name"
    fi
  done
  unset __leos_public_helpers
  unfunction __leos_drop_public_helpers
}

# Shared init-cache helpers, loaded before entries.zsh so every path/ entry can
# use them. Kept in their own file so tests can exercise them in isolation.
__leos_entry cache

# PATH, environment, aliases and public commands.
__leos_entry entries

# __leos_private_mode_warn <file>
# Local override files routinely hold API keys, and a group-traversable home
# (the macOS default, where every local account is in staff) makes a permissive
# mode a real exposure. Warn instead of rewriting it: the mode is the owner's
# call, and the installer already enforces 600 on every apply.
#
# A function so EXTENDED_GLOB — needed for the (#q...) qualifiers — stays local,
# and the `source` that follows still sees the ambient option set that a
# machine-specific override may depend on.
__leos_private_mode_warn() {
  emulate -L zsh
  setopt extended_glob
  local f=$1
  # `-f` follows symlinks: a bare `f:...:` qualifier lstats, and a symlink's
  # own mode is 0777, so a link to a correctly-locked file would warn forever
  # with no way to silence it.
  [[ -n $f(#qN-f:g+r:) || -n $f(#qN-f:o+r:) ]] || return 0
  puts-err "$f is readable beyond its owner and usually holds secrets. Fix with: chmod 600 ${(q)f}"
}

# Private overrides are sourced HERE, at the top level of this file, rather
# than through `entry`: anything sourced inside a function scopes a bare
# `typeset`, `local` or `typeset -A` declaration to that function, so an
# override's declarations would silently vanish when it returned.
#
# local/private.zsh loads after the public command layer so a machine-specific
# override can intentionally win. compinit has not run yet, so `compdef` does
# not exist here: completion and ZLE widget overrides belong in
# local/private-interactive.zsh, which loads last of all below.
if [[ -r $LEOS_PROFILES/local/private.zsh ]]; then
  __leos_private_mode_warn "$LEOS_PROFILES/local/private.zsh"
  source "$LEOS_PROFILES/local/private.zsh"
fi

# env.zsh defined the command wrappers before private.zsh could set
# LEOS_DISABLE_ALIASES, so honour a value set there now.
if [[ ${LEOS_DISABLE_ALIASES:-0} == 1 ]] && (( $+functions[__leos_drop_wrappers] )); then
  __leos_drop_wrappers
fi
(( ! $+functions[__leos_drop_wrappers] )) || unfunction __leos_drop_wrappers
unset __leos_wrappers

# Dumb terminals (Emacs TRAMP, `M-x shell`, some IDE runners) get the PATH and
# environment above but no line editor, plugins or themed prompt: those emit
# escape sequences such a terminal shows literally, and TRAMP waits for a
# plain prompt it can recognise.
if [[ ${TERM:-} == dumb ]]; then
  unsetopt zle
  PS1='$ '
  __leos_drop_public_helpers
  return 0
fi

# Plugins, completion and the prompt.
__leos_entry interactive

# Machine-local interactive overrides, last of all: the counterpart to
# local/private.zsh for anything that needs `compdef`, a ZLE widget, or the final
# word over the plugin stack — none of which exist yet when private.zsh loads.
if [[ -r $LEOS_PROFILES/local/private-interactive.zsh ]]; then
  __leos_private_mode_warn "$LEOS_PROFILES/local/private-interactive.zsh"
  source "$LEOS_PROFILES/local/private-interactive.zsh"
fi

# The public helper names were for the override files above only.
__leos_drop_public_helpers

# Convention: every profile zsh file ends with a bare `:` so `source`
# reports success when the file's last real command is a guard that
# legitimately failed (e.g. `command -v x && eval ...`). A mid-file error
# under err_return still aborts before reaching it.
:
