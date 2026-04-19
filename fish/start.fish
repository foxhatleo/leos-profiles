# Leo's Profiles
# Starting point script
#
# This script adds basic utility functions, and loads "fish/entries.fish".

function puts
  set_color --bold blue; echo -n "===> "; set_color normal ; set_color --bold; echo "$argv"; set_color normal
end

function puts-err
  set_color --bold red; echo -n "===> "; set_color normal ; set_color --bold; echo "$argv"; set_color normal
end

function add-path
  if test -d $argv[1]
    fish_add_path -m $argv[1]
  else if test "$argv[2]" = "required"
    puts-err "$argv[1] is not found."
    return 1
  end
  return 0
end

function __leos_brew_bin
  if command -sq brew
    command -s brew
    return 0
  end

  for brew_bin in \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew \
    $HOME/.linuxbrew/bin/brew \
    /home/linuxbrew/.linuxbrew/bin/brew
    if test -x "$brew_bin"
      echo "$brew_bin"
      return 0
    end
  end

  return 1
end

function __leos_brew_prefix
  if set -l brew_bin (__leos_brew_bin)
    "$brew_bin" --prefix
    return $status
  end

  return 1
end

set LEOS_PROFILES $HOME/.leos-profiles
set LEOS_PROFILES_FISH $LEOS_PROFILES/fish

function entry
  if test -e "$LEOS_PROFILES_FISH/$argv[1].fish"
    source "$LEOS_PROFILES_FISH/$argv[1].fish"
  else if not test "$argv[2]" = "optional"
    puts-err "$argv[1] is not found. Check $LEOS_PROFILES_FISH/entries.fish."
  end
end

entry entries
