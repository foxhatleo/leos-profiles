# Leo's Profiles — user commands (zsh)

__rmdsstore() {
  sudo python3 "$HOME/.leos-profiles/util/rmdsstore.py" "$@"
  puts "Finished scanning $*"
}

# Remove all .DS_Store and sibling metadata files under standard macOS roots.
rmdsstore() {
  __rmdsstore /System/Volumes/Data/Users
  __rmdsstore /System/Volumes/Data/Library
  __rmdsstore /System/Volumes/Data/opt
  __rmdsstore /System/Volumes/Data/usr
  __rmdsstore /System/Volumes/Data/private
}

# Clear history files.
clear-history() {
  local f
  for f in $HOME/.*history(N) $HOME/.zcompdump*(N) \
           $HOME/.oracle_jre_usage(N) $HOME/.*hsts(N); do
    rm -rf "$f"
  done
  : > "$HISTFILE" 2>/dev/null
  fc -p "$HISTFILE" 2>/dev/null
  if [[ -d $HOME/.lldb ]]; then
    for f in $HOME/.lldb/*history(N); do rm -rf "$f"; done
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -Command "Remove-Item (Get-PSReadlineOption).HistorySavePath"
  fi
}

# Show/hide hidden files in Finder (macOS).
__hidden-set() {
  if [[ $(uname -s) == Darwin ]]; then
    defaults write com.apple.Finder AppleShowAllFiles "$1" || return 1
    killall Finder >/dev/null 2>&1 || true
  else
    puts-err "This command is only available on macOS."
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

# Clean up and quit the terminal.
# Tokens (matched anywhere in args): keep-history, non-interactive, no-exit.
bye() {
  local keep_history non_interactive no_exit
  [[ $* == *keep-history*    ]] && keep_history=1
  [[ $* == *non-interactive* ]] && non_interactive=1
  [[ $* == *no-exit*         ]] && no_exit=1

  puts "Bye!"

  local sudo_keepalive_pid
  if sudo -v; then
    zsh -c 'while true; do sudo -n true 2>/dev/null || break; sleep 50; done' &
    sudo_keepalive_pid=$!
  fi

  # Shadow HOMEBREW_NO_ASK for this run, restoring any pre-existing value on the
  # way out (zsh has no function-local export, so save/restore by hand).
  local __hna_saved=0 __hna_prev
  if [[ -n $non_interactive ]]; then
    [[ -n ${HOMEBREW_NO_ASK+x} ]] && { __hna_saved=1; __hna_prev=$HOMEBREW_NO_ASK; }
    export HOMEBREW_NO_ASK=1
  fi
  [[ -n $keep_history    ]] && puts "History will be preserved."

  (( $+functions[brew-checkup] )) && { puts "Doing brew checkup...";     brew-checkup; }
  (( $+functions[apt-checkup]  )) && { puts "Doing apt checkup...";      apt-checkup;  }
  (( $+functions[dnf-checkup]  )) && { puts "Doing dnf checkup...";      dnf-checkup;  }
  (( $+functions[ai-checkup]   )) && { puts "Doing AI tools checkup..."; ai-checkup;   }

  if [[ -z $keep_history ]]; then
    puts "Clear all history files.."
    clear-history
  fi

  if [[ $(uname -s) == Darwin ]]; then
    puts "Restarting Finder, Dock, SystemUIServer..."
    rmdsstore
    killall Finder Dock SystemUIServer
  fi

  [[ -n $sudo_keepalive_pid ]] && kill $sudo_keepalive_pid 2>/dev/null
  if [[ -n $non_interactive ]]; then
    if (( __hna_saved )); then export HOMEBREW_NO_ASK=$__hna_prev; else unset HOMEBREW_NO_ASK; fi
  fi

  if [[ -n $no_exit ]]; then
    puts "Skipped exiting."
  elif command -v /mnt/c/Windows/system32/wsl.exe >/dev/null 2>&1; then
    /mnt/c/Windows/system32/wsl.exe --shutdown
  else
    exit 0
  fi
}

# Upgrade Leo's Profiles (repo + cloned zsh plugins).
upgrade-leos-profiles() {
  git -C "$HOME/.leos-profiles" pull
  local d
  for d in "$LEOS_PROFILES_ZSH"/plugins/*(N/); do
    puts "Updating ${d:t}..."
    git -C "$d" pull --ff-only 2>/dev/null || true
  done
}

# Update AI coding CLIs.
ai-checkup() {
  if ! command -v npm >/dev/null 2>&1; then
    puts-err "npm is not available; cannot update AI tools."; return 1
  fi
  puts "Updating Claude Code and Codex..."
  npm update -g @anthropic-ai/claude-code @openai/codex
}

# Linux GUI toggles.
gui-disable() { sudo systemctl set-default multi-user; gui-stop; }
gui-enable()  { sudo systemctl set-default graphical;  gui-start; }
gui-start()   { sudo systemctl start gdm3; }
gui-stop()    { sudo systemctl stop gdm3; }
