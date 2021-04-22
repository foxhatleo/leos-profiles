# Remove all .DS_Store files.
rmdsstore() {
  sudo find /Users -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /private usr -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /Library usr -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /bin usr -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /cores usr -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /opt usr -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /sbin usr -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /usr usr -depth -iname .DS_Store -type f -print -delete 2> /dev/null ;
  sudo find /Applications -depth -iname .DS_Store -type f -print -delete 2> /dev/null || true
}

# Clear any history files.
clear-history() {
  setopt +o nomatch;
  rm -rf $HOME/.*history ;
  rm -rf $HOME/.zcompdump* ;
  rm -rf $HOME/.oracle_jre_usage ;
  rm -rf $HOME/.*hsts ;
  if [ -d "$HOME/.lldb" ]; then
    rm -rf $HOME/.lldb/*history ;
  fi
}

# Show/hide hidden files in Finder.
hidden-on() { defaults write com.apple.Finder AppleShowAllFiles YES ; }
hidden-off() { defaults write com.apple.Finder AppleShowAllFiles NO ; }

# mk a directory then cd into it.
mkcdir () { mkdir -p -- "$1" && cd -P -- "$1" }

# Clean up and quit the terminal.
bye() {
  puts "Bye!";

  if command -v brew-checkup >/dev/null 2>/dev/null; then
    puts "Doing brew checkup...";
      brew-checkup;
  fi

  if command -v upgrade_oh_my_zsh >/dev/null 2>/dev/null; then
    puts "Upgrading oh my zsh...";
    omz update;
  fi

  puts "Clear all history files..";
  clear-history;

  if [[ "$OSTYPE" == "darwin"* ]]; then
    puts "Restarting Finder, Dock, SystemUIServer...";
    killall Finder Dock SystemUIServer;
  fi

  puts "Exiting...";
  exit 0;
}

# Upgrade Leo's profiles.
upgrade-leos-profiles () {
  git pull $HOME/.leos-profiles
}
