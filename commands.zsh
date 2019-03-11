rmdsstore() {
  sudo find / -depth -iname .DS_Store -type f -print -delete 2> /dev/null || true ;
}

clear-history() {
  rm -rf ~/.*history ;
  rm -rf ~/.zcompdump* ;
  rm -rf ~/.oracle_jre_usage ;
  rm -rf ~/.lldb/*history ;
}

hidden-on() { defaults write com.apple.Finder AppleShowAllFiles YES ; }
hidden-off() { defaults write com.apple.Finder AppleShowAllFiles NO ; }

mkcdir () { mkdir -p -- "$1" && cd -P -- "$1" }

bye() {
  puts "Bye!";

  if command -v brew-checkup >/dev/null 2>/dev/null; then
    puts "Doing brew checkup...";
      brew-checkup;
  fi

  puts "Clear all history files..";
  clear-history;

  if [[ "$OSTYPE" == "darwin"* ]]; then
    puts "Restarting Finder, Dock, SystemUIServer...";
    killall Finder Dock SystemUIServer;
  fi

  if command -v upgrade_oh_my_zsh >/dev/null 2>/dev/null; then
    puts "Upgrading oh my zsh...";
    upgrade_oh_my_zsh;
  fi

  puts "Exiting...";
  exit;
}
