# Leo's zsh Profiles
# Entries script
#
# This script adds useful commands to the environment.

__rmdsstore() {
  echo "$HOME/.leos-profiles/rmdsstore.py"
  sudo python "$HOME/.leos-profiles/rmdsstore.py" "$1"
  puts "Finished scanning $1"
}

# Remove all .DS_Store files.
rmdsstore() {
  __rmdsstore /System/Volumes/Data/Users 
  __rmdsstore /System/Volumes/Data/Library 
  __rmdsstore /System/Volumes/Data/opt 
  __rmdsstore /System/Volumes/Data/usr 
  __rmdsstore /System/Volumes/Data/private 
}

# Clear any history files.
clear-history() {
  setopt +o nomatch
  rm -rf $HOME/.*history 
  rm -rf $HOME/.zcompdump* 
  rm -rf $HOME/.oracle_jre_usage 
  rm -rf $HOME/.*hsts 
  if [ -d "$HOME/.lldb" ]; then
    rm -rf $HOME/.lldb/*history 
  fi
  if command -v powershell.exe >/dev/null 2>/dev/null; then
    powershell.exe -Command "Remove-Item (Get-PSReadlineOption).HistorySavePath"
  fi
}

# Show/hide hidden files in Finder.
__hidden-set() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    defaults write com.apple.Finder AppleShowAllFiles $1 
  else
    puts-err "This command is only available on macOS."
  fi
}
hidden-on() { __hidden-set YES ; }
hidden-off() { __hidden-set NO ; }

# mk a directory then cd into it.
mkcdir () { mkdir -p -- "$1" && cd -P -- "$1" }

# Clean up and quit the terminal.
bye() {
  puts "Bye!"

  if command -v brew-checkup &>/dev/null; then
    puts "Doing brew checkup..."
    brew-checkup
  fi

  if command -v apt-checkup &>/dev/null; then
    puts "Doing apt checkup..."
    apt-checkup
  fi

  if command -v dnf-checkup &>/dev/null; then
    puts "Doing dnf checkup..."
    dnf-checkup
  fi

  if command -v omz &>/dev/null; then
    puts "Upgrading oh my zsh..."
    omz update --unattended
  fi

  puts "Clear all history files.."
  clear-history

  if [[ "$OSTYPE" == "darwin"* ]]; then
    puts "Restarting Finder, Dock, SystemUIServer..."
    rmdsstore
    killall Finder Dock SystemUIServer
  fi

  if [ "$1" = "noexit" ]; then
    puts "Skipped exiting."
  elif command -v /mnt/c/Windows/system32/wsl.exe &> /dev/null ; then
    /mnt/c/Windows/system32/wsl.exe --shutdown
  else
    exit 0
  fi
}

# Upgrade Leo's profiles.
upgrade-leos-profiles () {
  git pull $HOME/.leos-profiles
}

# Disable GUI on Linux systems.
gui-disable() {
  sudo systemctl set-default multi-user
  gui-stop
}

# Enable GUI on Linux systems.
gui-enable() {
  sudo systemctl set-default graphical
  gui-start
}

# Start GUI on Linux systems.
gui-start() {
  sudo systemctl start gdm3
}

# Stop GUI on Linux systems.
gui-stop() {
  sudo systemctl stop gdm3
}
