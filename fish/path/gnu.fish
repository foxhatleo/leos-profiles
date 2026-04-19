# Leo's Profiles
# GNU tools
#
# This script replaces BSD tools on macOS with GNU tools if enabled.

if test (uname -s) = 'Darwin'; and not test -f "$HOME/.lp-no-gnu"; and set -l brew_prefix (__leos_brew_prefix)
    add-path "$brew_prefix/opt/coreutils/libexec/gnubin"
    add-path "$brew_prefix/opt/findutils/libexec/gnubin"
    add-path "$brew_prefix/opt/gnu-indent/libexec/gnubin"
    add-path "$brew_prefix/opt/gnu-sed/libexec/gnubin"
    add-path "$brew_prefix/opt/grep/libexec/gnubin"
    add-path "$brew_prefix/opt/gnu-tar/libexec/gnubin"
    add-path "$brew_prefix/opt/gawk/libexec/gnubin"
    add-path "$brew_prefix/opt/ed/libexec/gnubin"
    add-path "$brew_prefix/opt/gnu-which/libexec/gnubin"

    function enable-gnu
        rm -f "$HOME/.lp-no-gnu"
        puts "Enabled GNU tools. Restart shell to take effect."
    end

    function disable-gnu
        touch "$HOME/.lp-no-gnu"
        puts "Disabled GNU tools. Restart shell to take effect."
    end
end
