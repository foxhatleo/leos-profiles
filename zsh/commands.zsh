# Leo's Profiles — user commands (zsh)

__rmdsstore() {
  if [[ $(uname -s) != Darwin ]]; then
    puts-err "rmdsstore only supports the macOS data-volume layout."
    return 1
  fi
  # Run the sweep with the OS interpreter, not a PATH-resolved one: `sudo` must
  # not execute a python3 from a user-writable dir (the Homebrew prefix, pyenv
  # shims), which would be a local root-escalation vector — especially since
  # `bye` runs `brew upgrade` moments earlier. `-I` isolates the interpreter
  # (ignores PYTHON* env and user site; drops the script dir from sys.path on
  # 3.11+). rmdsstore.py is stdlib-only, so the system Python is sufficient.
  # Note: the script itself lives in the user-owned checkout by design (see the
  # README trust model); this closes the interpreter/env vectors, not that one.
  if [[ ! -x /usr/bin/python3 ]]; then
    puts-err "/usr/bin/python3 (the system Python) is required for rmdsstore."
    return 1
  fi
  sudo /usr/bin/python3 -I "$LEOS_PROFILES/util/rmdsstore.py" "$@" || return $?
  puts "Finished scanning $*"
}

# Remove all .DS_Store and sibling metadata files under standard macOS roots.
rmdsstore() {
  local arg
  local -a options
  while (( $# > 0 )); do
    arg=$1
    case $arg in
      --dry-run|--purge-recycle-bins) options+=("$arg"); shift ;;
      --) shift; break ;;
      -*) puts-err "Usage: rmdsstore [--dry-run] [--purge-recycle-bins] [root ...]"; return 2 ;;
      *) break ;;
    esac
  done
  __rmdsstore "${options[@]}" "$@"
}

# Clear known history files. The aggressive mode adds the legacy broad globs,
# but still never recursively deletes a matched directory.
clear-history() {
  local aggressive=${1:-} f exit_code=0
  local -a candidates
  candidates=("$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.python_history"
              "$HOME/.node_repl_history" "$HOME/.lesshst")
  if [[ $aggressive == --aggressive ]]; then
    candidates+=($HOME/.*history(N) $HOME/.zcompdump*(N) \
                 $HOME/.oracle_jre_usage(N) $HOME/.*hsts(N))
  fi
  for f in "${candidates[@]}"; do
    [[ -f $f || -L $f ]] || continue
    rm -f -- "$f" || exit_code=1
  done
  : > "$HISTFILE" 2>/dev/null || exit_code=1
  fc -p "$HISTFILE" 2>/dev/null || exit_code=1
  if [[ -d $HOME/.lldb ]]; then
    for f in $HOME/.lldb/*history(N); do
      if [[ -f $f || -L $f ]]; then rm -f -- "$f" || exit_code=1; fi
    done
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -Command "Remove-Item (Get-PSReadlineOption).HistorySavePath" || exit_code=1
  fi
  return $exit_code
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
  mkdir -p -- "$1" && cd -- "$1"
}

# Clean up and quit the terminal. This intentionally performs the full Leo's
# maintenance routine: package updates, AI CLI updates, history cleanup, and
# on macOS a privileged metadata sweep plus Finder/Dock restart.
# Options are exact; destructive extensions are explicit opt-ins.
bye() {
  local keep_history non_interactive no_exit aggressive_history purge_recycle_bins shutdown_wsl arg exit_code=0
  for arg in "$@"; do
    case $arg in
      --keep-history|keep-history) keep_history=1 ;;
      --non-interactive|non-interactive) non_interactive=1 ;;
      --no-exit|no-exit) no_exit=1 ;;
      --aggressive-history) aggressive_history=1 ;;
      --purge-recycle-bins) purge_recycle_bins=1 ;;
      --shutdown-wsl) shutdown_wsl=1 ;;
      *) puts-err "Usage: bye [--keep-history] [--non-interactive] [--no-exit] [--aggressive-history] [--purge-recycle-bins] [--shutdown-wsl]"; return 2 ;;
    esac
  done
  if [[ -n $shutdown_wsl && -n $no_exit ]]; then
    puts-err "--shutdown-wsl and --no-exit are contradictory."
    return 2
  fi
  if [[ -n $keep_history && -n $aggressive_history ]]; then
    puts-err "--keep-history and --aggressive-history are contradictory."
    return 2
  fi

  puts "Bye!"

  sudo -v || { puts-err "sudo authentication is required for the cleanup routine."; return 1; }

  # A local export is automatically restored even on an early function return.
  if [[ -n $non_interactive ]]; then
    local -x HOMEBREW_NO_ASK=1
  fi
  [[ -n $keep_history    ]] && puts "History will be preserved."

  if (( $+functions[brew-checkup] )); then puts "Doing brew checkup..."; brew-checkup || exit_code=1; fi
  if (( $+functions[apt-checkup]   )); then puts "Doing apt checkup...";  apt-checkup || exit_code=1; fi
  if (( $+functions[dnf-checkup]   )); then puts "Doing dnf checkup...";  dnf-checkup || exit_code=1; fi
  if (( $+functions[pacman-checkup] )); then puts "Doing pacman checkup..."; pacman-checkup || exit_code=1; fi
  if (( $+functions[ai-checkup]    )); then puts "Doing AI tools checkup..."; ai-checkup || exit_code=1; fi

  if [[ -z $keep_history ]]; then
    puts "Clear all history files.."
    if [[ -n $aggressive_history ]]; then
      clear-history --aggressive || exit_code=1
    else
      clear-history || exit_code=1
    fi
  fi

  if [[ $(uname -s) == Darwin ]]; then
    puts "Restarting Finder, Dock, SystemUIServer..."
    if [[ -n $purge_recycle_bins ]]; then rmdsstore --purge-recycle-bins || exit_code=1; else rmdsstore || exit_code=1; fi
    killall Finder Dock SystemUIServer || exit_code=1
  fi

  if [[ -n $no_exit ]]; then
    puts "Skipped exiting."
    return $exit_code
  elif [[ -n $shutdown_wsl ]] && command -v /mnt/c/Windows/system32/wsl.exe >/dev/null 2>&1; then
    /mnt/c/Windows/system32/wsl.exe --shutdown
  else
    exit $exit_code
  fi
}

# Fast-forward the configured profile upstream, then run the newly pulled
# deterministic reconciler against the saved local profile.
upgrade-leos-profiles() {
  local branch upstream
  local -a reconcile_args
  reconcile_args=(reconcile --yes)
  if (( $# > 1 )) || [[ $# == 1 && $1 != --full-upgrade ]]; then
    puts-err "Usage: upgrade-leos-profiles [--full-upgrade]"
    return 2
  fi
  [[ ${1:-} != --full-upgrade ]] || reconcile_args+=(--full-upgrade)
  branch=$(git -C "$LEOS_PROFILES" symbolic-ref --quiet --short HEAD) || {
    puts-err "The profile checkout must be on a branch."
    return 1
  }
  upstream=$(git -C "$LEOS_PROFILES" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || {
    puts-err "Branch $branch has no configured upstream."
    return 1
  }
  if [[ -n $(git -C "$LEOS_PROFILES" status --porcelain --untracked-files=normal) ]]; then
    puts-err "Refusing to pull because the profile checkout has local changes. Commit or stash them first."
    return 1
  fi
  git -C "$LEOS_PROFILES" pull --ff-only || return $?
  puts "Updated $LEOS_PROFILES from $upstream; reconciling the saved setup."
  command bash "$LEOS_PROFILES/install.sh" "${reconcile_args[@]}"
}

# Update only installed AI coding CLIs using their supported native updaters.
ai-checkup() {
  local found=0 exit_code=0
  if command -v claude >/dev/null 2>&1; then
    found=1; puts "Updating Claude Code..."; claude update || exit_code=1
  fi
  if command -v codex >/dev/null 2>&1; then
    found=1; puts "Updating Codex..."; codex update || exit_code=1
  fi
  (( found )) || puts "No supported installed AI CLI was detected; nothing to update."
  return $exit_code
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

:
