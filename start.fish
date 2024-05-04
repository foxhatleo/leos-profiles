# Leo's Profiles
# Starting point script
#
# This script adds basic utility functions, and loads "entries.fish".

function puts
  set_color -b blue; set_color bold; echo "===> $argv"; set_color normal
end

function puts-err
  set_color -b red; set_color bold; echo "===> $argv"; set_color normal
end

function add-path
  if test -d $argv[1]
    fish_add_path $argv[1]
  else if test "$argv[2]" = "required"
    puts-err "$argv[1] is not found."
    return 1
  end
  return 0
end

set LEOS_PROFILES $HOME/.leos-profiles

function entry
  if test -e "$LEOS_PROFILES/$argv[1].fish"
    source "$LEOS_PROFILES/$argv[1].fish"
  else if not test "$argv[2]" = "optional"
    puts-err "$argv[1] is not found. Check $LEOS_PROFILES/entries.fish."
  end
end

entry entries
