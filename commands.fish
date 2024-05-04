# Leo's Profiles
# Entries script
#
# This script adds useful commands to the environment.

function __rmdsstore
  sudo python "$HOME/.leos-profiles/rmdsstore.py" $argv
  echo "Finished scanning $argv"
end

# Remove all .DS_Store files.
function rmdsstore
  __rmdsstore /System/Volumes/Data/Users 
  __rmdsstore /System/Volumes/Data/Library 
  __rmdsstore /System/Volumes/Data/opt 
  __rmdsstore /System/Volumes/Data/usr 
  __rmdsstore /System/Volumes/Data/private 
end

# Clear any history files.
function clear-history
  set -g fish_user_paths
  rm -rf $HOME/.*history 
  rm -rf $HOME/.zcompdump* 
  rm -rf $HOME/.oracle_jre_usage 
  rm -rf $HOME/.*hsts 
  if test -d "$HOME/.lldb"
    rm -rf $HOME/.lldb/*history 
  end
  if command -sq powershell.exe
    powershell.exe -Command "Remove-Item (Get-PSReadlineOption).HistorySavePath"
  end
end

# Show/hide hidden files in Finder.
function __hidden-set
  if string match -q "darwin*" $OSTYPE
    defaults write com.apple.Finder AppleShowAllFiles $argv
  else
    echo "This command is only available on macOS."
  end
end
function hidden-on
  __hidden-set YES
end
function hidden-off
  __hidden-set NO
end

# Make a directory then cd into it.
function mkcdir
  mkdir -p -- $argv; and cd -P -- $argv
end

# Clean up and quit the terminal.
function bye
  echo "Bye!"

  if command -sq brew-checkup
    echo "Doing brew checkup..."
    brew-checkup
  end

  if command -sq apt-checkup
    echo "Doing apt checkup..."
    apt-checkup
  end

  if command -sq dnf-checkup
    echo "Doing dnf checkup..."
    dnf-checkup
  end

  if command -sq omf
    echo "Upgrading oh my zsh..."
    omz update
  end

  echo "Clear all history files.."
  clear-history

  if string match -q "darwin*" $OSTYPE
    echo "Restarting Finder, Dock, SystemUIServer..."
    rmdsstore
    killall Finder Dock SystemUIServer
  end

  if test "$argv" = "noexit"
    echo "Skipped exiting."
  else if command -sq /mnt/c/Windows/system32/wsl.exe
    /mnt/c/Windows/system32/wsl.exe --shutdown
  else
    exit 0
  end
end

# Upgrade Leo's profiles.
function upgrade-leos-profiles
  git pull $HOME/.leos-profiles
end

# Disable GUI on Linux systems.
function gui-disable
  sudo systemctl set-default multi-user
  gui-stop
end

# Enable GUI on Linux systems.
function gui-enable
  sudo systemctl set-default graphical
  gui-start
end

# Start GUI on Linux systems.
function gui-start
  sudo systemctl start gdm3
end

# Stop GUI on Linux systems.
function gui-stop
  sudo systemctl stop gdm3
end
