# Leo's Profiles
# Entries script
#
# This script adds useful commands to the environment.

function __rmdsstore
  sudo python "$HOME/.leos-profiles/rmdsstore.py" $argv
  puts "Finished scanning $argv"
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
  for file in $HOME/.*history ; rm $file; end
  for file in $HOME/.zcompdump* ; rm $file; end
  for file in $HOME/.oracle_jre_usage ; rm $file; end
  for file in $HOME/.*hsts ; rm $file; end
  echo yes | history --clear
  if test -d "$HOME/.lldb"
    for file in $HOME/.lldb/*history ; rm $file; end 
  end
  if command -sq powershell.exe
    powershell.exe -Command "Remove-Item (Get-PSReadlineOption).HistorySavePath"
  end
end

# Show/hide hidden files in Finder.
function __hidden-set
  if test (uname -s) = 'Darwin'
    defaults write com.apple.Finder AppleShowAllFiles $argv
  else
    puts-err "This command is only available on macOS."
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
  puts "Bye!"
  sudo echo nothing > /dev/null

  if functions brew-checkup > /dev/null
    puts "Doing brew checkup..."
    brew-checkup
  end

  if functions apt-checkup > /dev/null
    puts "Doing apt checkup..."
    apt-checkup
  end

  if functions dnf-checkup > /dev/null
    puts "Doing dnf checkup..."
    dnf-checkup
  end

  puts "Clear all history files.."
  clear-history

  if test (uname -s) = 'Darwin'
    puts "Restarting Finder, Dock, SystemUIServer..."
    rmdsstore
    killall Finder Dock SystemUIServer
  end

  if test "$argv" = "noexit"
    puts "Skipped exiting."
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
