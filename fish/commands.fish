# Leo's Profiles
# Entries script
#
# This script adds useful commands to the environment.

function __rmdsstore
  sudo python3 "$HOME/.leos-profiles/util/rmdsstore.py" $argv
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
    defaults write com.apple.Finder AppleShowAllFiles $argv; or return 1
    killall Finder > /dev/null 2>&1; or true
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
#
# Options (matched anywhere in the arguments, any combination):
#   keep-history     Preserve history files instead of clearing them.
#   non-interactive  Skip package-manager confirmation prompts (brew's ask-mode
#                    via HOMEBREW_NO_ASK; apt/dnf checkups already run unattended).
#                    Sudo still asks for a password once up front — unless sudo is
#                    passwordless or you are root, in which case bye runs silently.
#   no-exit          Do everything except quitting the terminal at the end.
function bye
  set -l keep_history
  set -l non_interactive
  set -l no_exit
  string match -qr 'keep-history'    -- $argv; and set keep_history 1
  string match -qr 'non-interactive' -- $argv; and set non_interactive 1
  string match -qr 'no-exit'         -- $argv; and set no_exit 1

  puts "Bye!"

  # Ask for sudo once up front, then keep the credential warm for the whole run
  # so nothing below prompts for a password again. Run the keep-alive as an
  # external `fish -c` process (NOT a backgrounded function — fish does not set
  # $last_pid for those), so we can actually stop it on the way out.
  set -l sudo_keepalive_pid
  if sudo -v
    fish -c 'while true; sudo -n true 2>/dev/null; or break; sleep 50; end' &
    set sudo_keepalive_pid $last_pid
  end

  # In non-interactive mode, disable Homebrew's default ask-mode prompt. Use
  # function scope so it shadows (never clobbers) any existing value and clears
  # itself when `bye` returns; brew still inherits it as an exported var.
  if set -q non_interactive[1]
    set -fx HOMEBREW_NO_ASK 1
  end

  if set -q keep_history[1]
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

  if functions ai-checkup > /dev/null
    puts "Doing AI tools checkup..."
    ai-checkup
  end

  if not set -q keep_history[1]
    puts "Clear all history files.."
    clear-history
  end

  if test (uname -s) = 'Darwin'
    puts "Restarting Finder, Dock, SystemUIServer..."
    rmdsstore
    killall Finder Dock SystemUIServer
  end

  # Stop the sudo keep-alive. HOMEBREW_NO_ASK is function-scoped, so it clears
  # itself when we return — no manual env cleanup needed.
  if set -q sudo_keepalive_pid[1]
    kill $sudo_keepalive_pid 2>/dev/null
  end

  if set -q no_exit[1]
    puts "Skipped exiting."
  else if command -sq /mnt/c/Windows/system32/wsl.exe
    /mnt/c/Windows/system32/wsl.exe --shutdown
  else
    exit 0
  end
end

# Upgrade Leo's profiles.
function upgrade-leos-profiles
  git -C "$HOME/.leos-profiles" pull
end

# Update AI coding CLIs (Claude Code, Codex) to their latest versions.
function ai-checkup
  if not command -sq npm
    puts-err "npm is not available; cannot update AI tools."
    return 1
  end
  puts "Updating Claude Code and Codex..."
  npm update -g @anthropic-ai/claude-code @openai/codex
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
complete -c bye -f -a "non-interactive" -d "Run upgrades without confirmation prompts"

# Upgrade Leo's profiles
complete -c upgrade-leos-profiles -f -d "Upgrade Leo's profiles"

# Update AI coding CLIs (Claude Code, Codex)
complete -c ai-checkup -f -d "Update AI coding CLIs (Claude Code, Codex)"
