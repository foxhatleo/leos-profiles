# Leo's Profiles — user commands (zsh)

__rmdsstore() {
  if [[ $(uname -s) != Darwin ]]; then
    puts-err "rmdsstore only supports the macOS data-volume layout."
    return 1
  fi
  if (( $# == 0 )); then
    puts-err "Usage: rmdsstore [--dry-run] <root> [...]."
    return 2
  fi
  sudo python3 "$LEOS_PROFILES/util/rmdsstore.py" "$@" || return $?
  puts "Finished scanning $*"
}

# Remove all .DS_Store and sibling metadata files under standard macOS roots.
rmdsstore() {
  local root status=0
  local -a options
  if [[ ${1:-} == --dry-run ]]; then
    options=(--dry-run)
    shift
  fi
  if (( $# > 0 )); then
    __rmdsstore "${options[@]}" "$@"
    return $?
  fi
  for root in /System/Volumes/Data/Users /System/Volumes/Data/Library \
              /System/Volumes/Data/opt /System/Volumes/Data/usr /System/Volumes/Data/private; do
    if [[ -d $root ]]; then
      __rmdsstore "${options[@]}" "$root" || status=1
    else
      puts-err "Skipping missing macOS data root: $root"
      status=1
    fi
  done
  return $status
}

# Clear history files.
clear-history() {
  local f status=0
  for f in $HOME/.*history(N) $HOME/.zcompdump*(N) \
           $HOME/.oracle_jre_usage(N) $HOME/.*hsts(N); do
    rm -rf "$f" || status=1
  done
  : > "$HISTFILE" 2>/dev/null || status=1
  fc -p "$HISTFILE" 2>/dev/null || status=1
  if [[ -d $HOME/.lldb ]]; then
    for f in $HOME/.lldb/*history(N); do rm -rf "$f" || status=1; done
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -Command "Remove-Item (Get-PSReadlineOption).HistorySavePath" || status=1
  fi
  return $status
}

# Show/hide hidden files in Finder (macOS).
__hidden-set() {
  if [[ $(uname -s) == Darwin ]]; then
    defaults write com.apple.Finder AppleShowAllFiles "$1" || return 1
    killall Finder >/dev/null 2>&1 || true
  else
    puts-err "This command is only available on macOS."
    return 1
  fi
}
hidden-on()  { __hidden-set YES; }
hidden-off() { __hidden-set NO; }

# Make a directory then cd into it.
mkcdir() {
  if (( $# == 0 )); then
    echo "Usage: mkcdir <directory>"; return 1
  fi
  mkdir -p "$1" && cd "$1"
}

# Clean up and quit the terminal. This intentionally performs the full Leo's
# maintenance routine: package updates, AI CLI updates, history cleanup, and
# on macOS a privileged metadata sweep plus Finder/Dock restart.
# Options are exact: --keep-history, --non-interactive, --no-exit.
bye() {
  local keep_history non_interactive no_exit arg status=0
  for arg in "$@"; do
    case $arg in
      --keep-history|keep-history) keep_history=1 ;;
      --non-interactive|non-interactive) non_interactive=1 ;;
      --no-exit|no-exit) no_exit=1 ;;
      *) puts-err "Usage: bye [--keep-history] [--non-interactive] [--no-exit]"; return 2 ;;
    esac
  done

  puts "Bye!"

  sudo -v || { puts-err "sudo authentication is required for the cleanup routine."; return 1; }

  # Shadow HOMEBREW_NO_ASK for this run, restoring any pre-existing value on the
  # way out (zsh has no function-local export, so save/restore by hand).
  local __hna_saved=0 __hna_prev
  if [[ -n $non_interactive ]]; then
    [[ -n ${HOMEBREW_NO_ASK+x} ]] && { __hna_saved=1; __hna_prev=$HOMEBREW_NO_ASK; }
    export HOMEBREW_NO_ASK=1
  fi
  [[ -n $keep_history    ]] && puts "History will be preserved."

  if (( $+functions[brew-checkup] )); then puts "Doing brew checkup..."; brew-checkup || status=1; fi
  if (( $+functions[apt-checkup]   )); then puts "Doing apt checkup...";  apt-checkup || status=1; fi
  if (( $+functions[dnf-checkup]   )); then puts "Doing dnf checkup...";  dnf-checkup || status=1; fi
  if (( $+functions[ai-checkup]    )); then puts "Doing AI tools checkup..."; ai-checkup || status=1; fi

  if [[ -z $keep_history ]]; then
    puts "Clear all history files.."
    clear-history || status=1
  fi

  if [[ $(uname -s) == Darwin ]]; then
    puts "Restarting Finder, Dock, SystemUIServer..."
    rmdsstore || status=1
    killall Finder Dock SystemUIServer || status=1
  fi

  if [[ -n $non_interactive ]]; then
    if (( __hna_saved )); then export HOMEBREW_NO_ASK=$__hna_prev; else unset HOMEBREW_NO_ASK; fi
  fi

  if [[ -n $no_exit ]]; then
    puts "Skipped exiting."
    return $status
  elif command -v /mnt/c/Windows/system32/wsl.exe >/dev/null 2>&1; then
    /mnt/c/Windows/system32/wsl.exe --shutdown
  else
    exit $status
  fi
}

# Upgrade Leo's Profiles (repo + cloned zsh plugins).
upgrade-leos-profiles() {
  local branch
  branch=$(git -C "$LEOS_PROFILES" symbolic-ref --quiet --short HEAD) || {
    puts-err "This is a pinned checkout. Upgrade with a reviewed release ref via install.sh --repair."
    return 1
  }
  git -C "$LEOS_PROFILES" pull --ff-only || return $?
  puts "Updated $LEOS_PROFILES on $branch. Plugin revisions remain locked until the next profile release."
}

# Update AI coding CLIs.
ai-checkup() {
  if ! command -v npm >/dev/null 2>&1; then
    puts-err "npm is not available; cannot update AI tools."; return 1
  fi
  puts "Updating Claude Code and Codex..."
  npm update -g @anthropic-ai/claude-code @openai/codex
}

# Linux GUI toggles. Detect a known display-manager service instead of assuming
# Debian's gdm3 name on every distribution.
__leos_display_manager() {
  local service
  command -v systemctl >/dev/null 2>&1 || return 1
  for service in gdm3 gdm sddm lightdm; do
    systemctl cat "$service" >/dev/null 2>&1 && { print -r -- "$service"; return 0; }
  done
  return 1
}

gui-start() {
  local service; service=$(__leos_display_manager) || { puts-err "No supported display manager was found."; return 1; }
  sudo systemctl start "$service"
}
gui-stop() {
  local service; service=$(__leos_display_manager) || { puts-err "No supported display manager was found."; return 1; }
  sudo systemctl stop "$service"
}
gui-disable() { command -v systemctl >/dev/null 2>&1 || { puts-err "systemd is required."; return 1; }; sudo systemctl set-default multi-user.target && gui-stop; }
gui-enable()  { command -v systemctl >/dev/null 2>&1 || { puts-err "systemd is required."; return 1; }; sudo systemctl set-default graphical.target && gui-start; }
