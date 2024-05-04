# Leo's Profiles
# GNU tools
#
# This script replaces BSD tools on macOS with GNU tools if enabled.

if test (uname -s) = 'Darwin'; and not test -f "$HOME/.lp-no-gnu"
    add-path "/opt/homebrew/opt/coreutils/libexec/gnubin"
    add-path "/opt/homebrew/opt/findutils/libexec/gnubin"
    add-path "/opt/homebrew/opt/gnu-indent/libexec/gnubin"
    add-path "/opt/homebrew/opt/gnu-sed/libexec/gnubin"
    add-path "/opt/homebrew/opt/grep/libexec/gnubin"
    add-path "/opt/homebrew/opt/gnu-tar/libexec/gnubin"
    add-path "/opt/homebrew/opt/gawk/libexec/gnubin"
    add-path "/opt/homebrew/opt/ed/libexec/gnubin"
    add-path "/opt/homebrew/opt/gnu-which/libexec/gnubin"

    function enable-gnu
        rm -f "$HOME/.lp-no-gnu"
        puts "Enabled GNU tools. Restart shell to take effect."
    end

    function disable-gnu
        touch "$HOME/.lp-no-gnu"
        puts "Disabled GNU tools. Restart shell to take effect."
    end
end
