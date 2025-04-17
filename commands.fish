# Leo's Profiles
# Entries script
#
# This script adds useful commands to the environment.

function __rmdsstore
  sudo python3 "$HOME/.leos-profiles/rmdsstore.py" $argv
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
  for file in $HOME/.*history ; rm -rf $file; end
  for file in $HOME/.zcompdump* ; rm -rf $file; end
  for file in $HOME/.oracle_jre_usage ; rm -rf $file; end
  for file in $HOME/.*hsts ; rm -rf $file; end
  echo yes | history --clear
  if test -d "$HOME/.lldb"
    for file in $HOME/.lldb/*history ; rm -rf $file; end 
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
  if test (count $argv) -eq 0
    echo "Usage: mkcdir <directory>"
    return 1
  end

  mkdir -p $argv[1]  # Create the directory (and parents, if needed)
  cd $argv[1]        # Change into the directory
end

# Clean up and quit the terminal.
function bye
  puts "Bye!"
  sudo echo '' > /dev/null

  if string match -r ".*keep-history.*" $argv
    puts "History will be preserved."
  end

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

  if not string match -r ".*keep-history.*" $argv
    puts "Clear all history files.."
    clear-history
  end

  if test (uname -s) = 'Darwin'
    puts "Restarting Finder, Dock, SystemUIServer..."
    rmdsstore
    killall Finder Dock SystemUIServer
  end

  if string match -r ".*no-exit.*" $argv
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

# =============================================================================
# Fish completions for Leo's Profiles commands
# =============================================================================

# Remove all .DS_Store files on the system
complete -c rmdsstore -f -d "Remove all .DS_Store files on the system"

# Clear any history files
complete -c clear-history -f -d "Clear any history files"

# Show hidden files in Finder (macOS only)
complete -c hidden-on -f -d "Show hidden files in Finder (macOS only)"

# Hide hidden files in Finder (macOS only)
complete -c hidden-off -f -d "Hide hidden files in Finder (macOS only)"

# Make a directory then cd into it
complete -c mkcdir -f -d "Make a directory then cd into it"
complete -c mkcdir -f -x -a "(__fish_complete_directories)" -d "Directory to create and enter"

# Clean up and quit the terminal
complete -c bye -f -d "Clean up and quit the terminal"
complete -c bye -f -a "no-exit" -d "Do not quit the terminal"
complete -c bye -f -a "keep-history" -d "Preserve history files"

# Upgrade Leo's profiles
complete -c upgrade-leos-profiles -f -d "Upgrade Leo's profiles"
