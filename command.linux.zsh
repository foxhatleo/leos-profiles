if [[ "$OSTYPE" == "linux-gnu" ]]; then
  function clear-history() {
      rm -f ~/.*history ;
      rm -f ~/.zcompdump* ;
  }
  function apt-checkup() {
    apt update ;
    apt upgrade ;
    apt autoremove ;
  }

  function _bye__output() { echo "$(tput setaf 4 bold)===>$(tput bold) $1$(tput sgr0)"; }
  function bye() {
    _bye__output "Bye!";

    if ! type "apt" > /dev/null; then
      _bye__output "Doing apt checkup...";
      apt-checkup;
    fi

    _bye__output "Clear all history files..";
    clear-history;

    upgrade_oh_my_zsh;

    _bye__output "Shutting down...";
    sudo poweroff;
  }
fi
