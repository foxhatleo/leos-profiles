if [[ "$OSTYPE" == "darwin"* ]]; then
  function rmdsstore() { sudo ~/.zsh_profiles/rmdsstore/rmdsstore ; }
  function clear-history() {
      rm -f ~/.*history ;
      rm -f ~/.zcompdump* ;
      rm -r ~/.oracle_jre_usage ;
  }
  function hidden-on() { defaults write com.apple.Finder AppleShowAllFiles YES ; }
  function hidden-off() { defaults write com.apple.Finder AppleShowAllFiles NO ; }
  function brew-checkup() {
    brew update ;
    brew upgrade ;
    brew cask upgrade ;
    brew cleanup ;
    brew prune ;
    brew doctor ;
  }

  function _bye__output() { echo "$(tput setaf 4 bold)===>$(tput bold) $1$(tput sgr0)"; }
  function bye() {
    _bye__output "Bye!";

    _bye__output "Removing .DS_Store...";
    rmdsstore;

    _bye__output "Doing brew checkup...";
    brew-checkup;

    _bye__output "Clear all history files..";
    clear-history;

    _bye__output "Restarting Finder, Dock, SystemUIServer...";
    killall Finder Dock SystemUIServer;

    upgrade_oh_my_zsh;

    _bye__output "Exiting...";
    exit;
  }
fi
